/* Image popup — shared by chat bubbles (Message), search results, and the
   Images transcript. The dialog is fit-content (UA default) inside the
   modal; a range slider scales height, scroll pans, the inner <pre>
   overflows when the image is bigger than the viewport.

   Exposed as `window.ChatImagePopup.show(src)`. Self-contained: this
   module owns ALL its styling. Element styles are set via
   Object.assign on .style; the one rule that can't be inlined
   (::backdrop is a pseudo-element) is injected as a single <style> tag
   the first time show() runs. No external CSS needed — drop the script
   into any page and it works.

   No instance state; each call builds a fresh <dialog>, stacks natively
   over other modals, and self-removes on close. */
window.ChatImagePopup = (function(){
  'use strict';

  /* PRODUCT_DECISION: ::backdrop is the one rule that can't go on
     element.style (it's a pseudo-element). Injected once per page load,
     class-scoped so the rule only matches this popup's dialogs. */
  var backdropStyleInjected = false;
  // lint:called-once init-once-guard
  function ensureBackdropStyle(){
    if(backdropStyleInjected) return;
    var s = document.createElement('style');
    s.textContent = 'dialog.chat-img-dialog::backdrop { background:var(--cc-backdrop); }';
    document.head.appendChild(s);
    backdropStyleInjected = true;
  }

  function show(src){
    ensureBackdropStyle();
    var dlg = document.createElement('dialog');
    /* PRODUCT_DECISION: the class is kept ONLY so the ::backdrop rule has
       something to attach to; nothing else selects on it. */
    dlg.className = 'chat-img-dialog';
    Object.assign(dlg.style, {
      border: '1px solid '+ChatColors.accent, borderRadius: '10px', padding: '10px',
      background: ChatColors.bg, color: ChatColors.fg,
      display: 'flex', flexDirection: 'column', gap: '8px',
    });

    var controls = document.createElement('div');
    Object.assign(controls.style, {
      display: 'flex', alignItems: 'center', gap: '10px',
    });
    var range = document.createElement('input');
    range.type = 'range'; range.min = '1'; range.max = '8'; range.step = '0.05'; range.value = '1';
    range.style.flex = '1';
    var close = document.createElement('button');
    close.type = 'button'; close.textContent = 'Close';
    close.addEventListener('click', function(){ dlg.close(); });
    controls.appendChild(range); controls.appendChild(close);

    /* PRODUCT_DECISION: fixed viewport so the slider stays put. The image
       is scaled in px inside it and overflows into scrollbars when zoomed. */
    var scroll = document.createElement('div');
    Object.assign(scroll.style, {
      width: '70vw', height: '70vh', overflow: 'auto',
      background: ChatColors.codeStrapBg, borderRadius: '6px',
    });
    var img = document.createElement('img'); img.alt = '';
    img.style.display = 'block';
    scroll.appendChild(img);
    dlg.appendChild(controls); dlg.appendChild(scroll);
    dlg.addEventListener('close', function(){ dlg.remove(); });
    document.body.appendChild(dlg);

    /* PRODUCT_DECISION: fitW/fitH = largest size that fits the fixed
       container (computed once natural + container sizes are known); the
       slider multiplies. */
    var fitW = 0, fitH = 0;
    function applyZoom(){
      if(!fitW) return;
      var z = parseFloat(range.value);
      img.style.width = (fitW * z) + 'px';
      img.style.height = (fitH * z) + 'px';
    }
    function fit(){
      var cw = scroll.clientWidth, ch = scroll.clientHeight, nw = img.naturalWidth, nh = img.naturalHeight;
      if(!cw || !ch || !nw || !nh) return;
      var s = Math.min(cw / nw, ch / nh);
      fitW = nw * s; fitH = nh * s; applyZoom();
    }
    range.addEventListener('input', applyZoom);
    dlg.showModal();
    img.addEventListener('load', fit);
    img.src = src;
    if(img.complete) fit();
  }

  return { show: show };
})();
