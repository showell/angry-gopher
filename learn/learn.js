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

  /* ---- chrome: top bar, page wrap, footer ---- */
  // lint:called-once page-factory
  function buildTopBar(){
    var bar = setStyles(document.createElement('header'), {
      background: '#f0ede4', borderBottom: '1px solid ' + COLORS.border,
      padding: '8px 24px', fontFamily: 'sans-serif',
      display: 'flex', justifyContent: 'space-between', alignItems: 'baseline',
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

  root.appendChild(wrap);
})();
