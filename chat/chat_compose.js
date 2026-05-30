/* Chat compose — the form behavior on the conversation page: the
   textarea + send button, image upload (button + clipboard paste), the
   resilient-send state machine (cid → optimistic disable → ack-on-echo
   / hostDown-on-timeout), and the inline alert modal for "host down"
   warnings.

   Boundary:
     CONSUMERS
       - chat.js: hands the incoming SSE message's `cid` to
         ackIfPending(); calls isPending() to gate quote/refer/edit (a
         pending send shouldn't be disturbed); calls insertAtCursor() to
         drop "See MSG_…" / "In MSG_…" snippets; calls setBody() to
         load a message back into compose for edit.
       - chat_help.js: no direct calls — keyboard shortcuts for compose
         (Ctrl/⌘-Enter to send, Esc to close when empty) live on the
         textarea itself and are wired here, not in the global keydown
         dispatcher.
     PRODUCERS (server-mutating)
       - send:    POST /chat/c/<conv>/<sid>/send  body=body=<text>&cid=<uuid>
                  the SSE echo of this message with matching cid is what
                  acks the send (see chat.js's stream handler);
                  hostDown fires after a 3s timeout if no ack arrives.
       - upload:  POST /chat/c/<conv>/<sid>/upload  multipart
                  on success, inserts an <img> tag (with dims) at the
                  caret so the user can post it with their message.
     DEPENDS ON
       - SESSION_BASE for the POST URLs.
       - chat_right_sidebar's closeCompose for the Esc-empty handler
         (passed in at init, sibling-to-sibling, not circular).
     OWNS
       - pendingCid + pendingTimer + setComposeEnabled — the send state
         machine. NOT exposed outside this module; chat.js calls
         ackIfPending() and lets compose decide.

   Loaded as a sibling of chat.js (BEFORE chat.js). */
