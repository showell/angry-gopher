/* MessageView — exploratory abstraction (NOT wired into chat.js).

   A scrollable list of opaque bubbles with: selection state, keyboard
   navigation, scroll-driven selection updates, programmatic-scroll
   suppression, click event surfacing, and a backlog batch mode for
   bulk inserts. Bubble content is the caller's concern via
   renderBubble(idx, data).

   Bubbles are numbered 1..N (1-based). The selection is one index in
   [1..N], or 0 for "no selection". The view doesn't know about mine vs
   theirs, indentation, markdown, or any chat-domain concept; it just
   manages a numbered list of opaque rectangles in a scroll container.

   Keyboard ownership: the view OWNS Arrow Up/Down, Home, End, PgUp,
   PgDn — those map to its own moveCursor / cursorToExtreme / pageNav.
   The keydown listener attaches at document level with the standard
   input-focus filter, and only acts on those keys. Every other key
   (q, r, e, b, f, c, t, /, etc.) is the caller's domain — the listener
   passes through without preventDefault, so the caller's dispatcher
   (e.g. ChatHelp) can still bind whatever else it wants.

   Backlog batch mode: between startBacklog(count) and endBacklog(opts),
   append() is DOM-only. settle() is a no-op, the scroll listener is a
   no-op, clicks don't fire. At endBacklog the view does ONE anchor
   action (focus a specific bubble, scroll to bottom, or leave alone),
   commits ONE selection, and runs an image-decode stabilizer that
   re-anchors as <img>s load (image decode grows scrollHeight without
   firing scroll events — pure browser-API leak).

   What it does NOT do:
   - Render bubble content (caller's renderBubble does that)
   - Classify clicks (caller's onClick decides image-zoom / msg-ref / etc.)
   - Track domain identifiers (caller maps wantFocusID → idx itself)
   - Manage a nav-stack / back-forward (caller's domain feature)

   Usage sketch (chat.js could do roughly this if we wired it up):

     var view = MessageView.create({
       container: document.getElementById('chat-bubbles'),
       renderBubble: function(idx, m){
         var div = document.createElement('div');
         div.className = 'chat-msg ' + (m.mine ? 'mine' : 'theirs');
         div.id = 'msg-' + m.id;
         div.setAttribute('data-i', idx - 1);
         // ... meta + body construction ...
         return div;
       },
       setSelectedBubble: function(idx){ updateHash(); updateNav(); },
       onClick: function(idx, e){
         var hit = hitInBody(e.target);
         if(hit.kind === 'msgref'){ navigateRef(hit.el); return; }
         openHitMedia(hit);
       },
     });

     // Initial load — server pushes backlog-size then 247 messages:
     view.startBacklog(247);
     for(each m in replay) view.append(m);
     view.endBacklog({ anchor: 'bottom' });

     // Live SSE handler:
     view.append(msg);

     // Caller's keymap still binds the domain keys:
     case 'q': if(s) deps.quoteReply(s); return;
     // Arrow / Home / End / PgUp / PgDn — view handles internally.
*/

