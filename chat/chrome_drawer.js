/* ChromeDrawer — the shared mobile nav, on every chrome page.

   The server (chrome.zig) ships only the desktop top bar: "Home", a
   title, the section nav (.chat-top-links), and the account links
   (.app-top-user). It knows nothing about small screens. This widget
   owns that adaptation entirely: on narrow viewports it hides the inline
   nav and presents the SAME links — read straight out of the top bar —
   as a left drawer behind a ☰ hamburger, with a backdrop. The server
   decides WHICH links exist; the client decides WHERE they show.

   #chrome-drawer-extra is an empty slot the chat conversation page fills
   with its conversations rail (ChatResponsive), so on mobile the drawer
   is one place: section nav + (on chat) conversations + account links.

   Loaded deferred from <head>, so the top bar is already parsed when
   this runs. Widget owns its CSS (injected here) — the server emits no
   drawer markup and no responsive rules. */
window.ChromeDrawer = (function(){
  'use strict';

  var drawer, backdrop;

  function el(tag, cls){
    var e = document.createElement(tag);
    if(cls) e.className = cls;
    return e;
  }

  /* Clone every element matching `selector` into `dest` — the drawer
     reuses the exact <a>/<strong> the server rendered (href, label, and
     the active item's bold-no-link form all come for free). */
  function cloneLinks(selector, dest){
    var nodes = document.querySelectorAll(selector);
    for(var i = 0; i < nodes.length; i++) dest.appendChild(nodes[i].cloneNode(true));
  }

  function close(){
    drawer.classList.remove('open');
    backdrop.classList.remove('open');
  }

  // lint:called-once init-once-guard
  function ensureStyles(){
    var s = document.createElement('style');
    s.textContent = ''
      + '.chrome-burger { display:none; background:none; border:none; cursor:pointer;'
      +   ' font-size:22px; line-height:1; padding:0 10px 0 0; color:var(--cc-accent,#000080); }'
      + '.chrome-drawer { display:none; }'
      + '.chrome-backdrop { display:none; }'
      + '.chrome-drawer-user { font-weight:bold; color:var(--cc-accent,#000080);'
      +   ' padding-bottom:8px; margin-bottom:6px; border-bottom:1px solid var(--cc-border,#c9bfa7); }'
      + '.chrome-drawer-nav a, .chrome-drawer-nav strong, .chrome-drawer-foot a {'
      +   ' display:block; padding:8px 6px; border-radius:4px; text-decoration:none;'
      +   ' color:var(--cc-accent,#000080); }'
      + '.chrome-drawer-nav a:hover, .chrome-drawer-foot a:hover { background:var(--cc-accent-soft-bg,#e8e4d8); }'
      + '.chrome-drawer-nav strong { background:var(--cc-accent,#000080); color:var(--cc-bg,#fff); }'
      + '.chrome-drawer-foot { margin-top:auto; padding-top:6px; border-top:1px solid var(--cc-border,#c9bfa7); }'
      + '@media (max-width:768px) {'
      +   ' .app-top { padding:8px 12px; }'
      +   ' .chat-top-links { display:none; }'
      +   ' .app-top-user-extra { display:none; }'
      +   ' .chrome-burger { display:inline-block; }'
      +   ' .chrome-drawer { display:flex; flex-direction:column; gap:2px;'
      +     ' position:fixed; top:0; left:0; bottom:0; width:260px; z-index:100;'
      +     ' box-sizing:border-box; padding:14px; overflow-y:auto;'
      +     ' background:var(--cc-bg,#fff); border-right:1px solid var(--cc-border,#c9bfa7);'
      +     ' transform:translateX(-100%); transition:transform 0.25s ease; }'
      +   ' .chrome-drawer.open { transform:translateX(0); }'
      +   ' .chrome-backdrop { position:fixed; inset:0; z-index:99; background:rgba(0,0,0,0.4); }'
      +   ' .chrome-backdrop.open { display:block; }'
      + '}';
    document.head.appendChild(s);
  }

  var topLeft = document.querySelector('.chat-top-left');
  if(!topLeft) return {}; /* not a chrome page — nothing to adapt */
  ensureStyles();

  /* Hamburger, first thing in the top bar's left group. */
  var burger = el('button', 'chrome-burger');
  burger.type = 'button';
  burger.setAttribute('aria-label', 'Menu');
  burger.textContent = '☰'; /* ☰ */
  topLeft.insertBefore(burger, topLeft.firstChild);

  backdrop = el('div', 'chrome-backdrop');
  document.body.appendChild(backdrop);

  /* Drawer: viewer name, the section nav, the conversations slot (filled
     by the chat page), then the account links. */
  drawer = el('nav', 'chrome-drawer');
  drawer.setAttribute('aria-label', 'Menu');

  var nameEl = document.querySelector('.app-top-user strong');
  if(nameEl){
    var who = el('div', 'chrome-drawer-user');
    who.textContent = nameEl.textContent;
    drawer.appendChild(who);
  }

  var nav = el('div', 'chrome-drawer-nav');
  cloneLinks('.chat-top-links a, .chat-top-links strong', nav);
  drawer.appendChild(nav);

  var extraSlot = el('div', null);
  extraSlot.id = 'chrome-drawer-extra';
  drawer.appendChild(extraSlot);

  var foot = el('div', 'chrome-drawer-foot');
  cloneLinks('.app-top-user a', foot);
  drawer.appendChild(foot);

  document.body.appendChild(drawer);

  /* Group the top bar's name + account links into one span so the mobile
     rule can hide them as a unit — hiding the bare <a>s would strand the
     " · " text separators between them. The 🌙 toggle stays visible. */
  var user = document.querySelector('.app-top-user');
  var toggle = document.getElementById('chat-theme-toggle');
  if(user && toggle){
    var extra = el('span', 'app-top-user-extra');
    while(toggle.nextSibling) extra.appendChild(toggle.nextSibling);
    user.appendChild(extra);
  }

  burger.addEventListener('click', function(){
    var willOpen = drawer.classList.toggle('open');
    backdrop.classList.toggle('open', willOpen);
  });
  backdrop.addEventListener('click', close);
  /* A link tap inside the drawer is a navigation — close behind it. */
  drawer.addEventListener('click', function(e){
    if(e.target.tagName === 'A') close();
  });
  /* Crossing back to desktop width (rotate) must not leave the drawer
     stuck open under the restored top-bar nav. */
  var mql = window.matchMedia('(max-width:768px)');
  mql.addEventListener('change', function(){ if(!mql.matches) close(); });

  return { close: close };
})();
