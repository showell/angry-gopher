/* ChatEmoji — the emoji whitelist, the compose-box autocomplete, and the
   reaction picker.

   PRODUCT_DECISION: emoji are a CLIENT feature. The list below is the ONE
   authority; the server never sees a shortcode. Typing `:` at the start of a
   word in the compose box opens a menu (all of the popular set, narrowing as
   you type); accepting an entry (Enter / Tab / click) or typing the closing
   colon on an exact name (`:tada:`) replaces the shortcode with the unicode
   glyph IN THE TEXTAREA — so the message body that reaches the server already
   holds the glyph, and markdown passes it through like any other text.
   Names are lowercase [a-z0-9]+ only. Every glyph is one codepoint (plus a
   variation selector where the base character is text-presentation by
   default), no ZWJ sequences, no skin tones, no flags.

   The trigger is `:` at the start of the text or after whitespace, so
   `12:30`, `http://` and `a:b` never open the menu. There is almost no reason
   to start a word with `:`, so the menu optimizes for CHOOSING, not
   dismissing — Escape or any non-matching character closes it.

   The same menu, with a filter input on top, is the reaction picker
   (`ChatEmoji.pick`), anchored to a bubble.

   Self-contained: owns its DOM (one fixed-position menu at a time) and
   injects its own CSS once. */
