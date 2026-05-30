/* Chat right sidebar — the right column shell on the conversation page,
   which switches between two states: the OPEN compose form (chat_compose.js)
   and the CLOSED panel (the "Open compose box" button + the keyboard
   shortcut reference that's currently server-rendered HTML).

   This module is comically slim by design — its only job is to flip
   visibility between #chat-compose-body and #chat-closed-panel and to
   wire the "Open compose box" button. The parallel with the left sidebar
   is intentional: nearly every chat UI partitions the conversation page
   into left rail / center feed / right rail, and we want future-Claude
   to find each rail in a predictable file even when the right one is
   trivial.

   Boundary:
     CONSUMERS (callers of openCompose / closeCompose)
       - chat.js: quote-reply / refer / edit each open compose so the
         next keystroke goes into the textarea.
       - chat_help.js: the 'c' keybind calls openCompose.
       - chat_compose.js: the textarea's Esc-empty handler calls
         closeCompose (passed in as a dep at init time to keep the
         direction sibling → sibling, not circular).
     OWNS
       - the OPEN/CLOSED visibility toggle of #chat-compose-body and
         #chat-closed-panel.
       - the #chat-open-compose click binding.
     DOES NOT OWN
       - what's inside the compose form (chat_compose.js).
       - what's inside the closed-panel's help UI (server-rendered HTML;
         no JS counterpart yet — see chat_help.js for the future seam).

   Loaded as a sibling of chat.js (BEFORE chat.js). */
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
