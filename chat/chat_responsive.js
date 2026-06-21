/* ChatResponsive — mobile/small-screen layout overrides.

   Single cross-cutting module that makes the 3-column chat layout
   work on narrow viewports (<=768px):

     - Left sidebar becomes an off-screen drawer, toggled by a ☰ button
       in the top bar + a backdrop overlay.
     - Right sidebar (compose) becomes a bottom-anchored bar: a compact
       "Write a message…" pill that expands on tap, Zulip-style —
       part of the message feed stays visible while composing.
     - Middle pane goes full-width.

   All layout overrides live in one @media block injected here.
   Desktop styling is untouched.

   Wire: ChatResponsive.init({ topBar, sidebar, onSidebarClose })
   Must run AFTER ChatLeftSidebar, ChatRightSidebar, ChatCompose. */
window.ChatResponsive = (function(){
  'use strict';

  var sidebar, backdrop, hamburger;
  var mql;

  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''

      /* ===== mobile (<=768px) ===== */
      + '@media (max-width:768px) {'

      /* top bar: tighter padding, hide sub-nav + user links */
      + '.app-top.chat-top { padding:8px 12px; }'
      + '.chat-top-links { display:none; }'
      + '.app-top-user a { display:none; }'

      /* layout: single-column, no gap */
      + '.app-body-wrap { margin:0; padding:0 0 0 0; }'
      + '.chat-layout { flex-direction:column; gap:0; }'

      /* left sidebar → off-screen drawer */
      + '.chat-sidebar { position:fixed; top:0; left:0; bottom:0;'
      +   ' width:260px; z-index:100;'
      +   ' transform:translateX(-100%); transition:transform 0.25s ease;'
      +   ' background:var(--cc-bg); border-right:1px solid var(--cc-border);'
      +   ' padding:52px 14px 14px; overflow-y:auto; }'
      + '.chat-sidebar.open { transform:translateX(0); }'

      /* backdrop behind the drawer */
      + '.chat-sidebar-backdrop { display:none; position:fixed; inset:0;'
      +   ' z-index:99; background:rgba(0,0,0,0.4); }'
      + '.chat-sidebar-backdrop.visible { display:block; }'

      /* middle pane: full width */
      + '.chat-mp-main { max-width:none !important; flex:1 !important; }'

      /* bottom padding so last messages sit above the compose bar */
      + '.chat-mp-history { padding-bottom:56px !important; }'

      /* right sidebar → fixed bottom bar */
      + '.chat-compose { width:auto !important; flex:none !important;'
      +   ' position:fixed; bottom:0; left:0; right:0; z-index:50;'
      +   ' background:var(--cc-bg); border-top:1px solid var(--cc-border);'
      +   ' max-height:45vh; }'
      + '.chat-compose .chat-closed-panel { padding:8px 12px; }'
      + '.chat-compose .chat-keyhelp { display:none; }'
      + '.chat-compose-body { padding:8px 12px; }'
      + '.chat-compose textarea { min-height:80px; max-height:25vh;'
      +   ' flex:none; resize:none; font-size:16px; }'

      /* hamburger button */
      + '.chat-hamburger { display:inline-block; background:none; border:none;'
      +   ' font-size:22px; cursor:pointer; padding:0 8px;'
      +   ' color:var(--cc-accent); vertical-align:middle; }'

      /* compose collapse bar */
      + '.chat-compose-collapse { display:flex; justify-content:flex-end;'
      +   ' margin-bottom:4px; }'
      + '.chat-compose-collapse-btn { background:none; border:none;'
      +   ' color:var(--cc-muted-fg); font-size:18px; cursor:pointer;'
      +   ' padding:2px 4px; line-height:1; }'

      + '}' /* end @media */

      /* ===== desktop: hide mobile-only elements ===== */
      + '@media (min-width:769px) {'
      + '.chat-hamburger { display:none; }'
      + '.chat-sidebar-backdrop { display:none !important; }'
      + '.chat-compose-collapse { display:none; }'
      + '}';

    document.head.appendChild(s);
    stylesInjected = true;
  }

  // lint:called-once toggle-counterpart
  function openSidebar(){
    if(!sidebar) return;
    sidebar.classList.add('open');
    backdrop.classList.add('visible');
  }
  function closeSidebar(){
    if(!sidebar) return;
    sidebar.classList.remove('open');
    backdrop.classList.remove('visible');
  }
  function toggleSidebar(){
    if(sidebar && sidebar.classList.contains('open')) closeSidebar();
    else openSidebar();
  }

  /* Close the drawer on any in-sidebar link click — navigating away
     should feel like closing a menu. */
  // lint:called-once init-section
  function wireAutoClose(){
    sidebar.addEventListener('click', function(e){
      if(e.target.tagName === 'A') closeSidebar();
    });
  }

  /* When the viewport crosses the breakpoint (e.g. device rotation),
     reset drawer state so the sidebar doesn't stick open. */
  function onBreakpointChange(){
    if(!mql.matches) closeSidebar();
  }

  function init(deps){
    ensureStyles();
    sidebar = deps.sidebar;
    var topBar = deps.topBar;

    /* Build backdrop overlay */
    backdrop = document.createElement('div');
    backdrop.className = 'chat-sidebar-backdrop';
    backdrop.addEventListener('click', closeSidebar);
    document.body.appendChild(backdrop);

    /* Build hamburger button, prepend to the top-bar left group */
    hamburger = document.createElement('button');
    hamburger.type = 'button';
    hamburger.className = 'chat-hamburger';
    hamburger.setAttribute('aria-label', 'Toggle sidebar');
    hamburger.textContent = '\u2630'; /* ☰ */
    hamburger.addEventListener('click', toggleSidebar);
    var topLeft = topBar.querySelector('.chat-top-left');
    if(topLeft) topLeft.insertBefore(hamburger, topLeft.firstChild);

    wireAutoClose();

    /* Compose collapse bar — a ▾ button prepended to the compose body
       so mobile users can dismiss the compose panel without Esc. Hidden
       on desktop via the @media rule above. */
    var composeBody = document.getElementById('chat-compose-body');
    if(composeBody){
      var bar = document.createElement('div');
      bar.className = 'chat-compose-collapse';
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'chat-compose-collapse-btn';
      btn.setAttribute('aria-label', 'Collapse compose box');
      btn.textContent = '\u25BE'; /* ▾ */
      btn.addEventListener('click', function(){ ChatRightSidebar.closeCompose(); });
      bar.appendChild(btn);
      composeBody.insertBefore(bar, composeBody.firstChild);
    }

    /* Listen for breakpoint changes */
    mql = window.matchMedia('(max-width:768px)');
    mql.addEventListener('change', onBreakpointChange);
  }

  return { init:init, closeSidebar:closeSidebar };
})();
