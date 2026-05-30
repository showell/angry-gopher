/* PRODUCT_DECISION: keymap mirrors the chat-keyhelp panel (server-rendered on
   the closed-compose side). Two faces of one contract — add a key here, add
   a row there. Feed-focused only: skips text inputs so the user can type into
   compose. */
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
        case 'b': e.preventDefault(); d.backBtn.click(); return; /* BROWSER_WORKAROUND: disabled buttons ignore click. */
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
