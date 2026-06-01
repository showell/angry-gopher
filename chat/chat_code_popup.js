/* Code popup — shared by chat bubbles (Message), search results, and the
   Code transcript. The dialog is fit-content (UA default) capped at
   80vw/80vh; the <pre> scrolls when the snippet is larger. Esc (native)
   or a backdrop click also closes it.

   Exposed as `window.ChatCodePopup.show(text)`. Self-contained: this
   module owns ALL its styling. Element styles are set via Object.assign
   on .style; the one rule that can't be inlined (::backdrop is a pseudo-
   element) is injected as a single <style> tag the first time show()
   runs. No external CSS needed — drop the script into any page and it
   works.

   No instance state; each call builds a fresh <dialog>, stacks natively
   over other modals, and self-removes on close. */
window.ChatCodePopup = (function(){
  'use strict';

  /* PRODUCT_DECISION: ::backdrop is the one rule that can't go on
     element.style (it's a pseudo-element). Injected once per page load,
     class-scoped so the rule only matches this popup's dialogs. */
  var backdropStyleInjected = false;
  // lint:called-once init-once-guard
  function ensureBackdropStyle(){
    if(backdropStyleInjected) return;
    var s = document.createElement('style');
    s.textContent = 'dialog.chat-code-dialog::backdrop { background:rgba(0,0,0,0.45); }';
    document.head.appendChild(s);
    backdropStyleInjected = true;
  }

  function show(text){
    ensureBackdropStyle();
    var dlg = document.createElement('dialog');
    /* PRODUCT_DECISION: the class is kept ONLY so the ::backdrop rule has
       something to attach to; nothing else selects on it. */
    dlg.className = 'chat-code-dialog';
    Object.assign(dlg.style, {
      maxWidth: '80vw', maxHeight: '80vh', padding: '0',
      border: '1px solid #bbb', borderRadius: '8px', background: '#fff',
      display: 'flex', flexDirection: 'column',
    });

    var controls = document.createElement('div');
    Object.assign(controls.style, {
      flex: 'none', display: 'flex', justifyContent: 'flex-end',
      padding: '6px 8px', borderBottom: '1px solid #eee', background: '#faf9f5',
    });
    var close = document.createElement('button');
    close.type = 'button'; close.textContent = 'Close';
    close.addEventListener('click', function(){ dlg.close(); });
    controls.appendChild(close);

    var pre = document.createElement('pre');
    pre.textContent = text;
    Object.assign(pre.style, {
      flex: '1', minHeight: '0', minWidth: '0', overflow: 'auto',
      margin: '0', padding: '14px 16px',
      fontFamily: 'ui-monospace, Menlo, Consolas, monospace',
      fontSize: '14px', lineHeight: '1.45', whiteSpace: 'pre',
      color: '#222', cursor: 'auto',
    });

    dlg.appendChild(controls); dlg.appendChild(pre);
    dlg.addEventListener('close', function(){ dlg.remove(); });
    dlg.addEventListener('click', function(e){ if(e.target === dlg) dlg.close(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  return { show: show };
})();
