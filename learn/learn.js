/* /learn client — an aspiring-developer tutorial for how chat was built.
   The page is born from an empty <div id="learn-root">; this script
   creates every element and applies styles via el.style.X directly. The
   experiment: see how far we get without writing CSS server-side.

   Lesson 1 today: chat/images.js (the per-user Image feed), with a
   spoiler that fetches the LIVE source from /learn/source/images.js and
   a small interactive demo of the shared ChatImagePopup. */
(function(){
  'use strict';

  var root = document.getElementById('learn-root');
  if(!root) return;

  /* ---- style helpers — one place to keep the page's visual language ----
     Concept: a JS object is the closest thing to a stylesheet rule when
     you're avoiding CSS. We pass these into setStyles(el, ...) and grow
     the vocabulary as the page grows. */
  function setStyles(el, styles){
    for(var k in styles) el.style[k] = styles[k];
    return el;
  }

  var COLORS = {
    ink:     '#000080',
    body:    '#222',
    muted:   '#666',
    border:  '#c9bfa7',
    surface: '#fcfcf8',
    code:    '#1a1a1a',
    codeBg:  '#f4f4ee',
  };

  /* ---- chrome: top bar, page wrap, footer ----
     PRODUCT_DECISION: top bars in this binary are STICKY — same rule on
     every page. When you build a custom JS-styled top bar like this
     one, include position:sticky/top:0/zIndex + an opaque background so
     scrolled content can't bleed through. Future-Claude: keep new pages
     consistent with this. */
  // lint:called-once page-factory
  function buildTopBar(){
    var bar = setStyles(document.createElement('header'), {
      background: '#f0ede4', borderBottom: '1px solid ' + COLORS.border,
      padding: '8px 24px', fontFamily: 'sans-serif',
      display: 'flex', justifyContent: 'space-between', alignItems: 'baseline',
      position: 'sticky', top: '0', zIndex: '10',
    });
    var left = document.createElement('div');
    var lrLink = setStyles(document.createElement('a'), {
      color: COLORS.ink, textDecoration: 'none', fontWeight: 'bold',
    });
    lrLink.href = '/'; lrLink.textContent = 'Lyn Rummy';
    var chatLink = setStyles(document.createElement('a'), {
      color: COLORS.ink, textDecoration: 'none', fontSize: '14px', marginLeft: '6px',
    });
    chatLink.href = '/chat'; chatLink.textContent = ' · Chat';
    var here = setStyles(document.createElement('span'), {
      color: COLORS.body, fontSize: '14px', marginLeft: '6px',
    });
    here.textContent = ' · Learn';
    left.appendChild(lrLink); left.appendChild(chatLink); left.appendChild(here);
    bar.appendChild(left);
    return bar;
  }

  // lint:called-once page-factory
  function buildWrap(){
    return setStyles(document.createElement('div'), {
      maxWidth: '780px', margin: '32px auto', padding: '0 24px 80px',
      fontFamily: 'sans-serif', color: COLORS.body, lineHeight: '1.55',
    });
  }

  /* ---- spoiler widget: a button that toggles a hidden region.
     First open triggers fetchOnce, so the source isn't loaded until the
     reader actually asks. Subsequent toggles flip display only. ---- */
  // lint:called-once widget — reused per lesson
  function buildSpoiler(opts){
    /* opts: { label, openLabel, render(container) }
       label       — the button text when closed (e.g. "Show source (87 lines)")
       openLabel   — the button text when open  (e.g. "Hide source")
       render(box) — called ONCE on first open; populates the box. */
    var wrap = document.createElement('div');
    var btn = setStyles(document.createElement('button'), {
      background: COLORS.ink, color: 'white', border: 'none',
      padding: '8px 14px', fontSize: '14px', cursor: 'pointer',
      borderRadius: '4px', marginBottom: '8px',
    });
    btn.type = 'button'; btn.textContent = opts.label;
    var box = setStyles(document.createElement('div'), {
      display: 'none', border: '1px solid ' + COLORS.border,
      borderRadius: '6px', background: COLORS.surface, padding: '12px',
    });
    var rendered = false;
    btn.addEventListener('click', function(){
      var opening = box.style.display === 'none';
      if(opening && !rendered){ opts.render(box); rendered = true; }
      box.style.display = opening ? 'block' : 'none';
      btn.textContent = opening ? opts.openLabel : opts.label;
    });
    wrap.appendChild(btn); wrap.appendChild(box);
    return wrap;
  }

  /* ---- code block: monospace <pre><code> with the page's visual language.
     One styled wrapper, two filling strategies — inline text (buildCodeBlock)
     and async fetch (buildSourcePanel). ---- */
  // lint:called-once widget — reused per lesson
  function buildCodeBlock(text){
    var pre = setStyles(document.createElement('pre'), {
      margin: '0', padding: '12px 14px', background: COLORS.codeBg,
      color: COLORS.code, fontFamily: 'ui-monospace, Menlo, Consolas, monospace',
      fontSize: '13px', lineHeight: '1.5', borderRadius: '4px',
      overflowX: 'auto', whiteSpace: 'pre',
    });
    var code = document.createElement('code');
    code.textContent = text;
    pre.appendChild(code);
    return pre;
  }

  // lint:called-once widget — reused per lesson
  function buildSourcePanel(url){
    var pre = buildCodeBlock('Loading…');
    var code = pre.firstChild;
    fetch(url).then(function(r){
      if(!r.ok) throw new Error('fetch failed: ' + r.status);
      return r.text();
    }).then(function(text){
      code.textContent = text;
    }).catch(function(err){
      code.textContent = 'failed to load ' + url + ': ' + err.message;
    });
    return pre;
  }

  /* ---- meta code-popup demo: fetches a JS source file, renders it as a
     clickable code block, and on click hands that exact text to
     ChatCodePopup.show. The popup ends up displaying its own source — the
     reader sees the code, clicks it, and the code goes into the popup the
     code itself implements. ---- */
  // lint:called-once page-factory
  function buildCodePopupDemo(url){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });
    var caption = setStyles(document.createElement('div'), {
      fontSize: '13px', color: COLORS.muted, marginBottom: '10px',
    });
    caption.textContent = 'Demo: click the code below to open it in the popup it implements.';
    var pre = buildCodeBlock('Loading…');
    var code = pre.firstChild;
    setStyles(pre, { cursor: 'pointer' });
    fetch(url).then(function(r){
      if(!r.ok) throw new Error('fetch failed: ' + r.status);
      return r.text();
    }).then(function(text){
      code.textContent = text;
      pre.addEventListener('click', function(){
        if(window.ChatCodePopup) ChatCodePopup.show(text);
      });
    }).catch(function(err){
      code.textContent = 'failed to load ' + url + ': ' + err.message;
    });
    box.appendChild(caption); box.appendChild(pre);
    return box;
  }

  /* ---- popup demo: a small caption + a button that calls
     ChatImagePopup.show(<test image>). The exact integration images.js
     uses, isolated to one click. ---- */
  // lint:called-once page-factory
  function buildPopupDemo(){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });
    var caption = setStyles(document.createElement('div'), {
      fontSize: '13px', color: COLORS.muted, marginBottom: '10px',
    });
    caption.textContent = 'Demo: click the cat to open the same popup the chat uses.';
    var img = setStyles(document.createElement('img'), {
      maxWidth: '160px', maxHeight: '160px', display: 'block',
      borderRadius: '6px', cursor: 'zoom-in', border: '1px solid ' + COLORS.border,
    });
    img.alt = 'Cat professor';
    img.src = '/images/cat_professor.webp';
    img.addEventListener('click', function(){
      if(window.ChatImagePopup) ChatImagePopup.show(img.src);
    });
    box.appendChild(caption); box.appendChild(img);
    return box;
  }

  /* ---- explanatory paragraph: when a lesson has more to say than the
     section's one-line lede. ---- */
  // lint:called-once widget — reused per lesson
  function buildParagraph(text){
    return setStyles(
      Object.assign(document.createElement('p'), { textContent: text }),
      { margin: '0 0 12px', color: COLORS.body }
    );
  }

  /* ---- Lesson 0 second demo: LearnFakeHost. Register a /ping route,
     wire a button to fetch it, log both sides of the round-trip. ---- */
  // lint:called-once page-factory
  function buildFakeHostDemo(){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });
    var hint = setStyles(document.createElement('p'), {
      margin: '0 0 10px', color: COLORS.muted, fontSize: '13px',
    });
    hint.textContent = 'Click "fetch /learn/lesson0-fake/ping" — the call goes through real fetch, '
      + 'LearnFakeHost matches the URL against this demo\'s registered route, and the route\'s '
      + 'respond() returns a fake Response. Lessons 7, 8, and 9 use the same registration to '
      + 'simulate their hosts.';

    var clog = LearnCallbackLog.create({ height: '180px' });

    /* Register a tiny ping route — string-match against the literal URL. */
    LearnFakeHost.register({
      match: '/learn/lesson0-fake/ping',
      respond: function(ctx){
        clog.log('LearnFakeHost matched ' + ctx.url + ' → calling respond()');
        return Promise.resolve({
          ok: true,
          text: function(){ return Promise.resolve('pong'); },
        });
      },
    });

    var btnRow = setStyles(document.createElement('div'), {
      display: 'flex', gap: '8px', flexWrap: 'wrap', marginBottom: '8px',
    });
    var pingBtn = document.createElement('button');
    pingBtn.type = 'button';
    pingBtn.textContent = 'fetch("/learn/lesson0-fake/ping")';
    pingBtn.addEventListener('click', function(){
      clog.log('caller: fetch("/learn/lesson0-fake/ping")');
      fetch('/learn/lesson0-fake/ping').then(function(r){
        return r.text();
      }).then(function(t){
        clog.log('caller: received "' + t + '"');
      });
    });
    btnRow.appendChild(pingBtn);

    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(hint);
    leftCol.appendChild(btnRow);
    twoCol.appendChild(leftCol); twoCol.appendChild(clog.element);
    box.appendChild(twoCol);
    return box;
  }

  /* ---- Lesson 0 first demo: the LearnCallbackLog widget itself.
     Three "event" buttons each call clog.log(...) so the reader sees
     the widget receiving events the same way real-system widgets
     feed their callers. ---- */
  // lint:called-once page-factory
  function buildCallbackLogDemo(){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });
    var hint = setStyles(document.createElement('p'), {
      margin: '0 0 10px', color: COLORS.muted, fontSize: '13px',
    });
    hint.textContent = 'Click the buttons to send events into the log. The widget owns the column, '
      + 'the caption, and the fixed-height scrolling body — auto-scrolling to keep the latest entry '
      + 'in view. Every other lesson drops the same widget into its demo.';

    var clog = LearnCallbackLog.create();

    var btnRow = setStyles(document.createElement('div'), {
      display: 'flex', gap: '8px', flexWrap: 'wrap', marginBottom: '8px',
    });
    var counter = 0;
    function mkBtn(label, msg){
      var b = document.createElement('button');
      b.type = 'button'; b.textContent = label;
      b.addEventListener('click', function(){ clog.log(msg + ' (#' + (++counter) + ')'); });
      return b;
    }
    btnRow.appendChild(mkBtn('Fire onSelect',   'onSelect(42)'));
    btnRow.appendChild(mkBtn('Fire onChange',   'onChange("draft")'));
    btnRow.appendChild(mkBtn('Fire onComplete', 'onComplete({ok:true})'));
    var clearBtn = document.createElement('button');
    clearBtn.type = 'button'; clearBtn.textContent = 'Clear';
    clearBtn.addEventListener('click', function(){ clog.clear(); counter = 0; });
    btnRow.appendChild(clearBtn);

    /* Side-by-side: buttons + hint on the left, the log on the right —
       same shape every later lesson uses. */
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(hint);
    leftCol.appendChild(btnRow);
    twoCol.appendChild(leftCol); twoCol.appendChild(clog.element);
    box.appendChild(twoCol);
    return box;
  }

  /* ---- message demo: the meat of Lesson 3. Builds three server-shaped
     messages, wires their callbacks to a visible log panel, and renders
     the bubbles with NO chat CSS loaded — the widget owns DOM + behavior,
     not styling. Clicking around shows callback flow + body-click
     delegation to ChatImagePopup / ChatCodePopup. ---- */
  // lint:called-once page-factory
  function buildMessageDemo(){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });

    /* Three server-shaped message objects. `html` would be produced by the
       server's markdown renderer; here we author it directly. */
    var messages = [
      { id: 'demo_001', index: 0, from: 'Alice', mine: false, at: '2026-06-16T13:30:00Z',
        body: 'Hey 👋',
        html: 'Hey there 👋' },
      { id: 'demo_002', index: 1, from: 'You', mine: true, at: '2026-06-16T13:31:00Z',
        body: 'Try clicking the image or the code block',
        html: 'Try clicking either of these:<br>'
            + '<img src="/images/cat_professor.webp" style="max-width:140px;cursor:zoom-in"><br>'
            + '<pre>console.log("hi from the demo");</pre>' },
      { id: 'demo_003', index: 2, from: 'Alice', mine: false, at: '2026-06-16T13:32:00Z',
        body: 'See MSG_demo_002',
        html: 'See <a class="msg-ref" href="#msg-demo_002">MSG_demo_002</a> 👆' },
    ];

    /* The callback log — visible proof that the widget hands off without
       deciding what should happen. Drop-in shared widget (see Lesson 0). */
    var clog = LearnCallbackLog.create();
    var callbacks = {
      onQuote:  function(r){    clog.log('onQuote(MSG_'  + r.id + ')'); },
      onRefer:  function(r){    clog.log('onRefer(MSG_'  + r.id + ')'); },
      onEdit:   function(r){    clog.log('onEdit(MSG_'   + r.id + ')'); },
      onMsgRef: function(link){ clog.log('onMsgRef('     + link.getAttribute('href') + ')'); },
    };

    /* A plain container — the bubbles bring their own visual chrome
       (Message injects its stylesheet on first create()), so the wrapper
       just provides a neutral white surface. */
    var bubbles = setStyles(document.createElement('div'), {
      background: '#fff', padding: '4px 8px',
    });
    messages.forEach(function(d){
      bubbles.appendChild(Message.create(d, callbacks).render());
    });

    var hint = setStyles(document.createElement('p'), {
      margin: '0 0 10px', color: COLORS.muted, fontSize: '13px',
    });
    hint.textContent = 'Demo: three bubbles, no chat CSS loaded on this page — Message brought its own. '
      + 'Click the buttons (quote-reply / refer / edit), the image, the code block, or the MSG_ link. '
      + 'Watch the log on the right: that’s the page acting on what the widget reports.';

    /* Side-by-side: bubbles on the left flex to fill; the log column
       brings its own fixed width (LearnCallbackLog defaults to 260px). */
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(bubbles);
    twoCol.appendChild(leftCol); twoCol.appendChild(clog.element);

    box.appendChild(hint);
    box.appendChild(twoCol);
    return box;
  }

  /* ---- shared infrastructure for Lessons 4 + 5 ----
     Three small helpers build the common scaffolding both lessons need:
     a 36-bubble MessageView, a fixed-height auto-scrolling log panel,
     and the two-column layout. Lesson 4's demo wires setSelectedBubble
     to the log only; Lesson 5's demo additionally instantiates a
     NavStack and wires Back/Forward buttons. ---- */

  var SURFACE_HEIGHT = '220px';

  // lint:called-once widget — shared by Lessons 4 + 5
  function buildColoredScroller(onSelected){
    /* Three colors, twelve-entry size cycle repeated to 36 bubbles —
       enough to overflow the scroll container so the reader sees
       scroll-driven selection in action, and to feel the
       burst-of-keypresses → 700ms debounce in the log. */
    var palette = ['#e74c3c', '#27ae60', '#3498db']; // red, green, blue
    var sizeCycle = [
      [120, 36], [180, 52], [ 90, 30], [220, 64], [150, 44], [110, 38],
      [200, 56], [ 80, 32], [170, 60], [140, 42], [190, 48], [100, 34],
    ];
    var dims = [];
    for(var i = 0; i < 36; i++) dims.push(sizeCycle[i % sizeCycle.length]);

    /* tabindex so the container can hold keyboard focus when the reader
       clicks — MessageView's keydown listener is scoped to the container
       here (no hijacking page-wide arrows). */
    var scroller = setStyles(document.createElement('div'), {
      height: SURFACE_HEIGHT, overflow: 'auto',
      border: '1px solid #ccc', borderRadius: '4px',
      background: '#fff', padding: '8px', boxSizing: 'border-box',
    });
    scroller.tabIndex = 0;

    var view = MessageView.create({
      container: scroller,
      scopeKeysToContainer: true,
      renderBubble: function(idx, data){
        var div = document.createElement('div');
        Object.assign(div.style, {
          background: data.color, width: data.w + 'px', height: data.h + 'px',
          margin: '6px 0', borderRadius: '4px',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'white', fontFamily: 'sans-serif', fontSize: '13px', fontWeight: 'bold',
        });
        div.textContent = '#' + idx;
        return div;
      },
      setSelectedBubble: onSelected,
    });

    /* Fill via the same backlog protocol the chat page uses on initial
       load: startBacklog → many append → endBacklog. anchor:'bottom'
       scrolls to the bottom and selects the last bubble. */
    view.startBacklog(dims.length);
    dims.forEach(function(d, i){
      view.append({ color: palette[i % palette.length], w: d[0], h: d[1] });
    });
    view.endBacklog({ anchor: 'bottom' });

    return { scroller: scroller, view: view };
  }

  // lint:called-once widget — shared by Lessons 4 + 5
  function buildScrollerLogLayout(scroller, logColumn){
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(scroller);
    twoCol.appendChild(leftCol); twoCol.appendChild(logColumn);
    return twoCol;
  }

  /* ---- Lesson 4 demo: MessageView in isolation, callback just logs. ---- */
  // lint:called-once page-factory
  function buildMessageViewDemo(){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });
    var hint = setStyles(document.createElement('p'), {
      margin: '0 0 10px', color: COLORS.muted, fontSize: '13px',
    });
    hint.textContent = 'Demo: 36 opaque rectangles instead of chat bubbles. '
      + 'Click one, scroll the container, or click into it and hold an arrow key. '
      + 'The yellow ring follows every press instantly — but setSelectedBubble waits '
      + 'for a 700ms rest before reporting, so a burst of presses only logs the place '
      + 'you SETTLED, not every intermediate step. The callback fires into the void here; '
      + 'Lesson 5 wires it up to the nav stack.';
    var clog = LearnCallbackLog.create();
    var scr = buildColoredScroller(function(idx){
      clog.log('setSelectedBubble(' + idx + ')');
    });
    box.appendChild(hint);
    box.appendChild(buildScrollerLogLayout(scr.scroller, clog.element));
    return box;
  }

  /* ---- Lesson 5 demo: same scroller, plus a NavStack instance and two
     native <button>s for Back/Forward. Additive on top of Lesson 4 —
     the helpers do the same job; the new wiring lives here. ---- */
  // lint:called-once page-factory
  function buildNavStackDemo(){
    var box = setStyles(document.createElement('div'), {
      border: '1px solid ' + COLORS.border, borderRadius: '6px',
      background: COLORS.surface, padding: '14px 16px', marginTop: '10px',
    });
    var hint = setStyles(document.createElement('p'), {
      margin: '0 0 10px', color: COLORS.muted, fontSize: '13px',
    });
    hint.textContent = 'Demo: same 36 rectangles, plus a NavStack instance and two unstyled '
      + 'browser-default buttons. Click bubbles, scroll, or use arrows to settle on places — each '
      + 'settle pushes onto the stack. Click Back to retrace; click Forward to undo a Back. Scroll '
      + 'after a click to drift off the cursor, then click Back — it recovers, doesn’t pop.';

    /* Plain <button>s: no Object.assign(button.style, ...). Want the
       reader to see them as raw bindings, not styled UI. */
    var backBtn = document.createElement('button'); backBtn.textContent = 'Back';
    var fwdBtn  = document.createElement('button'); fwdBtn.textContent  = 'Forward';
    var buttonRow = document.createElement('div');
    buttonRow.style.margin = '0 0 10px';
    buttonRow.appendChild(backBtn);
    buttonRow.appendChild(document.createTextNode(' '));
    buttonRow.appendChild(fwdBtn);

    var clog = LearnCallbackLog.create();

    /* Forward-reference: the callback closes over `nav` (declared
       here, assigned below). buildColoredScroller runs endBacklog
       synchronously, which fires setSelectedBubble once for the
       anchored bubble — before nav exists. Guard the push; the
       initial selection wasn't a user action anyway, so dropping it
       on the floor matches the chat page's behavior. */
    var nav;
    var scr = buildColoredScroller(function(idx){
      clog.log('setSelectedBubble(' + idx + ')');
      if(nav) nav.push(idx);
    });

    nav = NavStack.create({
      gotoMessage: function(entry){
        clog.log('gotoMessage(' + entry + ')');
        scr.view.focusBubble(entry, {silent:true});
      },
      onChange: function(canBack, canFwd){
        backBtn.disabled = !canBack;
        fwdBtn.disabled  = !canFwd;
      },
      currentSelection: scr.view.getSelected,
    });
    backBtn.addEventListener('click', nav.back);
    fwdBtn.addEventListener('click', nav.forward);

    box.appendChild(hint);
    box.appendChild(buttonRow);
    box.appendChild(buildScrollerLogLayout(scr.scroller, clog.element));
    return box;
  }

  /* ---- Lesson 6 demo: ChatMiddlePane.init wired with the real
     Message factory and a small batch of simulated server responses
     (same wire shape as the chat conversation page's SSE — index,
     from, at, html, markdown, id, mine). The html field is what the
     server's markdown renderer would have produced; everything else is
     JS the reader has already seen. ---- */

  // lint:called-once widget
  function buildMiddlePaneDemo(){
    /* Six simulated SSE payloads in the same shape the real stream
       emits. The `html` field is what the server would have rendered
       from the `markdown` source — written by hand here so the demo
       doesn't need a Go round-trip. */
    var fakeMessages = [
      { from: 'apoorva', at: '2026-06-16T13:00:00Z', mine: false, id: 'demo_1',
        markdown: 'Hi! I just finished lesson 5 about **nav_stack**. Are these demos using real chat data?',
        html: '<p>Hi! I just finished lesson 5 about <strong>nav_stack</strong>. Are these demos using real chat data?</p>' },
      { from: 'Claude',  at: '2026-06-16T13:01:00Z', mine: true,  id: 'demo_2',
        markdown: 'No — the earlier lessons used colored rectangles to keep the focus on the widget itself...',
        html: '<p>No — the earlier lessons used colored rectangles to keep the focus on the widget itself. Lesson 6 finally introduces real messages.</p>'
            + '<p>The data shape is what the SSE stream sends: <code>{from, at, html, markdown, id, mine}</code> — <code>at</code> is the RFC3339 instant, rendered in your local zone (click it for the world clock). Hand it to <code>Message.create</code> and you get a bubble.</p>' },
      { from: 'apoorva', at: '2026-06-16T13:02:00Z', mine: false, id: 'demo_3',
        markdown: 'So the html field is already rendered? What does the JS side do then?',
        html: '<p>So the <code>html</code> field is already rendered? What does the JS side do then?</p>' },
      { from: 'Claude',  at: '2026-06-16T13:03:00Z', mine: true,  id: 'demo_4',
        markdown: 'Right — the server runs the markdown through its renderer, sanitizes it, and post-processes MSG_ tokens...',
        html: '<p>Right — the server runs the markdown through its renderer, sanitizes it, and post-processes MSG_ tokens into msg-ref links (see <a href="#msg-demo_1" class="msg-ref">MSG_demo_1</a>). The JS just <code>innerHTML</code>s it.</p>'
            + '<p>Code blocks land in <code>&lt;pre&gt;</code> tags — clickable too:</p>'
            + '<pre class="chat-quote">function hi(){ return \'world\'; }</pre>' },
      { from: 'apoorva', at: '2026-06-16T13:04:00Z', mine: false, id: 'demo_5',
        markdown: 'And images?',
        html: '<p>And images?</p>'
            + '<p><img src="/images/cat_professor.webp" alt="cat professor"></p>' },
      { from: 'Claude',  at: '2026-06-16T13:05:00Z', mine: true,  id: 'demo_6',
        markdown: 'Same path — markdown has ![alt](src), the server renders it as <img>, Message wires the click to the popup.',
        html: '<p>Same path — the markdown has <code>![alt](src)</code>, the server renders it as <code>&lt;img&gt;</code>, Message wires the click to the popup. Try clicking the cat above.</p>'
            + '<p>Click <a href="#msg-demo_1" class="msg-ref">MSG_demo_1</a> and the pane scrolls back + selects that bubble — your current position goes on the nav stack, so Back returns you here.</p>' },
    ];

    var wrapper = setStyles(document.createElement('div'), {
      height: '440px', display: 'flex',
      border: '1px solid #ccc', borderRadius: '4px',
      padding: '8px', background: '#fafafa', boxSizing: 'border-box',
    });
    var mount = document.createElement('div');
    wrapper.appendChild(mount);

    /* Same id→record lookup chat.js maintains for cross-message
       navigation. msg-ref clicks find their target through this. */
    var recordsById = Object.create(null);
    var pane;
    function navigateRef(linkEl){
      var id = (linkEl.getAttribute('href') || '').replace(/^#msg-/, '');
      var rec = recordsById[id];
      if(rec) pane.focusBubble(rec.index + 1);
    }

    pane = ChatMiddlePane.init({
      mount: mount,
      scopeKeysToContainer: true,
      renderBubble: function(idx, data){
        var msg = Message.create(data, {
          /* The real chat.js routes these into the compose box; the
             demo just announces the verb so the buttons aren't dead.
             onQuote/onRefer/onEdit receive the SSE record — data, not
             a widget. */
          onQuote:  function(r){ alert('quote-reply to MSG_' + r.id); },
          onRefer:  function(r){ alert('insert "See MSG_' + r.id + '" into compose'); },
          onEdit:   function(r){ alert('compose "Edit of MSG_' + r.id + '"'); },
          onMsgRef: navigateRef,
        });
        recordsById[data.id] = data;
        return msg.render();
      },
    });

    pane.startBacklog(fakeMessages.length);
    fakeMessages.forEach(function(m, i){
      pane.append({
        index: i, from: m.from, time: m.time,
        html: m.html, markdown: m.markdown, id: m.id, mine: m.mine,
      });
    });
    pane.endBacklog({ anchor: 'bottom' });

    return wrapper;
  }

  /* ---- Lesson 7 demo: the right rail.
     ChatRightSidebar builds the wrapper + closed-panel + Open-compose
     button; ChatCompose builds the open-state form and runs the send
     state machine (POST → wait for SSE echo → clear textarea). We
     monkey-patch fetch on the demo's fake SESSION_BASE so the reader
     can choose what happens next: a fake echo arrives in 800ms, or
     the host stays silent and the 3s timer trips hostDown. ---- */

  // lint:called-once widget
  function buildRightRailDemo(){
    var wrapper = setStyles(document.createElement('div'), {
      display: 'flex', flexDirection: 'column', gap: '10px',
      border: '1px solid #ccc', borderRadius: '4px',
      padding: '10px', background: '#fafafa', boxSizing: 'border-box',
    });

    /* "Next send" mode toggle — picks how the fake server responds
       to the next POST /send. Default is echo (the happy path). */
    var nextMode = 'echo';
    var controls = setStyles(document.createElement('div'), {
      fontSize: '13px', color: '#555', display: 'flex', gap: '14px',
      alignItems: 'center', flexWrap: 'wrap',
    });
    var modeLabel = document.createElement('span');
    modeLabel.textContent = 'Next send:';
    controls.appendChild(modeLabel);
    var modes = [
      { value: 'echo',   label: 'echo arrives in 800ms (success)' },
      { value: 'silent', label: 'host silent → 3s timeout' },
    ];
    modes.forEach(function(m){
      var lbl = document.createElement('label');
      lbl.style.cursor = 'pointer';
      var r = document.createElement('input');
      r.type = 'radio'; r.name = 'lesson7-mode'; r.value = m.value;
      if(m.value === nextMode) r.checked = true;
      r.addEventListener('change', function(){ if(r.checked) nextMode = m.value; });
      lbl.appendChild(r); lbl.appendChild(document.createTextNode(' ' + m.label));
      controls.appendChild(lbl);
    });
    wrapper.appendChild(controls);

    /* Hint line above the side-by-side rail+log. */
    var hint = setStyles(document.createElement('p'), {
      margin: '0', fontSize: '12px', color: '#888',
    });
    hint.textContent = 'Click "Open compose box", type a message, hit Send. '
      + 'Watch the textarea + buttons disable while "Sending…" sits in the status line, '
      + 'and watch the callback log on the right narrate the round-trip. '
      + 'The Image button works too — pick a file, the fake server returns a JSON pointer, '
      + 'and ChatCompose inserts an <img> tag at the cursor.';
    wrapper.appendChild(hint);

    /* The callback log — visible proof of the send state machine. We
       hook the two observable round-trip points: the fake-server POST
       handler (entry: "POST received"), and our setTimeout that fires
       ChatCompose.ackIfPending (exit: "echo arrived → ack fired"). For
       the silent path we just log the entry and note that hostDown will
       trip from inside ChatCompose without our help. Drop-in shared
       widget (see Lesson 0). */
    var clog = LearnCallbackLog.create({height: '300px'});
    function log(line){ clog.log(line); }

    /* Left: the rail mount. Right: the callback log column. */
    var mountWrapper = setStyles(document.createElement('div'), {
      background: '#fff', border: '1px solid #ddd', borderRadius: '4px',
      padding: '12px', boxSizing: 'border-box', minHeight: '320px',
    });
    var mountSlot = document.createElement('div');
    mountWrapper.appendChild(mountSlot);

    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(mountWrapper);
    twoCol.appendChild(leftCol); twoCol.appendChild(clog.element);
    wrapper.appendChild(twoCol);

    /* PRODUCT_DECISION: register the two routes with LearnFakeHost
       (Lesson 0). The host owns the fetch wrap; we just declare
       URL → response mappings. Each route's respond reads nextMode
       from this demo's closure for the echo/silent toggle. */
    var FAKE_BASE = '/learn/lesson7-fake';
    LearnFakeHost.register({
      match: FAKE_BASE + '/send',
      respond: function(ctx){
        var body = (ctx.opts && ctx.opts.body) || '';
        var cidMatch = body.match(/cid=([^&]+)/);
        var cid = cidMatch ? decodeURIComponent(cidMatch[1]) : null;
        var shortCid = cid ? cid.slice(0, 8) + '…' : '?';
        log('POST /send received (cid=' + shortCid + ', mode=' + nextMode + ')');
        if(nextMode === 'echo' && cid){
          log('  → scheduling fake SSE echo in 800ms');
          setTimeout(function(){
            log('SSE echo arriving — calling ChatCompose.ackIfPending(' + shortCid + ')');
            ChatCompose.ackIfPending(cid);
            log('  → textarea cleared, form re-enabled');
          }, 800);
        } else {
          log('  → no echo will be sent; ChatCompose\'s 3s hostDown will trip');
        }
        return Promise.resolve({ ok: true });
      },
    });
    LearnFakeHost.register({
      match: FAKE_BASE + '/upload',
      respond: function(ctx){
        var fd = ctx.opts && ctx.opts.body;
        var file = (fd && fd.get) ? fd.get('file') : null;
        var name = file ? file.name : '?';
        var kb = file ? (file.size/1024).toFixed(1) + ' KB' : '?';
        log('POST /upload received (file=' + name + ', ' + kb + ')');
        var fakeResp = { name: name, url: '/simulated-link-from-mock-server',
                         width: 320, height: 240 };
        log('  → returning JSON {url=' + fakeResp.url + ', '
          + fakeResp.width + 'x' + fakeResp.height + '}');
        log('  → ChatCompose inserts <img> tag at cursor');
        return Promise.resolve({
          ok: true,
          json: function(){ return Promise.resolve(fakeResp); },
        });
      },
    });

    /* Init in the same order chat.js does: right sidebar first
       (builds the wrapper class + closed-panel + Open button), then
       compose (inserts its body before the closed-panel and registers
       it for the open/closed toggle). No ChatHelp here — the keyhelp
       panel is Lesson 4's territory; the closed state in the demo
       shows just the Open-compose button. */
    ChatRightSidebar.init({
      mount:   mountSlot,
      onOpen:  function(){ ChatCompose.focus(); },
      onClose: function(){},
    });
    ChatCompose.init({
      sessionBase: FAKE_BASE,
      closeCompose: ChatRightSidebar.closeCompose,
    });

    return wrapper;
  }

  /* ---- Lesson 8 demo: the Add Topic form.
     ChatAddTopic.create returns a presentational form that owns
     validation (TOPIC_RE: letters/digits/hyphens, no leading/trailing
     hyphen), the POST to /chat/c/<conv>/new, and the inline error
     display. It does NOT navigate; the caller's onCreated callback
     decides what to do with the new {conv, sid}. The demo
     monkey-patches fetch for the demo's fake conv URL (same shape as
     Lesson 7), and passes a logging onCreated so success doesn't
     navigate away from /learn. ---- */

  // lint:called-once widget
  function buildAddTopicDemo(){
    var wrapper = setStyles(document.createElement('div'), {
      display: 'flex', flexDirection: 'column', gap: '10px',
      border: '1px solid #ccc', borderRadius: '4px',
      padding: '10px', background: '#fafafa', boxSizing: 'border-box',
    });

    /* "Next submit" toggle — picks how the fake server responds.
       Default is succeed. */
    var nextMode = 'succeed';
    var controls = setStyles(document.createElement('div'), {
      fontSize: '13px', color: '#555', display: 'flex', gap: '14px',
      alignItems: 'center', flexWrap: 'wrap',
    });
    var modeLabel = document.createElement('span');
    modeLabel.textContent = 'Next submit:';
    controls.appendChild(modeLabel);
    var modes = [
      { value: 'succeed', label: 'host accepts' },
      { value: 'reject',  label: 'host rejects ("topic already exists")' },
    ];
    modes.forEach(function(m){
      var lbl = document.createElement('label');
      lbl.style.cursor = 'pointer';
      var r = document.createElement('input');
      r.type = 'radio'; r.name = 'lesson8-mode'; r.value = m.value;
      if(m.value === nextMode) r.checked = true;
      r.addEventListener('change', function(){ if(r.checked) nextMode = m.value; });
      lbl.appendChild(r); lbl.appendChild(document.createTextNode(' ' + m.label));
      controls.appendChild(lbl);
    });
    wrapper.appendChild(controls);

    /* Hint paragraph above the side-by-side form+log. */
    var hint = setStyles(document.createElement('p'), {
      margin: '0', fontSize: '12px', color: '#888',
    });
    hint.textContent = 'Type a topic name and hit Add Topic. Watch the callback log on '
      + 'the right narrate validation → POST → response → onCreated. Try invalid input '
      + '("foo--bar", "-foo", "foo!") to see the client-side TOPIC_RE rejection — no '
      + 'fetch fires, the error displays under the input.';
    wrapper.appendChild(hint);

    /* Callback log — drop-in shared widget (see Lesson 0). */
    var clog = LearnCallbackLog.create();
    function log(line){ clog.log(line); }

    /* PRODUCT_DECISION: register the route with LearnFakeHost
       (Lesson 0) — the host owns the fetch wrap. */
    var FAKE_CONV = 'lesson8-fake';
    var NEW_URL = '/chat/c/' + FAKE_CONV + '/new';
    LearnFakeHost.register({
      match: NEW_URL,
      respond: function(ctx){
        var body = (ctx.opts && ctx.opts.body) || '';
        var topicMatch = body.match(/topic=([^&]+)/);
        var topic = topicMatch ? decodeURIComponent(topicMatch[1]) : '?';
        log('POST ' + NEW_URL + ' (topic=' + topic + ', mode=' + nextMode + ')');
        if(nextMode === 'succeed'){
          var resp = { conv: FAKE_CONV, sid: topic };
          log('  → host returns {ok:true, conv=' + resp.conv + ', sid=' + resp.sid + '}');
          return Promise.resolve({
            ok: true,
            json: function(){ return Promise.resolve(resp); },
          });
        }
        var errMsg = 'topic already exists';
        log('  → host returns {ok:false} with body: "' + errMsg + '"');
        return Promise.resolve({
          ok: false,
          text: function(){ return Promise.resolve(errMsg); },
        });
      },
    });

    /* Build the form with a logging onCreated — no navigation. */
    var formMount = setStyles(document.createElement('div'), {
      background: '#fff', border: '1px solid #ddd', borderRadius: '4px',
      padding: '12px', boxSizing: 'border-box',
    });
    formMount.appendChild(ChatAddTopic.create({
      convBase: '/chat/c/' + FAKE_CONV,
      onCreated: function(j){
        log('onCreated({conv: ' + j.conv + ', sid: ' + j.sid + '}) — caller would navigate to '
          + '/chat/c/' + j.conv + '/' + j.sid);
      },
    }));

    /* Side-by-side: form on the left, log on the right. */
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(formMount);
    twoCol.appendChild(leftCol); twoCol.appendChild(clog.element);
    wrapper.appendChild(twoCol);

    return wrapper;
  }

  /* ---- Lesson 9 demo: ChatDragToPin.
     Two stacked lists (Pinned + Sessions) playing the role of the
     real left sidebar's drop targets. Each item is an <li> with
     data-sid; each list has data-section so the widget can tell
     "pinned" from "everything else." Mock fetch handles the pin/unpin
     POST and delays its response so the optimistic move is visible
     for ~700ms before the revert (in failure mode). ---- */

  // lint:called-once widget
  function buildDragToPinDemo(){
    var wrapper = setStyles(document.createElement('div'), {
      display: 'flex', flexDirection: 'column', gap: '10px',
      border: '1px solid #ccc', borderRadius: '4px',
      padding: '10px', background: '#fafafa', boxSizing: 'border-box',
    });

    /* "Next pin/unpin" toggle — pick whether the host accepts the
       optimistic move or rejects it (triggering the revert). */
    var nextMode = 'accept';
    var controls = setStyles(document.createElement('div'), {
      fontSize: '13px', color: '#555', display: 'flex', gap: '14px',
      alignItems: 'center', flexWrap: 'wrap',
    });
    var modeLabel = document.createElement('span');
    modeLabel.textContent = 'Next pin/unpin:';
    controls.appendChild(modeLabel);
    var modes = [
      { value: 'accept', label: 'host accepts' },
      { value: 'reject', label: 'host rejects → optimistic move reverts' },
    ];
    modes.forEach(function(m){
      var lbl = document.createElement('label');
      lbl.style.cursor = 'pointer';
      var r = document.createElement('input');
      r.type = 'radio'; r.name = 'lesson9-mode'; r.value = m.value;
      if(m.value === nextMode) r.checked = true;
      r.addEventListener('change', function(){ if(r.checked) nextMode = m.value; });
      lbl.appendChild(r); lbl.appendChild(document.createTextNode(' ' + m.label));
      controls.appendChild(lbl);
    });
    wrapper.appendChild(controls);

    var hint = setStyles(document.createElement('p'), {
      margin: '0', fontSize: '12px', color: '#888',
    });
    hint.textContent = 'Drag a row between the two lists. Watch the callback log narrate the '
      + 'gesture: onDrop fires immediately (the optimistic move), then we POST to the host. '
      + 'In "reject" mode the response takes ~700ms, and you\'ll see onDrop fire a second time '
      + 'with reversed source/target to revert.';
    wrapper.appendChild(hint);

    /* The callback log — drop-in shared widget (see Lesson 0). */
    var clog = LearnCallbackLog.create({ height: '280px' });

    /* PRODUCT_DECISION: inline list styling — chat_left_sidebar.js
       owns the .chat-sidebar-list CSS family on the real chat page,
       but /learn doesn't load that script. Borrow just enough to make
       the lists feel like the sidebar's: a thin column, a section
       title, a slim row. The drag widget supplies its own affordance
       CSS (cursor:grab, the dragging opacity, the drop-target outline,
       the floating ghost), so we don't restyle those here. */
    // lint:called-once row-builder — invoked per <li> inside makeList
    function makeItem(sid){
      var li = setStyles(document.createElement('li'), {
        padding: '4px 8px', borderRadius: '3px',
        color: '#000080', background: '#f0f0ff',
        margin: '2px 0', fontSize: '13px', listStyle: 'none',
      });
      li.setAttribute('data-sid', sid);
      li.textContent = sid;
      ChatDragToPin.attach(li);
      return li;
    }
    function makeList(title, section, sids){
      var box = setStyles(document.createElement('div'), {
        marginBottom: '14px',
      });
      var t = setStyles(document.createElement('div'), {
        fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em',
        color: '#888', marginBottom: '4px', fontWeight: 'bold',
      });
      t.textContent = title;
      var ul = setStyles(document.createElement('ul'), {
        listStyle: 'none', padding: '4px', margin: '0',
        minHeight: '32px', borderRadius: '4px',
      });
      ul.className = 'chat-session-drop';   /* widget styles the drop-active outline */
      ul.setAttribute('data-section', section);
      sids.forEach(function(sid){ ul.appendChild(makeItem(sid)); });
      box.appendChild(t); box.appendChild(ul);
      return { box: box, ul: ul };
    }
    var pinned   = makeList('Pinned',   'pinned',   ['general']);
    var sessions = makeList('Sessions', 'sessions', ['ideas', 'notes', 'todos', '2026-06-02']);

    var listsCol = setStyles(document.createElement('div'), {
      width: '200px', flexShrink: '0',
      background: '#fff', border: '1px solid #ddd', borderRadius: '4px',
      padding: '8px 10px', boxSizing: 'border-box',
    });
    listsCol.appendChild(pinned.box);
    listsCol.appendChild(sessions.box);

    /* Mini insertSorted (the real sidebar's version) so dropped rows
       sit alphabetically by data-sid in their new home. */
    // lint:called-once drop-callback-hook — invoked from onDrop on every move
    function insertSorted(ul, li){
      var sid = li.getAttribute('data-sid');
      var items = ul.querySelectorAll('li[data-sid]');
      for(var i = 0; i < items.length; i++){
        if(items[i].getAttribute('data-sid') > sid){ ul.insertBefore(li, items[i]); return; }
      }
      ul.appendChild(li);
    }

    /* PRODUCT_DECISION: register the route with LearnFakeHost
       (Lesson 0). Regexp match captures the sid + action; the 700ms
       delay keeps the optimistic state visible before revert. */
    var FAKE_CONV = 'lesson9-fake';
    LearnFakeHost.register({
      match: /^\/chat\/c\/lesson9-fake\/([^/]+)\/(pin|unpin)$/,
      respond: function(ctx){
        var sid = decodeURIComponent(ctx.match[1]);
        var action = ctx.match[2];
        clog.log('POST /chat/c/' + FAKE_CONV + '/' + sid + '/' + action
               + ' (mode=' + nextMode + ')');
        return new Promise(function(resolve){
          setTimeout(function(){
            if(nextMode === 'accept'){
              clog.log('  → host returns ok');
              resolve({ ok: true });
            } else {
              clog.log('  → host returns failure → ChatDragToPin will revert');
              resolve({ ok: false });
            }
          }, 700);
        });
      },
    });

    /* Init the gesture widget. onDrop fires TWICE in failure mode:
       once for the optimistic move, once for the revert. We log + place
       in both cases (same callback, no branching). */
    ChatDragToPin.init({
      convBase: '/chat/c/' + FAKE_CONV,
      onDrop: function(evt){
        var section = evt.toUl.getAttribute('data-section');
        clog.log('onDrop({item: ' + evt.item.getAttribute('data-sid')
               + ', toUl: <ul data-section="' + section + '">})');
        insertSorted(evt.toUl, evt.item);
      },
    });

    /* Side-by-side: lists on the left, log on the right. */
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(listsCol);
    twoCol.appendChild(leftCol); twoCol.appendChild(clog.element);
    wrapper.appendChild(twoCol);

    return wrapper;
  }

  /* ---- section frame: heading + prose + custom body ---- */
  // lint:called-once widget — reused per lesson
  function buildSection(opts){
    /* opts: { title, lede (string), body (DOM element) } */
    var sec = setStyles(document.createElement('section'), {
      marginTop: '28px', paddingTop: '20px',
      borderTop: '1px solid ' + COLORS.border,
    });
    var h = setStyles(document.createElement('h2'), {
      color: COLORS.ink, margin: '0 0 8px', fontSize: '22px',
    });
    h.textContent = opts.title;
    var p = setStyles(document.createElement('p'), {
      margin: '0 0 14px', color: COLORS.body,
    });
    p.textContent = opts.lede;
    sec.appendChild(h); sec.appendChild(p); sec.appendChild(opts.body);
    return sec;
  }

  /* ---- intro: page title + the pitch ---- */
  // lint:called-once page-factory
  function buildIntro(){
    var box = document.createElement('div');
    var h1 = setStyles(document.createElement('h1'), {
      color: COLORS.ink, margin: '0 0 8px', fontSize: '28px',
    });
    h1.textContent = 'Learn';
    var lede = setStyles(document.createElement('p'), {
      margin: '0', color: COLORS.muted, fontSize: '15px',
    });
    lede.textContent = 'Walking through how the chat at /chat was built, one small module at a time. '
      + 'The source you see below is loaded live from the deployed binary, so it can’t drift from the running code.';
    box.appendChild(h1); box.appendChild(lede);
    return box;
  }

  /* ---- compose ---- */
  document.body.insertBefore(buildTopBar(), document.body.firstChild);
  var wrap = buildWrap();
  wrap.appendChild(buildIntro());

  /* Lesson 0 — the demo infrastructure. Two small widgets the rest
     of the lessons assemble together: LearnCallbackLog (narrates
     what a callback received) and LearnFakeHost (registers fake
     server responses without manually patching fetch). Together they
     give every later lesson the same Legos. */
  var lesson0Body = document.createElement('div');
  lesson0Body.appendChild(buildParagraph(
    'Most lessons that follow show a chat widget receiving events — clicks, keystrokes, server '
    + 'responses — and reporting them back through callbacks. The lessons share two tiny demo '
    + 'widgets to make that visible: LearnCallbackLog, which prints each event as a line, and '
    + 'LearnFakeHost, which lets a demo register fake server responses without manually '
    + 'monkey-patching window.fetch.'));
  lesson0Body.appendChild(buildParagraph(
    'Neither is part of the chat system. They are demo code — only /learn loads them, no '
    + 'production widget knows they exist. But they are built exactly the way the real widgets '
    + 'are: one factory or registration API, owned DOM, owned styling, a small public surface. '
    + 'The shape is what lets the lessons assemble code like Legos — drop in a Message here, a '
    + 'ChatRightSidebar there, a LearnCallbackLog beside it, a LearnFakeHost route below it.'));

  /* ---- Part 1: LearnCallbackLog ---- */
  var lesson0PartA = setStyles(document.createElement('h3'), {
    margin: '14px 0 8px', fontSize: '17px', color: COLORS.ink,
  });
  lesson0PartA.textContent = 'Part 1: LearnCallbackLog';
  lesson0Body.appendChild(lesson0PartA);
  lesson0Body.appendChild(buildParagraph(
    'LearnCallbackLog.create({caption, height, width}) returns {element, log, clear}. Drop the '
    + 'element wherever the layout needs it; call log(line) on every event you want to narrate; '
    + 'optionally call clear() to wipe. The log body has a FIXED height (220px by default) so '
    + 'overflowing entries scroll INSIDE the body — flex:1 minHeight:0 was tried first, but in '
    + 'short-form demos (like the Add Topic form) it left the auto-scroll moving the page '
    + 'instead of the log.'));
  lesson0Body.appendChild(buildSpoiler({
    label:     'Show callback_log.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/callback_log.js')); },
  }));
  lesson0Body.appendChild(buildCallbackLogDemo());
  var demo0aCaption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo0aCaption.textContent = 'Demo source (the function that built the box above):';
  lesson0Body.appendChild(demo0aCaption);
  lesson0Body.appendChild(buildCodeBlock(buildCallbackLogDemo.toString()));

  /* ---- Part 2: LearnFakeHost ---- */
  var lesson0PartB = setStyles(document.createElement('h3'), {
    margin: '24px 0 8px', fontSize: '17px', color: COLORS.ink,
  });
  lesson0PartB.textContent = 'Part 2: LearnFakeHost';
  lesson0Body.appendChild(lesson0PartB);
  lesson0Body.appendChild(buildParagraph(
    'When a lesson teaches a widget that POSTs to the server (Lessons 7, 8, 9), the demo needs '
    + 'to fake the host\'s response. LearnFakeHost is the shared facility for that: one global '
    + 'wrap of window.fetch, a registry of routes, fall-through to the browser\'s real fetch '
    + 'for anything no route claims.'));
  lesson0Body.appendChild(buildParagraph(
    'LearnFakeHost.register({match, respond}) adds one route. match is a string (literal or '
    + 'prefix), a RegExp (with captured groups), or a function predicate. respond receives a '
    + '{url, opts, match} context and returns a Promise of a Response-shaped object. The host '
    + 'tries routes in registration order; the first match wins.'));
  lesson0Body.appendChild(buildSpoiler({
    label:     'Show fake_host.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/fake_host.js')); },
  }));
  lesson0Body.appendChild(buildFakeHostDemo());
  var demo0bCaption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo0bCaption.textContent = 'Demo source (the function that built the box above):';
  lesson0Body.appendChild(demo0bCaption);
  lesson0Body.appendChild(buildCodeBlock(buildFakeHostDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 0: demo infrastructure (LearnCallbackLog + LearnFakeHost)',
    lede:  'Two small widgets the rest of the lessons reuse: one narrates what a callback '
         + 'received, the other simulates the host. Demo code, but built the same shape as the '
         + 'real chat widgets — every later lesson assembles one of each.',
    body:  lesson0Body,
  }));

  /* Lesson 1 — chat_image_popup.js (48 LOC). */
  var lesson1Body = document.createElement('div');
  lesson1Body.appendChild(buildSpoiler({
    label:     'Show source (48 lines)',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/chat_image_popup.js')); },
  }));
  lesson1Body.appendChild(buildPopupDemo());
  /* PRODUCT_DECISION: the inline demo source is buildPopupDemo.toString() —
     not a copy. The reader sees exactly the function that built the box
     above, and there is nowhere for the two to drift apart. */
  var demoCaption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demoCaption.textContent = 'Demo source (the function that built the box above):';
  lesson1Body.appendChild(demoCaption);
  lesson1Body.appendChild(buildCodeBlock(buildPopupDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 1: chat_image_popup.js',
    lede:  'A tiny shared module that opens an image in a zoomable <dialog>. '
         + 'The chat feed, the search panel, and the Images transcript all delegate to it via ChatImagePopup.show(src). '
         + 'Click the cat below to see exactly what those callers see — same module, no chat around it.',
    body:  lesson1Body,
  }));

  /* Lesson 2 — chat_code_popup.js (27 LOC). Meta demo: the code IS the
     clickable target; the popup it opens shows the code that built the
     popup. Small enough that no spoiler is needed. */
  var lesson2Body = document.createElement('div');
  lesson2Body.appendChild(buildCodePopupDemo('/learn/source/chat_code_popup.js'));
  var demo2Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo2Caption.textContent = 'Demo source (the function that built the box above):';
  lesson2Body.appendChild(demo2Caption);
  lesson2Body.appendChild(buildCodeBlock(buildCodePopupDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 2: chat_code_popup.js',
    lede:  'A sibling of Lesson 1, but for code: opens any string of source in a monospace <dialog>. '
         + 'Used by the chat feed (click a code block) and the Code transcript. '
         + 'Self-contained — owns its own styles inline, no external CSS — so it’s short enough to read end-to-end without a spoiler.',
    body:  lesson2Body,
  }));

  /* Lesson 3 — chat/message.js. A widget that builds a chat bubble out of
     server-baked HTML and routes clicks via caller-supplied callbacks. */
  var lesson3Body = document.createElement('div');
  lesson3Body.appendChild(buildParagraph(
    'Each message your browser shows comes through Message.create(data, callbacks).render(). '
    + 'The widget owns the bubble’s DOM and one delegated click listener. What should happen '
    + 'when you click the quote-reply button? When you click an image? When you click a MSG_ '
    + 'reference link? Message doesn’t know. It classifies the click and invokes the matching '
    + 'callback the caller provided. The callbacks are how the page connects this widget to '
    + 'the rest of the system — the compose box, the nav stack, the popups.'));
  lesson3Body.appendChild(buildParagraph(
    'Notice two things in the source below. First, data.html is HTML the server already produced '
    + '(markdown rendered + sanitized by the server, plus a regex pass that wraps MSG_<id> tokens in '
    + '<a class="msg-ref"> links). The widget innerHTMLs it as-is — it doesn’t parse markdown, '
    + 'doesn’t re-sanitize. The separation lets the chat surface and the search modal use the same '
    + 'widget on the same bytes. Second, Message owns ALL the styling — both the bubble chrome it '
    + 'builds (chat-msg, chat-meta, etc.) and the small vocabulary of classes the server emits inside '
    + 'data.html (.chat-body, a.msg-ref, pre.chat-quote, img). The widget injects one <style> tag '
    + 'lazily on first create(); the chat conversation page no longer ships any CSS for these. The '
    + 'demo below proves it: /learn loads no chat stylesheet at all, and the bubbles still look right.'));
  lesson3Body.appendChild(buildSpoiler({
    label:     'Show message.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/message.js')); },
  }));
  lesson3Body.appendChild(buildMessageDemo());
  var demo3Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo3Caption.textContent = 'Demo source (the function that built the box above):';
  lesson3Body.appendChild(demo3Caption);
  lesson3Body.appendChild(buildCodeBlock(buildMessageDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 3: message.js',
    lede:  'The first widget that exposes callbacks instead of doing the work itself. '
         + 'Build a chat bubble, route the click, hand off to the caller — never reach across '
         + 'to compose, to the nav stack, or to ChatSearch.',
    body:  lesson3Body,
  }));

  /* Lesson 4 — chat/message_view.js. A scrolling list of opaque rectangles;
     the widget manages selection + keyboard nav + scroll-driven re-selection
     and reports back via setSelectedBubble — that's the seam where the nav
     stack lives. */
  var lesson4Body = document.createElement('div');
  lesson4Body.appendChild(buildParagraph(
    'MessageView is the rectangle-list widget under Lesson 3’s bubbles. '
    + 'It knows nothing about chat, markdown, or popups — its DOM is opaque rectangles in a scroll '
    + 'container. The caller passes a renderBubble strategy ("here’s how to make bubble #i") '
    + 'and a setSelectedBubble callback ("here’s what to do when the selection settles"). '
    + 'The widget itself owns no policy about what selection MEANS.'));
  lesson4Body.appendChild(buildParagraph(
    'Why have that callback at all? Because something needs to remember where you’ve been so '
    + 'you can press Back and return. That something is a nav stack — Lesson 5’s subject. In this '
    + 'lesson the callback just logs; in Lesson 5 the same callback also pushes onto a NavStack '
    + 'instance, and two Back/Forward buttons pop it. Keeping the wiring out of MessageView is the '
    + 'point: a different page could wire setSelectedBubble to a URL router, a save-as-bookmark '
    + 'button, anything.'));
  lesson4Body.appendChild(buildParagraph(
    'The demo below uses three colors and 36 rectangles of varying sizes so scrolling is '
    + 'forced. Click, scroll, or focus the container and press arrows — every settle fires '
    + 'setSelectedBubble, and the page logs it. The selection ring (yellow box-shadow) is '
    + 'MessageView’s own visual: it injects the .mv-selected stylesheet on first create() the '
    + 'same way Message brought its own.'));
  lesson4Body.appendChild(buildParagraph(
    'There’s a 700ms debounce between the visible cursor and the setSelectedBubble call. '
    + 'The cursor (yellow ring) moves on every keystroke so a burst of arrow presses feels '
    + 'responsive — but the callback only fires after a brief rest, so whatever you wire it to '
    + '(eventually the nav stack) records where you LANDED, not every intermediate stop. The same '
    + 'debounce gates scroll-driven re-selection: scrolling fast doesn’t fire the callback per frame.'));
  lesson4Body.appendChild(buildSpoiler({
    label:     'Show message_view.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/message_view.js')); },
  }));
  lesson4Body.appendChild(buildMessageViewDemo());
  var demo4Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo4Caption.textContent = 'Demo source (the function that built the box above):';
  lesson4Body.appendChild(demo4Caption);
  lesson4Body.appendChild(buildCodeBlock(buildMessageViewDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 4: message_view.js',
    lede:  'A scrollable list of opaque rectangles with selection state, keyboard navigation, '
         + 'scroll-driven re-selection, and one outbound callback. The widget under chat’s '
         + 'bubbles — separable enough that a demo with colored rectangles wires up the same way.',
    body:  lesson4Body,
  }));

  /* Lesson 5 — chat/nav_stack.js. The back/forward state machine. Built
     on top of Lesson 4: same scroller, plus a NavStack instance and two
     unstyled <button>s. ---- */
  var lesson5Body = document.createElement('div');
  lesson5Body.appendChild(buildParagraph(
    'NavStack is just a stack — push, back, forward — wrapped around a cursor so back and '
    + 'forward walk it instead of popping. The button-and-hotkey orchestration stays in chat.js '
    + 'where it belongs (Lesson 6 will cover that). Three callbacks in, three verbs out: '
    + 'gotoMessage(entry) is "navigate to entry," onChange(canBack, canFwd) is the button-enable '
    + 'hook, currentSelection() returns the live selection for drift detection.'));
  lesson5Body.appendChild(buildParagraph(
    'Drift: after a push, the live selection can wander off — the user scrolls, or arrows to a '
    + 'new bubble without resting long enough for a push to fire. The first Back in that state '
    + 'recovers to the marked entry instead of popping, so Back means "get me back to where I '
    + 'was" first and "pop the stack" second. Try it in the demo: click bubble #20, scroll up '
    + 'or down, then click Back.'));
  lesson5Body.appendChild(buildSpoiler({
    label:     'Show nav_stack.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/nav_stack.js')); },
  }));
  lesson5Body.appendChild(buildNavStackDemo());
  var demo5Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo5Caption.textContent = 'Demo source (additive on Lesson 4 — same helpers, plus the new wiring):';
  lesson5Body.appendChild(demo5Caption);
  lesson5Body.appendChild(buildCodeBlock(buildNavStackDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 5: nav_stack.js',
    lede:  'The state machine Back/Forward orbit around. Lessons 3 and 4 segue here: Message '
         + 'reports clicks via callbacks (Lesson 3), MessageView reports settled selections via '
         + 'setSelectedBubble (Lesson 4), and this lesson wires that callback into a real NavStack '
         + 'so Back and Forward come alive.',
    body:  lesson5Body,
  }));

  /* Lesson 6 — chat/middle_pane.js. The integration layer for everything
     Lessons 3-5 built. One init() call builds the column + wires up
     MessageView + NavStack + the back/forward buttons. The demo is a
     full chat-shaped column wired with the real Message factory. */
  var lesson6Body = document.createElement('div');
  lesson6Body.appendChild(buildParagraph(
    'ChatMiddlePane.init({mount, renderBubble}) builds the whole bubble-feed column — wrapper, '
    + 'navbar with Back/Forward, scrollable history surface — and instantiates MessageView and '
    + 'NavStack inside. Hand it a renderBubble that returns Message.create(data, callbacks).render() '
    + 'and the column comes alive.'));
  lesson6Body.appendChild(buildParagraph(
    'What does the server actually send? Two payloads per message: data.markdown (the raw source '
    + 'the user typed) and data.html (the same source rendered by the server + a regex pass that '
    + 'turns MSG_<id> tokens into msg-ref links). The html lands in Message.create and gets '
    + 'innerHTMLed as-is; the markdown is kept for quote-reply, edit, and ChatSearch. Everything '
    + 'else — column, navbar, buttons, scrollbar, bubble chrome, hover and disabled states — is '
    + 'built and styled by JS. Go ships data; JS owns presentation.'));
  lesson6Body.appendChild(buildParagraph(
    'The demo below uses six simulated SSE payloads in the same wire shape the real stream emits '
    + '— the html field is written by hand so /learn doesn’t need a chat session backing it. '
    + 'Click MSG_demo_1 to jump back through the nav stack; click the cat for the image popup; '
    + 'click the code block for the code popup; click q/r/e on a message to see what the real '
    + 'compose-side callbacks would have fired.'));
  lesson6Body.appendChild(buildSpoiler({
    label:     'Show middle_pane.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/middle_pane.js')); },
  }));
  lesson6Body.appendChild(buildMiddlePaneDemo());
  var demo6Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo6Caption.textContent = 'Demo source (the function that built the box above):';
  lesson6Body.appendChild(demo6Caption);
  lesson6Body.appendChild(buildCodeBlock(buildMiddlePaneDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 6: middle_pane.js',
    lede:  'The integration layer that ties Lessons 3-5 together. One init() call, the whole '
         + 'column comes alive.',
    body:  lesson6Body,
  }));

  /* Lesson 7 — chat_right_sidebar.js + chat_compose.js (the right rail). */
  var lesson7Body = document.createElement('div');
  lesson7Body.appendChild(buildParagraph(
    'The right rail has two states: closed (showing the "Open compose box" button — and, in '
    + 'the real app, the keyhelp panel from Lesson 4) and open (showing the compose form). '
    + 'ChatRightSidebar.init builds the wrapper + closed-panel + Open button and exposes '
    + 'openCompose / closeCompose. ChatCompose.init builds the form, textarea, Send and Image '
    + 'buttons, the status line, and the markdown hint — then inserts that body before the '
    + 'closed-panel and hands a reference back via registerComposeBody so the toggle can flip '
    + 'their visibility.'));
  lesson7Body.appendChild(buildParagraph(
    'The send state machine is the essential complexity. Hitting Send doesn\'t clear the '
    + 'textarea. ChatCompose generates a client correlation id (cid), disables the form, paints '
    + '"Sending…", starts a 3-second hostDown timer, and POSTs. The textarea only clears when '
    + 'the SSE echo arrives with the matching cid (chat.js routes that into '
    + 'ChatCompose.ackIfPending). If the timer trips first, hostDown re-enables the form WITHOUT '
    + 'clearing the text — no draft lost — and shows a "host may be down" alert. The cid '
    + 'round-trip exists because POST success isn\'t real delivery confirmation; the SSE echo is.'));
  lesson7Body.appendChild(buildParagraph(
    'The demo wires both widgets into a mount slot. Fetch is monkey-patched on a fake '
    + 'SESSION_BASE: pick "echo" and your send fires a fake ackIfPending after 800ms; pick '
    + '"silent" and the POST resolves but no echo ever arrives, so the 3s timer trips and you '
    + 'see the alert. Real ChatCompose code, real state machine, fake server.'));
  lesson7Body.appendChild(buildSpoiler({
    label:     'Show chat_right_sidebar.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/chat_right_sidebar.js')); },
  }));
  lesson7Body.appendChild(buildSpoiler({
    label:     'Show chat_compose.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/chat_compose.js')); },
  }));
  lesson7Body.appendChild(buildRightRailDemo());
  var demo7Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo7Caption.textContent = 'Demo source (the function that built the box above):';
  lesson7Body.appendChild(demo7Caption);
  lesson7Body.appendChild(buildCodeBlock(buildRightRailDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 7: chat_right_sidebar.js + chat_compose.js',
    lede:  'The right rail: a tiny shell widget around a stateful form. The form has more '
         + 'state than usual — it has to wait for the server to confirm delivery before it '
         + 'clears.',
    body:  lesson7Body,
  }));

  /* Lesson 8 — chat_add_topic.js. The Add Topic form at the bottom of
     the left rail. Smallest "stateful form + host interaction" lesson —
     contrast with Lesson 7's compose, which juggles a real state
     machine. This one is just: validate, POST, fire a callback or
     show an error. */
  var lesson8Body = document.createElement('div');
  lesson8Body.appendChild(buildParagraph(
    'ChatAddTopic.create({convBase, onCreated}) returns a <form> ready to drop in. It owns input '
    + 'validation (TOPIC_RE: letters/digits/hyphens, no leading or trailing hyphen), the POST to '
    + 'convBase+"/new", and inline error display. It does NOT decide what happens on success '
    + '— onCreated({conv, sid}) is the caller\'s policy. The convBase shape carries the URL '
    + 'space (DM "/chat/c/<pair>" or channel "/channel/<name>"); the widget itself never '
    + 'branches on kind.'));
  lesson8Body.appendChild(buildParagraph(
    'The boundary lesson here is small but real: the widget reports a domain event ("a topic '
    + 'was added"), and the caller decides what to do with it. Hardcoding location.href inside '
    + 'the widget would have presumed deployment context (a page that wants to navigate); '
    + 'hoisting it makes the widget reusable AND makes the lesson demo possible without '
    + 'fighting a page navigation away from /learn.'));
  lesson8Body.appendChild(buildParagraph(
    'The demo monkey-patches fetch for the fake conv\'s /new URL — the same shape Lesson 7 '
    + 'used for the send/upload endpoints. Pick "host accepts" or "host rejects" before each '
    + 'submit and watch the callback log narrate. The TOPIC_RE rejection path is purely '
    + 'client-side: invalid input shows the error without firing fetch at all.'));
  lesson8Body.appendChild(buildSpoiler({
    label:     'Show chat_add_topic.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/chat_add_topic.js')); },
  }));
  lesson8Body.appendChild(buildAddTopicDemo());
  var demo8Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo8Caption.textContent = 'Demo source (the function that built the box above):';
  lesson8Body.appendChild(demo8Caption);
  lesson8Body.appendChild(buildCodeBlock(buildAddTopicDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 8: chat_add_topic.js',
    lede:  'A small form widget that knows about input validation and HTTP — but not about '
         + 'navigation. The caller decides what "topic added" means in their surface.',
    body:  lesson8Body,
  }));

  /* Lesson 9 — chat_drag_to_pin.js. A pointer-driven gesture widget
     that owns the state machine and the host POST, and reports drops
     via callback so the caller stays in charge of DOM placement. The
     headline behavior is the optimistic-update + revert dance. */
  var lesson9Body = document.createElement('div');
  lesson9Body.appendChild(buildParagraph(
    'ChatDragToPin.init({convBase, onDrop}) wires the module; ChatDragToPin.attach(item) makes one '
    + '<li> draggable. The widget owns the pointer state machine (a 5px move threshold so '
    + 'a plain tap still navigates the link, pointer-capture at drag-start so the gesture '
    + 'tracks even when the cursor leaves the row, a floating drag ghost), the pin/unpin POST '
    + 'to the host, and — importantly — the optimistic-update + revert orchestration around '
    + 'that POST.'));
  lesson9Body.appendChild(buildParagraph(
    'The onDrop contract is the teaching point. The widget reports drops via a single '
    + 'callback ({item, toUl}). On a successful move it fires once. On host rejection it '
    + 'fires TWICE — once with the optimistic target, then again with source and target '
    + 'reversed. The caller does the DOM placement in BOTH cases (no separate revert API); '
    + 'one branch-less callback handles both directions. That keeps the gesture widget '
    + 'agnostic about the caller\'s placement rule (the real sidebar inserts alphabetically '
    + 'via insertSorted, this demo uses the same).'));
  lesson9Body.appendChild(buildParagraph(
    'The demo intercepts fetch for the fake conv\'s /pin and /unpin URLs and delays the '
    + 'response ~700ms so the optimistic state is visible before the revert. Try "host '
    + 'accepts" first to see the happy path, then flip to "host rejects" and watch the row '
    + 'snap back as onDrop fires a second time.'));
  lesson9Body.appendChild(buildSpoiler({
    label:     'Show chat_drag_to_pin.js source',
    openLabel: 'Hide source',
    render: function(box){ box.appendChild(buildSourcePanel('/learn/source/chat_drag_to_pin.js')); },
  }));
  lesson9Body.appendChild(buildDragToPinDemo());
  var demo9Caption = setStyles(document.createElement('p'), {
    margin: '14px 0 6px', color: COLORS.muted, fontSize: '13px',
  });
  demo9Caption.textContent = 'Demo source (the function that built the box above):';
  lesson9Body.appendChild(demo9Caption);
  lesson9Body.appendChild(buildCodeBlock(buildDragToPinDemo.toString()));

  wrap.appendChild(buildSection({
    title: 'Lesson 9: chat_drag_to_pin.js',
    lede:  'A pointer-driven gesture widget. The shape that matters: optimistic move plus '
         + 'symmetric revert, both reported through the SAME onDrop callback so the caller '
         + 'doesn\'t branch on direction.',
    body:  lesson9Body,
  }));

  root.appendChild(wrap);
})();
