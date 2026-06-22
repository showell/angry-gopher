/* ChatResponsive — chat-conversation-page mobile layout.

   The shared hamburger + nav drawer live in ChromeDrawer
   (chrome_drawer.js, loaded on every chrome page). This module owns only
   the chat-page-specific small-screen behavior:

     - The 3-column .chat-layout collapses to a single full-width feed.
     - The conversations rail (#chat-left-sidebar) is relocated into the
       shared drawer's #chrome-drawer-extra slot on mobile (and back to
       the layout column on desktop) — so the drawer reads as one panel:
       section nav (from ChromeDrawer) + conversations.
     - The right sidebar becomes a bottom compose bar with a ▾ collapse
       button. It stays IN FLOW: the column tiles as feed (flex:1) above
       compose (flex:none), so the bar sits at the bottom and the feed
       scrolls in the space that's left — no overlap, whatever the bar's
       height. JS owns the mode (column vs row, via the vp-narrow class);
       flexbox owns the geometry. No fixed-positioning, no height
       measurement.

   Runs from chat.js. Reads the breakpoint from Viewport (the single
   authority) — never its own matchMedia. The first sidebar placement waits
   for DOMContentLoaded, because ChromeDrawer (deferred) builds the
   #chrome-drawer-extra slot only after chat.js has run. */
window.ChatResponsive = (function(){
  'use strict';

  // lint:called-once init-once-guard
  function ensureStyles(){
    var s = document.createElement('style');
    /* Narrow-screen rules hang off html.vp-narrow (set by Viewport) — no
       @media, so the breakpoint lives only in Viewport. The compose-collapse
       button defaults to hidden and is revealed only when narrow. */
    s.textContent = ''

      /* single-column, full-bleed feed */
      + 'html.vp-narrow .app-body-wrap { margin:0; padding:0; }'
      + 'html.vp-narrow .chat-layout { flex-direction:column; gap:0; }'
      + 'html.vp-narrow .chat-mp-main { max-width:none !important; flex:1 !important; }'

      /* the conversations rail, once relocated into the chrome drawer:
         drop the desktop column chrome (fixed width + right border) and
         set it off from the section nav sitting above it */
      + 'html.vp-narrow .chrome-drawer .chat-sidebar { width:auto; border-right:none;'
      +   ' padding-right:0; overflow-y:visible; margin-top:8px; padding-top:8px;'
      +   ' border-top:1px solid var(--cc-border); }'

      /* right sidebar → in-flow bottom compose bar. flex:none + the feed's
         flex:1 tile the column; no fixed positioning, so no overlap to
         compensate for. max-height caps a long open textarea. */
      + 'html.vp-narrow .chat-compose { width:auto; flex:none;'
      +   ' background:var(--cc-bg); border-top:1px solid var(--cc-border);'
      +   ' max-height:45vh; }'
      + 'html.vp-narrow .chat-compose .chat-closed-panel { padding:8px 12px; }'
      + 'html.vp-narrow .chat-compose .chat-keyhelp { display:none; }'
      + 'html.vp-narrow .chat-compose-body { padding:8px 12px; }'
      + 'html.vp-narrow .chat-compose textarea { min-height:80px; max-height:25vh;'
      +   ' flex:none; resize:none; font-size:16px; }'

      /* compose collapse bar: hidden by default, shown when narrow */
      + '.chat-compose-collapse { display:none; }'
      + 'html.vp-narrow .chat-compose-collapse { display:flex; justify-content:flex-end;'
      +   ' margin-bottom:4px; }'
      + '.chat-compose-collapse-btn { background:none; border:none;'
      +   ' color:var(--cc-muted-fg); font-size:18px; cursor:pointer;'
      +   ' padding:2px 4px; line-height:1; }';

    document.head.appendChild(s);
  }

  /* Relocate the conversations rail between the desktop layout column and
     the shared mobile drawer, by current breakpoint. Moving the node (vs
     rebuilding) preserves the widget's listeners + live SSE subscription. */
  function placeSidebar(){
    var sb = document.getElementById('chat-left-sidebar');
    if(!sb) return;
    if(Viewport.isNarrow()){
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
       desktop (shown only under html.vp-narrow) by the rule above. */
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

    /* Viewport owns the breakpoint. placeSidebar runs on each crossing and on
       DOMContentLoaded — the latter because ChromeDrawer (deferred) builds the
       #chrome-drawer-extra slot only after this code runs, so the immediate
       onChange is too early for the first relocation. The compose/feed layout
       itself is pure flex now (see ensureStyles) — no JS to drive it. */
    Viewport.onChange(placeSidebar);
    document.addEventListener('DOMContentLoaded', placeSidebar);
  }

  return { init:init };
})();