window.ChatCompose = (function(){
  'use strict';

  var textarea, form, status, imageBtn, fileInput;
  var SESSION_BASE, closeCompose;
  var pendingCid=null, pendingTimer=null;
  /* MAX_IMAGE_BYTES must match Gopher's maxChatUploadBytes (and stay
     under Caddy's upload body cap). */
  var MAX_IMAGE_BYTES=10*1024*1024;

  function newCid(){ return (window.crypto&&crypto.randomUUID)?crypto.randomUUID():Date.now()+'-'+Math.random().toString(16).slice(2); }
  function setComposeEnabled(on){
    textarea.disabled=!on;
    var btns=form.querySelectorAll('button'); for(var i=0;i<btns.length;i++) btns[i].disabled=!on;
  }
  function ackSend(){ /* echo arrived: clear the box and re-enable */
    if(pendingTimer){ clearTimeout(pendingTimer); pendingTimer=null; }
    pendingCid=null; textarea.value=''; status.textContent=''; status.style.color='';
    setComposeEnabled(true); textarea.focus();
  }
  function hostDown(){ /* no echo / POST failed: keep the text, re-enable, tell the user */
    if(!pendingCid) return; /* already resolved (echo beat us) */
    if(pendingTimer){ clearTimeout(pendingTimer); pendingTimer=null; }
    pendingCid=null; status.textContent=''; status.style.color='';
    setComposeEnabled(true);
    showAlert('The host may be down. Please retry your send.', function(){ textarea.focus(); });
  }
  function showAlert(msg, onClose){
    var dlg=document.createElement('dialog'); dlg.className='chat-alert-dialog';
    var p=document.createElement('p'); p.textContent=msg;
    var ok=document.createElement('button'); ok.type='button'; ok.textContent='OK';
    ok.addEventListener('click',function(){ dlg.close(); });
    dlg.appendChild(p); dlg.appendChild(ok);
    dlg.addEventListener('close',function(){ dlg.remove(); if(onClose) onClose(); }); /* focus lands after the modal releases it */
    document.body.appendChild(dlg); dlg.showModal();
  }
  function send(){
    if(pendingCid) return; /* already awaiting an ack */
    var text=textarea.value;
    if(!text.trim()) return;
    var cid=newCid(); pendingCid=cid;
    setComposeEnabled(false); /* keep the text until the host acks */
    status.style.color='#888'; status.textContent='Sending…';
    pendingTimer=setTimeout(hostDown, 3000);
    fetch(SESSION_BASE+'/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'body='+encodeURIComponent(text)+'&cid='+encodeURIComponent(cid)
    }).then(function(r){ if(!r.ok) throw new Error('status '+r.status); /* success is confirmed by the SSE echo */ })
      .catch(hostDown);
  }
  function insertAtCursor(text){
    var s=textarea.selectionStart, e=textarea.selectionEnd, v=textarea.value;
    textarea.value=v.slice(0,s)+text+v.slice(e);
    textarea.selectionStart=textarea.selectionEnd=s+text.length; textarea.focus();
  }
  function setBody(text, caretAt){
    textarea.value=text;
    if(typeof caretAt==='number') textarea.setSelectionRange(caretAt, caretAt);
  }
  /* Reject oversized images up front (the per-image limit), and otherwise
     surface the server's own message — e.g. the lifetime upload cap. */
  function uploadImage(file){
    if(!file) return;
    if(file.size > MAX_IMAGE_BYTES){
      status.style.color='';
      status.textContent='That image is '+(file.size/1048576).toFixed(1)+' MB — too big to send (limit 10 MB). Try compressing or resizing it.';
      return;
    }
    status.style.color='#888'; status.textContent='Uploading image…';
    var fd=new FormData(); fd.append('file',file);
    fetch(SESSION_BASE+'/upload',{method:'POST',body:fd})
      .then(function(r){
        if(r.ok) return r.json();
        return r.text().then(function(t){
          t=(t||'').trim();
          throw (t && t.charAt(0)!=='<' && t.length<200) ? t : 'Image upload failed.';
        });
      })
      .then(function(d){
        /* HTML <img> instead of markdown image syntax so the width/height
           the server decoded ride along with the message body. Modern
           browsers use those attrs to reserve correctly-proportioned space
           before the image decodes, so the feed doesn't reflow when
           "scroll to bottom" lands. Server may return 0 for unknown dims
           (e.g. webp without a stdlib decoder); in that case we omit the
           attrs and fall back to the old no-dims behavior. */
        var alt=(d.name||'image').replace(/["<>\r\n]/g,'');
        var dims=(d.width>0 && d.height>0) ? ' width="'+d.width+'" height="'+d.height+'"' : '';
        insertAtCursor('<img src="'+d.url+'" alt="'+alt+'"'+dims+'>');
        status.textContent=''; status.style.color='';
      })
      .catch(function(msg){
        status.style.color='';
        status.textContent = (typeof msg==='string' && msg) ? msg : 'Image upload failed.';
      });
  }

  function init(deps){
    textarea=deps.textarea; form=deps.form; status=deps.status;
    imageBtn=deps.imageBtn; fileInput=deps.fileInput;
    SESSION_BASE=deps.sessionBase; closeCompose=deps.closeCompose;

    form.addEventListener('submit', function(e){ e.preventDefault(); send(); });
    textarea.addEventListener('keydown', function(e){
      if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){ e.preventDefault(); send(); return; }
      if(e.key==='Escape'&&textarea.value.trim()===''){ e.preventDefault(); closeCompose(); } /* empty only — never lose a draft */
    });
    imageBtn.addEventListener('click', function(){ fileInput.click(); });
    fileInput.addEventListener('change', function(){ uploadImage(fileInput.files[0]); fileInput.value=''; });
    textarea.addEventListener('paste', function(e){
      var files=e.clipboardData&&e.clipboardData.files;
      if(files) for(var i=0;i<files.length;i++){
        if(files[i].type.indexOf('image/')===0){ e.preventDefault(); uploadImage(files[i]); return; }
      }
    });
  }
  function isPending(){ return !!pendingCid; }
  function ackIfPending(cid){ if(pendingCid && cid===pendingCid) ackSend(); }

  return { init:init, isPending:isPending, ackIfPending:ackIfPending,
           insertAtCursor:insertAtCursor, setBody:setBody };
})();
