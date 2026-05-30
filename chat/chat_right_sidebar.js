/* PRODUCT_DECISION: slim by design — only flips visibility between
   #chat-compose-body and #chat-closed-panel and wires the open-compose button.
   Parallels chat_left_sidebar.js so future-Claude finds each rail in a
   predictable file. */
window.ChatRightSidebar = (function(){
  'use strict';

  var composeBody, closedPanel, textarea, history;

  function openCompose(){
    closedPanel.style.display='none';
    composeBody.style.display='';
    textarea.focus();
  }
  function closeCompose(){
    composeBody.style.display='none';
    closedPanel.style.display='';
    history.focus({preventScroll:true});
  }

  function init(deps){
    composeBody=deps.composeBody;
    closedPanel=deps.closedPanel;
    textarea=deps.textarea;
    history=deps.history;
    var btn=document.getElementById('chat-open-compose');
    if(btn) btn.addEventListener('click', openCompose);
  }
  return { init:init, openCompose:openCompose, closeCompose:closeCompose };
})();
