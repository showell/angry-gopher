/* Chat help — the global keyboard-shortcut dispatcher for the
   conversation page. The chat-keyhelp panel that's visible on the
   closed-compose side of the right sidebar (q/r/e/b/f/t/// keys, see
   server/chat/chat.go renderChatConversation) lists exactly the keys
   this module dispatches. The panel and the dispatcher are two faces
   of the same contract — when we add a key, we add it in both places;
   when we remove one, we remove the other.

   That symmetry is the reason this lives in its own file rather than
   the chat.js feed engine. The "what keys do" surface is small and
   stable, and a future "show the full help dialog" or "render the
   keyhelp panel from a single JS source" would slot in here.

   Boundary:
     CONSUMES (input)
       - keydown events on document, but only when the feed is focused
         (text inputs are skipped so the user can type into compose).
     DISPATCHES TO (via deps passed at init)
       - openCompose                — from chat_right_sidebar
       - backBtn / fwdBtn (click)   — DOM refs that the navbar provides
       - toggleView                 — chat.js
       - quoteReply / referReply / editMessage — chat.js, called on the
         currently-selected message (getSelected() returns the live
         reference, since selection mutates inside chat.js)
       - moveCursor / cursorToExtreme / pageNav — chat.js cursor nav
       - ChatSearch.open()          — global, already exported by
         chat_search.js, so not threaded through deps.

   Loaded as a sibling of chat.js (BEFORE chat.js). */
window.ChatHelp = (function(){
  'use strict';

  function init(deps){
    var d=deps;
    document.addEventListener('keydown', function(e){
      var ae=document.activeElement;
      if(ae&&(ae.tagName==='TEXTAREA'||ae.tagName==='INPUT'||ae.isContentEditable)) return;
      if(e.ctrlKey||e.metaKey||e.altKey) return;
      switch(e.key){
        case 'c': e.preventDefault(); d.openCompose(); return;
        case 'b': e.preventDefault(); d.backBtn.click(); return; /* disabled buttons ignore click */
        case 'f': e.preventDefault(); d.fwdBtn.click(); return;
        case 't': e.preventDefault(); d.toggleView(); return;
        case '/': e.preventDefault(); ChatSearch.open(); return;
        case 'q': { var s=d.getSelected(); if(s){ e.preventDefault(); d.quoteReply(s); } return; }
        case 'r': { var s=d.getSelected(); if(s){ e.preventDefault(); d.referReply(s); } return; }
        case 'e': { var s=d.getSelected(); if(s){ e.preventDefault(); d.editMessage(s); } return; }
        case 'ArrowDown': e.preventDefault(); d.moveCursor(1); return;
        case 'ArrowUp':   e.preventDefault(); d.moveCursor(-1); return;
        case 'Home':      e.preventDefault(); d.cursorToExtreme(false); return;
        case 'End':       e.preventDefault(); d.cursorToExtreme(true); return;
        case 'PageDown':  e.preventDefault(); d.pageNav(1); return;
        case 'PageUp':    e.preventDefault(); d.pageNav(-1); return;
      }
    });
  }
  return { init:init };
})();
