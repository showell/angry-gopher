/* ChatResponsive — chat-conversation-page mobile layout.

   The shared hamburger + nav drawer live in ChromeDrawer
   (chrome_drawer.js, loaded on every chrome page). This module owns only
   the chat-page-specific small-screen behavior:

     - The 3-column .chat-layout collapses to a single full-width feed.
     - The conversations rail (#chat-left-sidebar) is relocated into the
       shared drawer's #chrome-drawer-extra slot on mobile (and back to
       the layout column on desktop) — so the drawer reads as one panel:
       section nav (from ChromeDrawer) + conversations.
     - The right sidebar becomes a fixed bottom compose bar with a ▾
       collapse button.

   Runs from chat.js. The first sidebar placement waits for
   DOMContentLoaded, because ChromeDrawer (deferred) builds the
   #chrome-drawer-extra slot only after chat.js has run. */
window.ChatResponsive = (function(){
  'use strict';

  var mql;

  // lint:called-once init-once-guard
  function ensureStyles(){
    var s = document.createElement('style');
    s.textContent = ''

      /* ===== mobile (<=768px) ===== */
      + '@media (max-width:768px) {'

      /* single-column, full-bleed feed */
      + '.app-body-wrap { margin:0; padding:0; }'
      + '.chat-layout { flex-direction:column; gap:0; }'
      + '.chat-mp-main { max-width:none !important; flex:1 !important; }'

      /* bottom padding so the last messages clear the fixed compose bar */
      + '.chat-mp-history { padding-bottom:56px !important; }'

      /* the conversations rail, once relocated into the chrome drawer:
         drop the desktop column chrome (fixed width + right border) and
         set it off from the section nav sitting above it */
      + '.chrome-drawer .chat-sidebar { width:auto; border-right:none;'
      +   ' padding-right:0; overflow-y:visible; margin-top:8px; padding-top:8px;'
      +   ' border-top:1px solid var(--cc-border); }'

      /* right sidebar → fixed bottom compose bar */
      + '.chat-compose { width:auto !important; flex:none !important;'
      +   ' position:fixed; bottom:0; left:0; right:0; z-index:50;'
      +   ' background:var(--cc-bg); border-top:1px solid var(--cc-border);'
      +   ' max-height:45vh; }'
      + '.chat-compose .chat-closed-panel { padding:8px 12px; }'
      + '.chat-compose .chat-keyhelp { display:none; }'
      + '.chat-compose-body { padding:8px 12px; }'
      + '.chat-compose textarea { min-height:80px; max-height:25vh;'
      +   ' flex:none; resize:none; font-size:16px; }'

      /* compose collapse bar */
      + '.chat-compose-collapse { display:flex; justify-content:flex-end;'
      +   ' margin-bottom:4px; }'
      + '.chat-compose-collapse-btn { background:none; border:none;'
      +   ' color:var(--cc-muted-fg); font-size:18px; cursor:pointer;'
      +   ' padding:2px 4px; line-height:1; }'

      + '}' /* end @media */

      /* ===== desktop: hide mobile-only compose affordance ===== */
      + '@media (min-width:769px) {'
      + '.chat-compose-collapse { display:none; }'
      + '}';

    document.head.appendChild(s);
  }

  /* Relocate the conversations rail between the desktop layout column and
     the shared mobile drawer, by current breakpoint. Moving the node (vs
     rebuilding) preserves the widget's listeners + live SSE subscription. */
  function placeSidebar(){
    var sb = document.getElementById('chat-left-sidebar');
    if(!sb) return;
    if(mql.matches){
      var slot = document.getElementById('chrome-drawer-extra');
      if(slot) slot.appendChild(sb);
    } else {
      var layout = document.querySelector('.chat-layout');
      var feed = document.getElementById('chat-feed');
      if(layout && feed) layout.insertBefore(sb, feed);
    }
  }

  function init(){
    ensureStyles();

    /* Compose collapse bar — a ▾ button prepended to the compose body so
       mobile users can dismiss the compose panel without Esc. Hidden on
       desktop via the @media rule above. */
    var composeBody = document.getElementById('chat-compose-body');
    if(composeBody){
      var bar = document.createElement('div');
      bar.className = 'chat-compose-collapse';
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'chat-compose-collapse-btn';
      btn.setAttribute('aria-label', 'Collapse compose box');
      btn.textContent = '▾';
      btn.addEventListener('click', function(){ ChatRightSidebar.closeCompose(); });
      bar.appendChild(btn);
      composeBody.insertBefore(bar, composeBody.firstChild);
    }

    mql = window.matchMedia('(max-width:768px)');
    document.addEventListener('DOMContentLoaded', placeSidebar);
    mql.addEventListener('change', placeSidebar);
  }

  return { init:init };
})();
