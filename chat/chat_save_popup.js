/* Save popup — opened when you save a chat message to your reading list
   (the `save` button on a message, or the `s` hotkey). Pops a one-line
   annotation field pre-filled with "read later": hit Enter to accept it
   as-is (the cheap path), or edit then Enter. Esc / Cancel / backdrop
   click dismiss without saving.

   Exposed as `window.ChatSavePopup.show({ note, onConfirm })`:
     note      pre-fill for the annotation field (default "read later")
     onConfirm function(noteString) — called with the final annotation
               when the user commits; not called on cancel.

   Self-contained like the other popups: owns ALL its styling (Object.assign
   on .style plus one lazy ::backdrop <style> tag), no CSS from the server.
   No instance state — each call builds a fresh <dialog> and self-removes. */
window.ChatSavePopup = (function(){
  'use strict';

  /* ::backdrop is the one rule that can't live on element.style; injected
     once, class-scoped so it only matches this popup's dialogs. */
  var backdropStyleInjected = false;
  // lint:called-once init-once-guard
  function ensureBackdropStyle(){
    if(backdropStyleInjected) return;
    var s = document.createElement('style');
    s.textContent = 'dialog.chat-save-dialog::backdrop { background:var(--cc-backdrop); }';
    document.head.appendChild(s);
    backdropStyleInjected = true;
  }

  function show(opts){
    opts = opts || {};
    var onConfirm = opts.onConfirm || function(){};
    ensureBackdropStyle();

    var dlg = document.createElement('dialog');
    dlg.className = 'chat-save-dialog';
    Object.assign(dlg.style, {
      maxWidth: '90vw', width: '360px', padding: '0',
      border: '1px solid '+ChatColors.dialogBorder, borderRadius: '8px',
      background: ChatColors.bg, color: ChatColors.fg,
    });

    /* A <form> so Enter submits naturally and Esc cancels (native dialog). */
    var form = document.createElement('form');
    form.method = 'dialog';
    Object.assign(form.style, { margin: '0', padding: '14px 16px' });

    var title = document.createElement('div');
    title.textContent = 'Save to reading list';
    Object.assign(title.style, {
      fontSize: '13px', color: ChatColors.mutedFg, marginBottom: '8px',
    });
    form.appendChild(title);

    var input = document.createElement('input');
    input.type = 'text';
    input.value = (opts.note != null ? opts.note : 'read later');
    Object.assign(input.style, {
      width: '100%', boxSizing: 'border-box', padding: '7px 9px',
      fontSize: '14px', color: ChatColors.fg, background: ChatColors.bg,
      border: '1px solid '+ChatColors.inputBorder, borderRadius: '5px',
    });
    form.appendChild(input);

    var hint = document.createElement('div');
    hint.textContent = 'Enter to save · Esc to cancel';
    Object.assign(hint.style, {
      fontSize: '11px', color: ChatColors.softMutedFg, margin: '6px 2px 12px',
    });
    form.appendChild(hint);

    var row = document.createElement('div');
    Object.assign(row.style, { display: 'flex', justifyContent: 'flex-end', gap: '8px' });
    var cancel = document.createElement('button');
    cancel.type = 'button'; cancel.textContent = 'Cancel';
    Object.assign(cancel.style, {
      padding: '6px 12px', fontSize: '13px', cursor: 'pointer',
      color: ChatColors.mutedFg, background: 'none',
      border: '1px solid '+ChatColors.border, borderRadius: '5px',
    });
    cancel.addEventListener('click', function(){ dlg.close(); });
    var save = document.createElement('button');
    save.type = 'submit'; save.textContent = 'Save';
    Object.assign(save.style, {
      padding: '6px 14px', fontSize: '13px', cursor: 'pointer', fontWeight: '600',
      color: '#fff', background: ChatColors.accent,
      border: '1px solid '+ChatColors.accent, borderRadius: '5px',
    });
    row.appendChild(cancel); row.appendChild(save);
    form.appendChild(row);

    /* PRODUCT_DECISION: form-method=dialog means a submit closes the dialog
       with returnValue 'save'; we read that on close so Enter, the Save
       button, and a programmatic submit all funnel through one path. Cancel
       / Esc / backdrop close with an empty returnValue → no save. */
    var committed = false;
    form.addEventListener('submit', function(){ committed = true; });
    dlg.addEventListener('close', function(){
      var note = input.value;
      dlg.remove();
      if(committed) onConfirm(note);
    });
    dlg.addEventListener('click', function(e){ if(e.target === dlg) dlg.close(); });

    dlg.appendChild(form);
    document.body.appendChild(dlg);
    dlg.showModal();
    /* Pre-select so Enter accepts the default, or the first keystroke replaces it. */
    input.focus(); input.select();
  }

  return { show: show };
})();