window.ChatEmoji = (function(){
  'use strict';

  /* PRODUCT_DECISION: menu order = this order; reactions use the same names. */
  var EMOJI = [
    { name: 'smile',      glyph: '😄' },
    { name: 'joy',        glyph: '😂' },
    { name: 'sob',        glyph: '😭' },
    { name: 'wink',       glyph: '😉' },
    { name: 'thinking',   glyph: '🤔' },
    { name: 'thumbsup',   glyph: '👍' },
    { name: 'thumbsdown', glyph: '👎' },
    { name: 'heart',      glyph: '❤️' }, /* red heart is text-presentation without VS16 */
    { name: 'tada',       glyph: '🎉' },
    { name: 'rocket',     glyph: '🚀' },
    { name: 'fire',       glyph: '🔥' },
    { name: 'eyes',       glyph: '👀' },
    { name: '100',        glyph: '💯' },
    { name: 'check',      glyph: '✅' },
    { name: 'wave',       glyph: '👋' },
    /* fitness */
    { name: 'muscle',     glyph: '💪' },
    { name: 'run',        glyph: '🏃' },
    { name: 'bike',       glyph: '🚴' },
    { name: 'swim',       glyph: '🏊' },
    /* money */
    { name: 'moneybag',   glyph: '💰' },
    { name: 'dollar',     glyph: '💵' },
    { name: 'chartup',    glyph: '📈' },
    { name: 'chartdown',  glyph: '📉' },
    /* robots */
    { name: 'robot',      glyph: '🤖' },
    { name: 'invader',    glyph: '👾' },
    { name: 'brain',      glyph: '🧠' }
  ];
  /* The compose menu is a fast path: the top matches only. The picker lists
     every match in a scrolling box. */
  var COMPOSE_ROWS = 8;

  /* PRODUCT_DECISION: widget owns its CSS. Tokens only — no hex here. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-emoji-menu { position:fixed; z-index:20; box-sizing:border-box;'
      +                  ' background:var(--cc-card-bg); color:var(--cc-fg);'
      +                  ' border:1px solid var(--cc-dialog-border); border-radius:6px;'
      +                  ' padding:4px 0; font-size:14px; box-shadow:0 4px 14px var(--cc-backdrop); }'
      + '.chat-emoji-list { max-height:232px; overflow-y:auto; }'
      + '.chat-emoji-row { display:flex; align-items:center; gap:10px; padding:4px 12px; cursor:pointer; }'
      + '.chat-emoji-row.chat-emoji-sel { background:var(--cc-search-sel-bg); }'
      + '.chat-emoji-glyph { width:1.4em; text-align:center; }'
      + '.chat-emoji-name { color:var(--cc-muted-fg); font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; }'
      + '.chat-emoji-filter { display:block; box-sizing:border-box; width:calc(100% - 16px); margin:2px 8px 6px;'
      +                     ' padding:4px 6px; font:inherit; font-size:13px;'
      +                     ' background:var(--cc-bg); color:var(--cc-fg); border:1px solid var(--cc-input-border); }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* The shortcode under the caret: {start, query} where `start` indexes the
     opening colon, or null when the caret is not right after a `:name` run
     (an empty name — a bare colon — counts). */
  function shortcodeAtCaret(textarea){
    var s = textarea.selectionStart;
    if(s !== textarea.selectionEnd) return null;
    var m = /(^|\s):([a-z0-9]*)$/.exec(textarea.value.slice(0, s));
    if(!m) return null;
    return { start: m.index + m[1].length, query: m[2] };
  }

  function matches(query, limit){
    var out = [];
    for(var i = 0; i < EMOJI.length && out.length < limit; i++){
      if(EMOJI[i].name.indexOf(query) === 0) out.push(EMOJI[i]);
    }
    return out;
  }

  // lint:called-once whitelist-lookup
  function exactMatch(query){
    for(var i = 0; i < EMOJI.length; i++) if(EMOJI[i].name === query) return EMOJI[i];
    return null;
  }

  /* glyphOf resolves a whitelisted name — the hotkeys ('+' = thumbsup) go
     through here so the glyph has one home. */
  function glyphOf(name){
    for(var i = 0; i < EMOJI.length; i++) if(EMOJI[i].name === name) return EMOJI[i].glyph;
    return null;
  }

  /* One floating menu: a list of rows with a highlighted one, plus an optional
     head element above the list. Both front ends (the compose autocomplete,
     the reaction picker) drive it; it knows nothing about either. Selection
     is kept visible with a SNAP scroll, never smooth. */
  function createMenu(onAccept){
    var el = null, list = null, rows = [], sel = 0;
    function close(){ if(el) el.remove(); el = null; list = null; rows = []; sel = 0; }
    function paint(){
      for(var i = 0; i < list.children.length; i++){
        list.children[i].classList.toggle('chat-emoji-sel', i === sel);
      }
      if(list.children[sel]) list.children[sel].scrollIntoView({ block: 'nearest' });
    }
    function show(entries, head){
      if(!el){
        el = document.createElement('div'); el.className = 'chat-emoji-menu';
        if(head) el.appendChild(head);
        list = document.createElement('div'); list.className = 'chat-emoji-list';
        el.appendChild(list);
        document.body.appendChild(el);
      }
      rows = entries;
      if(sel >= rows.length) sel = 0;
      list.textContent = '';
      rows.forEach(function(entry, i){
        var row = document.createElement('div');
        row.className = 'chat-emoji-row';
        var g = document.createElement('span'); g.className = 'chat-emoji-glyph'; g.textContent = entry.glyph;
        var n = document.createElement('span'); n.className = 'chat-emoji-name'; n.textContent = ':' + entry.name + ':';
        row.appendChild(g); row.appendChild(n);
        /* mousedown, not click: click would first blur the owner and close us. */
        row.addEventListener('mousedown', function(e){ e.preventDefault(); onAccept(entry); });
        row.addEventListener('mousemove', function(){ if(sel !== i){ sel = i; paint(); } });
        list.appendChild(row);
      });
      paint();
    }
    function move(delta){ if(rows.length){ sel = (sel + delta + rows.length) % rows.length; paint(); } }
    function accept(){ if(rows.length) onAccept(rows[sel]); }
    function resetSel(){ sel = 0; }
    function place(style){ Object.assign(el.style, style); }
    function isOpen(){ return !!el; }
    return { show: show, close: close, move: move, accept: accept, resetSel: resetSel, place: place, isOpen: isOpen };
  }

  /* ===== the compose-box autocomplete ===== */
  function attach(textarea){
    ensureStyles();
    var hit = null; /* the shortcode the menu is open for */
    var menu = createMenu(function(entry){ insert(entry, ' '); });

    /* Replace the `:query` run with the glyph (+ `tail`), caret after it. */
    function insert(entry, tail){
      textarea.setRangeText(entry.glyph + tail, hit.start, textarea.selectionStart, 'end');
      menu.close(); hit = null;
      textarea.focus();
    }

    /* PRODUCT_DECISION: anchored to the textarea's bottom-left as a fixed
       overlay, so it works wherever the textarea sits without the host
       reserving layout for it. */
    function refresh(){
      var h = shortcodeAtCaret(textarea);
      var list = h ? matches(h.query, COMPOSE_ROWS) : [];
      if(list.length === 0){ menu.close(); hit = null; return; }
      if(!hit || hit.start !== h.start) menu.resetSel();
      hit = h;
      menu.show(list, null);
      var r = textarea.getBoundingClientRect();
      menu.place({ left: (r.left + 6) + 'px', width: Math.max(120, r.width - 12) + 'px',
                   top: '', bottom: (window.innerHeight - r.bottom + 6) + 'px' });
    }

    textarea.addEventListener('input', refresh);
    textarea.addEventListener('click', refresh);
    textarea.addEventListener('blur', function(){ menu.close(); hit = null; });
    textarea.addEventListener('keydown', function(e){
      if(e.ctrlKey || e.metaKey || e.altKey){ menu.close(); hit = null; return; } /* Ctrl/⌘-Enter sends; never sit over a sent box. */
      if(e.key === ':'){
        /* Closing colon on an exact name completes it in place — no menu needed. */
        var h = shortcodeAtCaret(textarea);
        var exact = h && exactMatch(h.query);
        if(exact){ e.preventDefault(); hit = h; insert(exact, ''); }
        return;
      }
      if(!menu.isOpen()) return;
      if(e.key === 'ArrowDown'){ e.preventDefault(); menu.move(1); }
      else if(e.key === 'ArrowUp'){ e.preventDefault(); menu.move(-1); }
      else if(e.key === 'Enter' || e.key === 'Tab'){ e.preventDefault(); menu.accept(); }
      else if(e.key === 'Escape'){ e.preventDefault(); menu.close(); hit = null; }
    });
  }

  /* ===== the reaction picker =====
     pick({anchor, onPick, onClose}): the full list under a filter input,
     anchored to `anchor` (a bubble). Enter / click picks; Escape or leaving
     the input closes. onClose always fires once, picked or not, so the caller
     can hand focus back. */
  function pick(opts){
    ensureStyles();
    var closed = false;
    var input = document.createElement('input');
    input.className = 'chat-emoji-filter'; input.placeholder = 'type to filter · Enter to react';
    var menu = createMenu(function(entry){ done(); opts.onPick(entry); });
    function done(){
      if(closed) return;
      closed = true; menu.close();
      if(opts.onClose) opts.onClose();
    }
    function refresh(){ menu.show(matches(input.value.trim().toLowerCase(), EMOJI.length), input); }
    input.addEventListener('input', function(){ menu.resetSel(); refresh(); });
    input.addEventListener('keydown', function(e){
      if(e.key === 'ArrowDown'){ e.preventDefault(); menu.move(1); }
      else if(e.key === 'ArrowUp'){ e.preventDefault(); menu.move(-1); }
      else if(e.key === 'Enter'){ e.preventDefault(); menu.accept(); }
      else if(e.key === 'Escape'){ e.preventDefault(); done(); }
    });
    input.addEventListener('blur', done);
    refresh();
    var r = opts.anchor.getBoundingClientRect();
    menu.place({ left: r.left + 'px', width: '240px', bottom: '',
                 top: Math.max(8, Math.min(r.top, window.innerHeight - 300)) + 'px' });
    input.focus();
  }

  return { attach: attach, pick: pick, glyphOf: glyphOf };
})();
