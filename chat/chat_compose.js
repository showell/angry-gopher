/* PRODUCT_DECISION: compose owns the send state machine — cid round-trip,
   optimistic disable, ack on SSE echo, hostDown timeout. Image upload (button
   + clipboard paste) lives here too. */
window.ChatCompose = (function(){
  'use strict';

  var textarea, form, status, imageBtn, fileInput;
  var SESSION_BASE, closeCompose;
  var pendingCid=null, pendingTimer=null;
  /* PRODUCT_DECISION: must match Gopher's maxChatUploadBytes and stay under Caddy's body cap. */
  var MAX_IMAGE_BYTES=10*1024*1024;

  function newCid(){ return (window.crypto&&crypto.randomUUID)?crypto.randomUUID():Date.now()+'-'+Math.random().toString(16).slice(2); }
  function setComposeEnabled(on){
    textarea.disabled=!on;
    var btns=form.querySelectorAll('button'); for(var i=0;i<btns.length;i++) btns[i].disabled=!on;
  }
  /* PRODUCT_DECISION: SSE echo arrived — clear the box and re-enable. */
  function ackSend(){
    if(pendingTimer){ clearTimeout(pendingTimer); pendingTimer=null; }
    pendingCid=null; textarea.value=''; status.textContent=''; status.style.color='';
    setComposeEnabled(true); textarea.focus();
  }
  /* PRODUCT_DECISION: no echo / POST failed — keep the text, re-enable, alert the user. */
  function hostDown(){
    if(!pendingCid) return; /* PRODUCT_DECISION: already resolved — echo beat us to the timer. */
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
    dlg.addEventListener('close',function(){ dlg.remove(); if(onClose) onClose(); }); /* PRODUCT_DECISION: focus lands after the modal releases it. */
    document.body.appendChild(dlg); dlg.showModal();
  }
  function send(){
    if(pendingCid) return;
    var text=textarea.value;
    if(!text.trim()) return;
    var cid=newCid(); pendingCid=cid;
    setComposeEnabled(false); /* PRODUCT_DECISION: keep the text disabled until the host acks. */
    status.style.color='#888'; status.textContent='Sending…';
    pendingTimer=setTimeout(hostDown, 3000);
    fetch(SESSION_BASE+'/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'body='+encodeURIComponent(text)+'&cid='+encodeURIComponent(cid)
    }).then(function(r){ if(!r.ok) throw new Error('status '+r.status); /* PRODUCT_DECISION: real confirmation is the SSE echo. */ })
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
  /* PRODUCT_DECISION: reject oversized images up front (per-image limit);
     otherwise surface the server's own message (e.g. lifetime upload cap). */
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
        /* BROWSER_WORKAROUND: HTML <img> with width/height so browsers reserve
           layout space before decode — keeps "scroll to bottom" stable when
           the image lands. Server may return 0 for unknown dims (e.g. webp
           without stdlib decoder); we omit the attrs in that case. */
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
      if(e.key==='Escape'&&textarea.value.trim()===''){ e.preventDefault(); closeCompose(); } /* PRODUCT_DECISION: Esc closes only when empty — never lose a draft. */
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
