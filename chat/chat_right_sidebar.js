/* PRODUCT_DECISION: slim by design — only flips visibility between
   #chat-compose-body and #chat-closed-panel and wires the open-compose button.
   Parallels chat_left_sidebar.js so future-Claude finds each rail in a
   predictable file. */
window.ChatRightSidebar = (function(){
  'use strict';

  var composeBody, closedPanel;
  var onOpen, onClose;

  function openCompose(){
    closedPanel.style.display='none';
    composeBody.style.display='';
    if(onOpen) onOpen();
  }
  function closeCompose(){
    composeBody.style.display='none';
    closedPanel.style.display='';
    if(onClose) onClose();
  }

  function init(deps){
    composeBody=document.getElementById('chat-compose-body');
    closedPanel=document.getElementById('chat-closed-panel');
    onOpen=deps.onOpen; onClose=deps.onClose;
    var btn=document.getElementById('chat-open-compose');
    if(btn) btn.addEventListener('click', openCompose);
  }
  return { init:init, openCompose:openCompose, closeCompose:closeCompose };
})();
