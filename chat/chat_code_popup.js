/* Code popup — shared by chat bubbles (Message), search results, and the
   Code transcript. The dialog is fit-content (CSS) capped at 80vw/80vh;
   the <pre> scrolls when the snippet is larger. Esc (native) or a
   backdrop click also closes it.

   Exposed as `window.ChatCodePopup.show(text)`. No instance state; each
   call builds a fresh <dialog>, stacks natively over other modals, and
   self-removes on close. */
window.ChatCodePopup = (function(){
  'use strict';

  function show(text){
    var dlg=document.createElement('dialog'); dlg.className='chat-code-dialog';
    var controls=document.createElement('div'); controls.className='chat-code-controls';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click', function(){ dlg.close(); });
    controls.appendChild(close);
    var pre=document.createElement('pre'); pre.className='chat-code-view'; pre.textContent=text;
    dlg.appendChild(controls); dlg.appendChild(pre);
    dlg.addEventListener('close', function(){ dlg.remove(); });
    dlg.addEventListener('click', function(e){ if(e.target===dlg) dlg.close(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  return { show: show };
})();
