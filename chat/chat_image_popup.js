/* Image popup — shared by chat bubbles (Message), search results, and the
   Images transcript. The dialog is fit-content (CSS) inside the modal;
   a range slider scales height, scroll pans, the inner <pre> overflows
   when the image is bigger than the viewport.

   Exposed as `window.ChatImagePopup.show(src)`. No instance state; each
   call builds a fresh <dialog>, stacks natively over other modals, and
   self-removes on close. */
window.ChatImagePopup = (function(){
  'use strict';

  function show(src){
    var dlg=document.createElement('dialog'); dlg.className='chat-img-dialog';
    var controls=document.createElement('div'); controls.className='chat-img-controls';
    var range=document.createElement('input'); range.type='range';
    range.min='1'; range.max='8'; range.step='0.05'; range.value='1';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click', function(){ dlg.close(); });
    controls.appendChild(range); controls.appendChild(close);
    var scroll=document.createElement('div'); scroll.className='chat-img-scroll';
    var img=document.createElement('img'); img.alt='';
    scroll.appendChild(img);
    dlg.appendChild(controls); dlg.appendChild(scroll);
    dlg.addEventListener('close', function(){ dlg.remove(); });
    document.body.appendChild(dlg);
    /* PRODUCT_DECISION: fitW/fitH = largest size that fits the fixed container
       (computed once natural + container sizes are known); the slider multiplies. */
    var fitW=0, fitH=0;
    function applyZoom(){
      if(!fitW) return;
      var z=parseFloat(range.value);
      img.style.width=(fitW*z)+'px'; img.style.height=(fitH*z)+'px';
    }
    function fit(){
      var cw=scroll.clientWidth, ch=scroll.clientHeight, nw=img.naturalWidth, nh=img.naturalHeight;
      if(!cw||!ch||!nw||!nh) return;
      var s=Math.min(cw/nw, ch/nh);
      fitW=nw*s; fitH=nh*s; applyZoom();
    }
    range.addEventListener('input', applyZoom);
    dlg.showModal();
    img.addEventListener('load', fit);
    img.src=src;
    if(img.complete) fit();
  }

  return { show: show };
})();