window.MessageView = (function(){
  'use strict';

  function create(opts){
    var container       = opts.container;
    /* PRODUCT_DECISION: `list` is the appendChild target; container is the
       scroll surface. They're the same in simple cases; chat.js needs them
       separate because the scroll surface (#chat-history) wraps both
       #chat-bubbles AND the transcript view. */
    var list            = opts.list || container;
    var renderBubble    = opts.renderBubble;
    var setSelectedBubble = opts.setSelectedBubble || function(){};
    var settleDelay     = opts.settleDelay     || 700;
    var scrollQuietMs   = opts.scrollQuietMs   || 150;
    var revealPadTop    = opts.revealPadTop    || 6;
    var revealPadBottom = opts.revealPadBottom || 48;
    var stabilizeMs     = opts.stabilizeMs     || 5000;

    var els = [];        /* PRODUCT_DECISION: 0-indexed array; external API is 1-based. */
    var selected = 0;    /* PRODUCT_DECISION: 0 means "no selection" (avoids null). */
    var settleTimer = null;
    var pendingIdx = 0;
    var progScroll = false;
    var progScrollTimer = null;
    var rafPending = false;
    var inBacklog = false;       /* PRODUCT_DECISION: batch mode flag; suppresses settle/scroll/click. */
    var userScrolled = false;    /* PRODUCT_DECISION: tracked outside progScroll windows; gates the stabilizer. */

    /* ---- selection ---- */

    function applySelection(idx){
      if(selected > 0 && els[selected - 1]) els[selected - 1].classList.remove('selected');
      selected = idx;
      if(selected > 0) els[selected - 1].classList.add('selected');
    }
    /* PRODUCT_DECISION: selection visual ALWAYS applies immediately; only the
       caller's setSelectedBubble callback (URL hash + nav-stack push) honors
       the debounce. Holding ArrowUp must walk the cursor one bubble per
       keypress — debouncing the visible selection makes a burst land on the
       FINAL keypress's target as a single step instead of stepping through.
       The 700ms rest is the "I've found something important, record it"
       signal for the nav stack, not a brake on the cursor itself. */
    function settle(idx, immediate){
      if(inBacklog) return; /* PRODUCT_DECISION: batch mode skips all settles — endBacklog does the final one. */
      if(settleTimer){ clearTimeout(settleTimer); settleTimer = null; }
      applySelection(idx);
      pendingIdx = idx;
      if(immediate){
        setSelectedBubble(idx);
      } else {
        settleTimer = setTimeout(function(){
          settleTimer = null;
          setSelectedBubble(pendingIdx);
        }, settleDelay);
      }
    }

    /* ---- programmatic-scroll suppression ---- */

    function endProgScroll(){ progScroll = false; progScrollTimer = null; }
    function armedScroll(fn){
      progScroll = true;
      if(progScrollTimer) clearTimeout(progScrollTimer);
      progScrollTimer = setTimeout(endProgScroll, scrollQuietMs);
      fn();
    }

    /* ---- visibility + reveal ---- */

    function visibleIdxs(){
      /* BROWSER_WORKAROUND: offsetParent===null skips bubbles in a hidden
         sibling view (e.g. the transcript view when rendered is active). */
      var out = [];
      for(var i = 0; i < els.length; i++){
        if(els[i].offsetParent !== null) out.push(i + 1);
      }
      return out;
    }
    function revealEl(el){
      var hr = container.getBoundingClientRect(), r = el.getBoundingClientRect();
      if(r.top < hr.top + revealPadTop){
        container.scrollTop += r.top - hr.top - revealPadTop;
      } else if(r.bottom > hr.bottom - revealPadBottom){
        var delta = r.bottom - (hr.bottom - revealPadBottom);
        if(r.top - delta < hr.top + revealPadTop) delta = r.top - hr.top - revealPadTop;
        container.scrollTop += delta;
      }
    }

    /* ---- scroll-driven selection ---- */

    function selectionCandidate(){
      var hr = container.getBoundingClientRect();
      var beginning = 0, straddler = 0;
      var visible = visibleIdxs();
      for(var i = 0; i < visible.length; i++){
        var el = els[visible[i] - 1], r = el.getBoundingClientRect();
        if(r.top >= hr.top - 1 && r.bottom <= hr.bottom + 1) return visible[i];
        if(!beginning && r.top >= hr.top - 1 && r.top < hr.bottom) beginning = visible[i];
        if(!straddler && r.top < hr.top && r.bottom > hr.top) straddler = visible[i];
      }
      return beginning || straddler || 0;
    }
    function syncSelectionToScroll(){
      if(progScroll) return;
      var idx = selectionCandidate();
      if(idx > 0 && idx !== selected) settle(idx, false);
    }
    container.addEventListener('scroll', function(){
      if(inBacklog) return; /* PRODUCT_DECISION: batch appends grow scrollHeight; no per-message scroll work. */
      if(progScroll){
        if(progScrollTimer) clearTimeout(progScrollTimer);
        progScrollTimer = setTimeout(endProgScroll, scrollQuietMs);
        return;
      }
      userScrolled = true;
      if(rafPending) return;
      rafPending = true;
      requestAnimationFrame(function(){ rafPending = false; syncSelectionToScroll(); });
    });

    /* ---- click ---- */
    /* PRODUCT_DECISION: container listener updates selection on bubble click.
       Per-bubble action routing (popups, quote/refer/edit) is the Message's
       responsibility — it attaches its own listener that doesn't stop
       propagation, so this one still sees the click. */
    container.addEventListener('click', function(e){
      if(inBacklog) return;
      var t = e.target, hitIdx = 0;
      for(var i = 0; i < els.length; i++){
        if(els[i] === t || els[i].contains(t)){ hitIdx = i + 1; break; }
      }
      if(hitIdx > 0) settle(hitIdx, true);
    });

    /* ---- public navigation API (also called from the built-in keymap) ---- */

    function moveCursor(delta){
      var visible = visibleIdxs();
      if(!visible.length){ container.scrollTop += delta * 40; return; }
      var pos = visible.indexOf(selected);
      if(pos < 0){
        var cand = selectionCandidate();
        pos = visible.indexOf(cand);
        if(pos < 0) pos = 0;
      } else {
        pos = Math.max(0, Math.min(visible.length - 1, pos + delta));
      }
      var targetIdx = visible[pos];
      settle(targetIdx, false);
      armedScroll(function(){ revealEl(els[targetIdx - 1]); });
    }
    function cursorToExtreme(toBottom){
      armedScroll(function(){ container.scrollTop = toBottom ? container.scrollHeight : 0; });
      var visible = visibleIdxs();
      if(!visible.length) return;
      settle(toBottom ? visible[visible.length - 1] : visible[0], true);
    }
    function pageNav(dir){
      var canScroll = dir < 0
        ? container.scrollTop > 0
        : container.scrollTop + container.clientHeight < container.scrollHeight - 1;
      if(canScroll) container.scrollTop += dir * Math.max(40, container.clientHeight - 40);
      else cursorToExtreme(dir > 0);
    }

    /* ---- keyboard (the view owns its own nav keys) ---- */

    document.addEventListener('keydown', function(e){
      var ae = document.activeElement;
      if(ae && (ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT' || ae.isContentEditable)) return;
      if(e.ctrlKey || e.metaKey || e.altKey) return;
      /* PRODUCT_DECISION: switch covers the only keys the view claims —
         everything else passes through to the caller's dispatcher. */
      switch(e.key){
        case 'ArrowDown': e.preventDefault(); moveCursor(1); return;
        case 'ArrowUp':   e.preventDefault(); moveCursor(-1); return;
        case 'Home':      e.preventDefault(); cursorToExtreme(false); return;
        case 'End':       e.preventDefault(); cursorToExtreme(true); return;
        case 'PageDown':  e.preventDefault(); pageNav(1); return;
        case 'PageUp':    e.preventDefault(); pageNav(-1); return;
      }
    });

    /* ---- image-decode stabilizer ---- */

    /* BROWSER_WORKAROUND: image decode grows scrollHeight WITHOUT firing scroll
       events, so the user's anchor point drifts visually as <img>s land. We
       re-run the anchor (passed as `reapply`) on each img load/error and on
       a couple of rAF passes, up to stabilizeMs. userScrolled (set only by
       genuine user scrolls outside progScroll windows) stops us early. */
    function stabilize(reapply){
      userScrolled = false;
      var stopAt = Date.now() + stabilizeMs;
      function fire(){
        if(Date.now() > stopAt) return;
        if(userScrolled) return;
        reapply();
      }
      var imgs = list.querySelectorAll('img');
      for(var i = 0; i < imgs.length; i++){
        if(!imgs[i].complete){
          imgs[i].addEventListener('load',  fire, {once:true});
          imgs[i].addEventListener('error', fire, {once:true});
        }
      }
      requestAnimationFrame(function(){ fire(); requestAnimationFrame(fire); });
    }

    /* ---- append + accessors ---- */

    function append(data){
      var idx = els.length + 1;
      var el = renderBubble(idx, data);
      els.push(el);
      list.appendChild(el);
      return idx;
    }
    function count(){ return els.length; }
    function getElement(idx){ return els[idx - 1]; }
    function getSelected(){ return selected; }
    function select(idx, immediate){
      if(idx >= 1 && idx <= els.length) settle(idx, immediate !== false);
    }
    function revealSelected(){
      if(selected > 0) armedScroll(function(){ revealEl(els[selected - 1]); });
    }

    /* PRODUCT_DECISION: scroll a bubble to view-center (the "deep navigation
       arriving at this message" pattern). silent=true cancels any pending
       settle and applies the class only, no setSelectedBubble fire — used
       by back/forward walks that shouldn't record on the nav stack. */
    function focusBubble(idx, opts){
      opts = opts || {};
      if(idx < 1 || idx > els.length) return;
      var el = els[idx - 1];
      armedScroll(function(){ el.scrollIntoView({block:'center', behavior:'auto'}); });
      if(opts.silent){
        if(settleTimer){ clearTimeout(settleTimer); settleTimer = null; }
        applySelection(idx);
      } else {
        settle(idx, true);
      }
    }

    /* ---- backlog batch mode ---- */

    /* PRODUCT_DECISION: startBacklog/endBacklog bracket bulk DOM inserts.
       The count is informational (the view doesn't enforce it) — callers
       pass it so the view CAN reason about progress if it wants. */
    function startBacklog(_expectedCount){
      inBacklog = true;
      if(settleTimer){ clearTimeout(settleTimer); settleTimer = null; }
    }

    /* opts.focusIdx: 1..N — scroll that bubble to view-center and select it.
       opts.anchor === 'bottom' — scroll to bottom, select last visible.
       (omitted both) — leave scroll/selection alone (reconnect case).

       Image-decode stabilizer runs only when an anchor was applied. */
    function endBacklog(opts){
      inBacklog = false;
      opts = opts || {};
      if(opts.focusIdx >= 1 && opts.focusIdx <= els.length){
        focusBubble(opts.focusIdx);
        stabilize(function(){
          var el = els[opts.focusIdx - 1];
          armedScroll(function(){ el.scrollIntoView({block:'center', behavior:'auto'}); });
        });
      } else if(opts.anchor === 'bottom'){
        armedScroll(function(){ container.scrollTop = container.scrollHeight; });
        var visible = visibleIdxs();
        if(visible.length) settle(visible[visible.length - 1], true);
        stabilize(function(){
          armedScroll(function(){ container.scrollTop = container.scrollHeight; });
        });
      } else {
        /* PRODUCT_DECISION: reconnect — keep whatever scroll/selection the user had. */
        syncSelectionToScroll();
      }
    }

    return {
      append: append, count: count, getElement: getElement,
      getSelected: getSelected, select: select, focusBubble: focusBubble,
      revealSelected: revealSelected,
      moveCursor: moveCursor, cursorToExtreme: cursorToExtreme, pageNav: pageNav,
      startBacklog: startBacklog, endBacklog: endBacklog,
    };
  }

  return { create: create };
})();
