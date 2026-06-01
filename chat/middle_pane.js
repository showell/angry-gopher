/* ChatMiddlePane — the bubble-feed column.

   Owns its entire DOM + styling: wrapper, navbar with Back/Forward
   buttons, the scrollable history surface, the inner bubble list.
   Owns MessageView + NavStack internally; the back/forward buttons
   are local to this widget — chat.js doesn't see them.

   Caller supplies a mount element (the layout slot where this column
   lives) and a renderBubble that builds one bubble from one message.
   The returned API mirrors MessageView's verbs plus back()/forward()
   plus a navbar handle for siblings that want to inject their own
   buttons (chat_search's 🔍). */
window.ChatMiddlePane = (function(){
  'use strict';

  var styleInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(styleInjected) return; styleInjected = true;
    var s = document.createElement('style');
    /* :hover / :disabled / media-query — the rules that can't go through
       el.style. The rest of the column's styling is inline. */
    s.textContent =
        '.chat-mp-btn:hover:enabled { background:#e3e3e3; }'
      + '.chat-mp-btn:disabled { opacity:0.4; cursor:default; }'
      + '.chat-mp-history:focus { outline:none; }'
      + '@media (orientation: landscape) { .chat-mp-main { flex:1; } }';
    document.head.appendChild(s);
  }

  function makeNavButton(opts){
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'chat-mp-btn';
    b.title = opts.title || '';
    if(opts.html) b.innerHTML = opts.html;
    else b.textContent = opts.label || '';
    Object.assign(b.style, {
      fontSize:'14px', lineHeight:1, padding:'3px 11px',
      background:'#eee', color:'#333',
      border:'1px solid #ccc', borderRadius:'4px', cursor:'pointer',
    });
    return b;
  }

  function init(opts){
    ensureStyles();
    var main         = opts.mount;
    var renderBubble = opts.renderBubble;
    var onSelect     = opts.onSelect || function(){};

    main.className = 'chat-mp-main';
    Object.assign(main.style, {
      minWidth:0, flex:1, maxWidth:'600px',
      display:'flex', flexDirection:'column', minHeight:0,
    });

    var navbar = document.createElement('div');
    Object.assign(navbar.style, { marginBottom:'8px' });

    var backBtn = makeNavButton({
      title: 'Back to the previous selection (b)',
      html:  '&larr;',
    });
    backBtn.disabled = true;
    var fwdBtn = makeNavButton({
      title: 'Forward — redo a Back (f)',
      html:  '&rarr;',
    });
    fwdBtn.disabled = true;
    fwdBtn.style.marginLeft = '4px';
    navbar.appendChild(backBtn);
    navbar.appendChild(fwdBtn);

    var history = document.createElement('div');
    history.className = 'chat-mp-history';
    history.tabIndex = -1;
    Object.assign(history.style, {
      minWidth:0, flex:1, minHeight:0, overflowY:'auto',
      border:'1px solid #ddd', borderRadius:'8px',
      padding:'12px', background:'#fcfcf8',
    });

    var bubbles = document.createElement('div');
    history.appendChild(bubbles);

    main.appendChild(navbar);
    main.appendChild(history);

    var nav;

    var view = MessageView.create({
      container:    history,
      list:         bubbles,
      renderBubble: renderBubble,
      /* PRODUCT_DECISION: forwarded for hosts that share the page with
         other arrow-key consumers (e.g. /learn's multiple demos).
         Defaults to false on the chat conversation page so arrows
         work without first focusing the feed. */
      scopeKeysToContainer: !!opts.scopeKeysToContainer,
      setSelectedBubble: function(idx){
        if(idx<=0) return;
        onSelect(idx);
        nav.push(idx);
      },
    });

    nav = NavStack.create({
      gotoMessage:      function(idx){ view.focusBubble(idx, {silent:true}); },
      onChange:         function(canBack, canFwd){ backBtn.disabled=!canBack; fwdBtn.disabled=!canFwd; },
      currentSelection: view.getSelected,
    });
    backBtn.addEventListener('click', nav.back);
    fwdBtn.addEventListener('click', nav.forward);

    function caughtUp(){
      var els = bubbles.querySelectorAll('[data-i]');
      if(els.length === 0) return true;
      return els[els.length-1].getBoundingClientRect().bottom
        <= history.getBoundingClientRect().bottom + 1;
    }

    return {
      append:          view.append,
      focusBubble:     view.focusBubble,
      getSelected:     view.getSelected,
      cursorToExtreme: view.cursorToExtreme,
      startBacklog:    view.startBacklog,
      endBacklog:      view.endBacklog,
      caughtUp:        caughtUp,
      back:            nav.back,
      forward:         nav.forward,
      navbar:          navbar,
      bubbles:         bubbles,
      focus:           function(){ history.focus({preventScroll:true}); },
    };
  }

  /* makeNavButton is exported so sibling modules (e.g. chat_search's
     🔍) can build a button that matches the navbar's look without
     re-deriving the styles. */
  return { init: init, makeNavButton: makeNavButton };
})();
