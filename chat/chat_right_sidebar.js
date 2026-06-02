/* ChatRightSidebar — the right rail's wrapper + open/closed toggle.

   Builds its own DOM into a caller-supplied mount element:

     <mount class="chat-compose">
       <div class="chat-closed-panel" id="chat-closed-panel">
         <button id="chat-open-compose" class="chat-open-compose">Open compose box</button>
         <!-- ChatHelp.init() appends its keyhelp panel here -->
       </div>
       <!-- ChatCompose.init() inserts its compose-body BEFORE the closed-panel -->
     </mount>

   Two children, two states, flipped by openCompose / closeCompose.
   getWrapper() / getClosedPanel() expose those refs to ChatCompose so
   it doesn't need to re-query the DOM (and works in demos where the
   widget isn't attached to document.body at init time).

   Parallels chat_left_sidebar.js so future-Claude finds each rail in a
   predictable file. */
window.ChatRightSidebar = (function(){
  'use strict';

  var wrapper, composeBody, closedPanel;
  var onOpen, onClose;

  /* PRODUCT_DECISION: widget owns its own CSS — the "Open compose box"
     button and the wrapper's structural rules. Page-level orientation
     @media queries still live in chat.go because they reach across
     .chat-layout / .chat-sidebar / .chat-compose. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-open-compose { font-size:13px; padding:4px 12px; background:#e7e7ff; color:#23235a;'
      +                    ' border:1px solid #b9b9e0; border-radius:6px; cursor:pointer; }'
      + '.chat-open-compose:hover { background:#dcdcff; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  function openCompose(){
    if(!composeBody) return; /* ChatCompose hasn't initialized yet (shouldn't happen). */
    closedPanel.style.display='none';
    composeBody.style.display='';
    if(onOpen) onOpen();
  }
  function closeCompose(){
    if(!composeBody) return;
    composeBody.style.display='none';
    closedPanel.style.display='';
    if(onClose) onClose();
  }

  function init(deps){
    ensureStyles();
    onOpen=deps.onOpen; onClose=deps.onClose;

    /* Caller hands us a mount element; we decorate it with the
       chat-compose class so the page-level @media queries (which size
       the right rail in landscape) match. */
    wrapper = deps.mount;
    wrapper.className = 'chat-compose';

    /* Closed panel + Open-compose button, built in DOM order. The
       keyhelp gets appended by ChatHelp.init() later. */
    closedPanel = document.createElement('div');
    closedPanel.id = 'chat-closed-panel';
    closedPanel.className = 'chat-closed-panel';
    var openBtn = document.createElement('button');
    openBtn.type = 'button';
    openBtn.id = 'chat-open-compose';
    openBtn.className = 'chat-open-compose';
    openBtn.textContent = 'Open compose box';
    openBtn.addEventListener('click', openCompose);
    closedPanel.appendChild(openBtn);
    wrapper.appendChild(closedPanel);

    /* ChatCompose.init() will set this once its body lands in the DOM. */
    composeBody = null;
  }

  /* PRODUCT_DECISION: ChatCompose hands us its body element on init so
     we have a stable reference for the open/closed toggle, without
     re-querying the DOM each time. */
  function registerComposeBody(el){ composeBody = el; }
  function getWrapper(){ return wrapper; }
  function getClosedPanel(){ return closedPanel; }

  return { init:init, openCompose:openCompose, closeCompose:closeCompose,
           registerComposeBody:registerComposeBody,
           getWrapper:getWrapper, getClosedPanel:getClosedPanel };
})();
