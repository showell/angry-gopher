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
     every page (see server/web/chrome.go's AppChromeCSS for the shared
     CSS exemplar). When you build a custom JS-styled top bar like this
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

    /* Three server-shaped message objects. `html` would be sanitized by
       goldmark on the real server; here we author it directly. */
    var messages = [
      { id: 'demo_001', index: 0, from: 'Alice', mine: false, time: '09:30',
        body: 'Hey 👋',
        html: 'Hey there 👋' },
      { id: 'demo_002', index: 1, from: 'You', mine: true, time: '09:31',
        body: 'Try clicking the image or the code block',
        html: 'Try clicking either of these:<br>'
            + '<img src="/images/cat_professor.webp" style="max-width:140px;cursor:zoom-in"><br>'
            + '<pre>console.log("hi from the demo");</pre>' },
      { id: 'demo_003', index: 2, from: 'Alice', mine: false, time: '09:32',
        body: 'See MSG_demo_002',
        html: 'See <a class="msg-ref" href="#msg-demo_002">MSG_demo_002</a> 👆' },
    ];

    /* The callback log — visible proof that the widget hands off without
       deciding what should happen. flex:1 + overflowY:auto so it matches
       the bubble column's height (stretched by the flex row) and scrolls
       instead of growing. */
    var logBody = setStyles(document.createElement('div'), {
      fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: '12px',
      background: '#fff', border: '1px solid ' + COLORS.border, borderRadius: '4px',
      padding: '8px', flex: '1', minHeight: '0', overflowY: 'auto', boxSizing: 'border-box',
    });
    function log(line){
      var entry = document.createElement('div');
      entry.textContent = '→ ' + line;
      logBody.appendChild(entry);
      logBody.scrollTop = logBody.scrollHeight;
    }
    var callbacks = {
      onQuote:  function(m){    log('onQuote(MSG_'  + m.getId() + ')'); },
      onRefer:  function(m){    log('onRefer(MSG_'  + m.getId() + ')'); },
      onEdit:   function(m){    log('onEdit(MSG_'   + m.getId() + ')'); },
      onMsgRef: function(link){ log('onMsgRef('     + link.getAttribute('href') + ')'); },
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
    var logCaption = setStyles(document.createElement('div'), {
      marginBottom: '4px', fontSize: '13px', color: COLORS.muted,
    });
    logCaption.textContent = 'Callback log:';

    /* Side-by-side: bubbles on the left flex to fill; log column fixed-
       width on the right. Default alignItems (stretch) makes the log
       column match the bubble column's natural height, so logBody's
       flex:1 fills the matched height and scrolls when full. */
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(bubbles);
    var rightCol = setStyles(document.createElement('div'), {
      width: '260px', flexShrink: '0',
      display: 'flex', flexDirection: 'column',
    });
    rightCol.appendChild(logCaption);
    rightCol.appendChild(logBody);
    twoCol.appendChild(leftCol); twoCol.appendChild(rightCol);

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
  function buildLogPanel(){
    var logCaption = setStyles(document.createElement('div'), {
      marginBottom: '4px', fontSize: '13px', color: COLORS.muted,
    });
    logCaption.textContent = 'Callback log:';
    /* Fixed height matches the scroller's; auto-scrolls so the latest
       entry stays in view and the panel doesn't grow without bound. */
    var logBody = setStyles(document.createElement('div'), {
      fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: '12px',
      background: '#fff', border: '1px solid ' + COLORS.border, borderRadius: '4px',
      padding: '8px', height: SURFACE_HEIGHT, overflowY: 'auto', boxSizing: 'border-box',
    });
    function log(line){
      var entry = document.createElement('div');
      entry.textContent = '→ ' + line;
      logBody.appendChild(entry);
      logBody.scrollTop = logBody.scrollHeight;
    }
    return { logCaption: logCaption, logBody: logBody, log: log };
  }

  // lint:called-once widget — shared by Lessons 4 + 5
  function buildScrollerLogLayout(scroller, logCaption, logBody){
    var twoCol = setStyles(document.createElement('div'), {
      display: 'flex', gap: '14px',
    });
    var leftCol = setStyles(document.createElement('div'), { flex: '1', minWidth: '0' });
    leftCol.appendChild(scroller);
    var rightCol = setStyles(document.createElement('div'), {
      width: '260px', flexShrink: '0',
      display: 'flex', flexDirection: 'column',
    });
    rightCol.appendChild(logCaption);
    rightCol.appendChild(logBody);
    twoCol.appendChild(leftCol); twoCol.appendChild(rightCol);
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
    var panel = buildLogPanel();
    var scr = buildColoredScroller(function(idx){
      panel.log('setSelectedBubble(' + idx + ')');
    });
    box.appendChild(hint);
    box.appendChild(buildScrollerLogLayout(scr.scroller, panel.logCaption, panel.logBody));
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

    var panel = buildLogPanel();

    /* Forward-reference: the callback closes over `nav` (declared
       here, assigned below). buildColoredScroller runs endBacklog
       synchronously, which fires setSelectedBubble once for the
       anchored bubble — before nav exists. Guard the push; the
       initial selection wasn't a user action anyway, so dropping it
       on the floor matches the chat page's behavior. */
    var nav;
    var scr = buildColoredScroller(function(idx){
      panel.log('setSelectedBubble(' + idx + ')');
      if(nav) nav.push(idx);
    });

    nav = NavStack.create({
      gotoMessage: function(entry){
        panel.log('gotoMessage(' + entry + ')');
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
    box.appendChild(buildScrollerLogLayout(scr.scroller, panel.logCaption, panel.logBody));
    return box;
  }

  /* ---- Lesson 6 demo: ChatMiddlePane.init wired with the real
     Message factory and a small batch of simulated server responses
     (same wire shape as the chat conversation page's SSE — index,
     from, time, html, markdown, id, mine). The html field is what the
     Go server would have produced from goldmark; everything else is
     JS the reader has already seen. ---- */

  // lint:called-once widget
  function buildMiddlePaneDemo(){
    /* Six simulated SSE payloads in the same shape the real stream
       emits. The `html` field is what the server would have rendered
       from the `markdown` source — written by hand here so the demo
       doesn't need a Go round-trip. */
    var fakeMessages = [
      { from: 'apoorva', time: 'today · 9:00 AM', mine: false, id: 'demo_1',
        markdown: 'Hi! I just finished lesson 5 about **nav_stack**. Are these demos using real chat data?',
        html: '<p>Hi! I just finished lesson 5 about <strong>nav_stack</strong>. Are these demos using real chat data?</p>' },
      { from: 'Claude',  time: 'today · 9:01 AM', mine: true,  id: 'demo_2',
        markdown: 'No — the earlier lessons used colored rectangles to keep the focus on the widget itself...',
        html: '<p>No — the earlier lessons used colored rectangles to keep the focus on the widget itself. Lesson 6 finally introduces real messages.</p>'
            + '<p>The data shape is what the SSE stream sends: <code>{from, time, html, markdown, id, mine}</code>. Hand it to <code>Message.create</code> and you get a bubble.</p>' },
      { from: 'apoorva', time: 'today · 9:02 AM', mine: false, id: 'demo_3',
        markdown: 'So the html field is already rendered? What does the JS side do then?',
        html: '<p>So the <code>html</code> field is already rendered? What does the JS side do then?</p>' },
      { from: 'Claude',  time: 'today · 9:03 AM', mine: true,  id: 'demo_4',
        markdown: 'Right — Go runs the markdown through goldmark, sanitizes it, and post-processes MSG_ tokens...',
        html: '<p>Right — Go runs the markdown through goldmark, sanitizes it, and post-processes MSG_ tokens into msg-ref links (see <a href="#msg-demo_1" class="msg-ref">MSG_demo_1</a>). The JS just <code>innerHTML</code>s it.</p>'
            + '<p>Code blocks land in <code>&lt;pre&gt;</code> tags — clickable too:</p>'
            + '<pre class="chat-quote">function hi(){ return \'world\'; }</pre>' },
      { from: 'apoorva', time: 'today · 9:04 AM', mine: false, id: 'demo_5',
        markdown: 'And images?',
        html: '<p>And images?</p>'
            + '<p><img src="/images/cat_professor.webp" alt="cat professor"></p>' },
      { from: 'Claude',  time: 'today · 9:05 AM', mine: true,  id: 'demo_6',
        markdown: 'Same path — markdown has ![alt](src), goldmark renders it as <img>, Message wires the click to the popup.',
        html: '<p>Same path — the markdown has <code>![alt](src)</code>, goldmark renders it as <code>&lt;img&gt;</code>, Message wires the click to the popup. Try clicking the cat above.</p>'
            + '<p>Click <a href="#msg-demo_1" class="msg-ref">MSG_demo_1</a> and the pane scrolls back + selects that bubble — your current position goes on the nav stack, so Back returns you here.</p>' },
    ];

    var wrapper = setStyles(document.createElement('div'), {
      height: '440px', display: 'flex',
      border: '1px solid #ccc', borderRadius: '4px',
      padding: '8px', background: '#fafafa', boxSizing: 'border-box',
    });
    var mount = document.createElement('div');
    wrapper.appendChild(mount);

    /* Same id→Message lookup chat.js builds for cross-message
       navigation. msg-ref clicks find their target through this. */
    var messagesById = Object.create(null);
    var pane;
    function navigateRef(linkEl){
      var id = (linkEl.getAttribute('href') || '').replace(/^#msg-/, '');
      var msg = messagesById[id];
      if(msg) pane.focusBubble(msg.getIndex() + 1);
    }

    pane = ChatMiddlePane.init({
      mount: mount,
      scopeKeysToContainer: true,
      renderBubble: function(idx, data){
        var msg = Message.create(data, {
          /* The real chat.js routes these into the compose box; the
             demo just announces the verb so the buttons aren't dead. */
          onQuote:  function(m){ alert('quote-reply to MSG_' + m.getId()); },
          onRefer:  function(m){ alert('insert "See MSG_' + m.getId() + '" into compose'); },
          onEdit:   function(m){ alert('compose "Edit of MSG_' + m.getId() + '"'); },
          onMsgRef: navigateRef,
        });
        messagesById[msg.getId()] = msg;
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
    + '(markdown rendered + sanitized by goldmark, plus a regex pass that wraps MSG_<id> tokens in '
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
    + 'the user typed) and data.html (the same source run through goldmark + a regex pass that '
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

  root.appendChild(wrap);
})();
