/* PRODUCT_DECISION: compose owns the send state machine — cid round-trip,
   optimistic disable, ack on SSE echo, hostDown timeout. Image upload (button
   + clipboard paste) lives here too. Also owns its entire DOM (form,
   textarea, Send/Image buttons, status line, markdown hint) and its CSS
   (form/textarea sizing, action-row layout, status/hint colors, and the
   host-down alert dialog). */
window.ChatCompose = (function(){
  'use strict';

  var textarea, form, status, imageBtn, fileInput;
  var SESSION_BASE, closeCompose;
  var pendingCid=null, pendingTimer=null;
  /* PRODUCT_DECISION: must match Gopher's maxChatUploadBytes and stay under Caddy's body cap. */
  var MAX_IMAGE_BYTES=10*1024*1024;

  /* PRODUCT_DECISION: widget owns its own CSS. Selectors are scoped to
     .chat-compose (the right-rail wrapper class set by ChatRightSidebar)
     so the page-level orientation @media queries in chat.go that reach
     in for landscape sizing keep matching the same elements. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-compose form { margin:0; }'
      + '.chat-compose textarea { width:100%; min-height:200px; resize:vertical;'
      +                        ' box-sizing:border-box; font-family:inherit;'
      +                        ' font-size:14px; padding:8px; }'
      + '.chat-compose button { margin-top:8px; }'
      + '.chat-compose-actions { display:flex; gap:8px; margin-top:8px; }'
      + '.chat-compose-actions button { margin-top:0; }'
      + '.chat-status { font-size:12px; color:#b00020; min-height:16px; margin-top:6px; }'
      + '.chat-hint { font-size:12px; color:#999; margin-top:8px; }'
      /* Plain "host may be down" alert — only ChatCompose builds these. */
      + '.chat-alert-dialog { max-width:90vw; border:1px solid #bbb;'
      +                    ' border-radius:8px; padding:18px 20px; }'
      + '.chat-alert-dialog::backdrop { background:rgba(0,0,0,0.4); }'
      + '.chat-alert-dialog p { margin:0 0 14px; }'
      + '.chat-alert-dialog button { padding:5px 16px; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  function setComposeEnabled(on){
    textarea.disabled=!on;
    var btns=form.querySelectorAll('button'); for(var i=0;i<btns.length;i++) btns[i].disabled=!on;
  }
  /* PRODUCT_DECISION: no echo / POST failed — keep the text, re-enable, alert the user. */
  function hostDown(){
    if(!pendingCid) return; /* PRODUCT_DECISION: already resolved — echo beat us to the timer. */
    if(pendingTimer){ clearTimeout(pendingTimer); pendingTimer=null; }
    pendingCid=null; status.textContent=''; status.style.color='';
    setComposeEnabled(true);
    showAlert('The host may be down. Please retry your send.', function(){ textarea.focus(); });
  }
  // lint:called-once popup-builder-abstraction
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
    var cid=(window.crypto&&crypto.randomUUID)?crypto.randomUUID():Date.now()+'-'+Math.random().toString(16).slice(2);
    pendingCid=cid;
    setComposeEnabled(false); /* PRODUCT_DECISION: keep the text disabled until the host acks. */
    status.style.color='#888'; status.textContent='Sending…';
    pendingTimer=setTimeout(hostDown, 3000);
    fetch(SESSION_BASE+'/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'markdown='+encodeURIComponent(text)+'&cid='+encodeURIComponent(cid)
    }).then(function(r){ if(!r.ok) throw new Error('status '+r.status); /* PRODUCT_DECISION: real confirmation is the SSE echo. */ })
      .catch(hostDown);
  }
  function insertAtCursor(text){
    var s=textarea.selectionStart, e=textarea.selectionEnd, v=textarea.value;
    textarea.value=v.slice(0,s)+text+v.slice(e);
    textarea.selectionStart=textarea.selectionEnd=s+text.length; textarea.focus();
  }
  function setMarkdown(text, caretAt){
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

  function focus(){ textarea.focus(); }

  /* PRODUCT_DECISION: compose owns its DOM — Go ships only the right-sidebar
     wrapper; the compose-body markup (form, textarea, send/image buttons,
     file input, status line, markdown hint) gets built here at init time
     and inserted before the closed-panel inside #chat-right-sidebar. */
  // lint:called-once dom-scaffold-abstraction
  function buildComposeBody(){
    var body = document.createElement('div');
    body.id = 'chat-compose-body'; body.className = 'chat-compose-body';
    body.style.display = 'none';

    var form = document.createElement('form'); form.id = 'chat-form';
    var ta = document.createElement('textarea'); ta.id = 'chat-body';
    ta.placeholder = 'Write a message…  Markdown is supported, and longer posts are welcome.';
    form.appendChild(ta);

    var actions = document.createElement('div'); actions.className = 'chat-compose-actions';
    var sendBtn = document.createElement('button'); sendBtn.type = 'submit'; sendBtn.textContent = 'Send';
    var imgBtn = document.createElement('button'); imgBtn.type = 'button'; imgBtn.id = 'chat-image-btn'; imgBtn.textContent = 'Image';
    actions.appendChild(sendBtn); actions.appendChild(imgBtn);
    form.appendChild(actions);
    body.appendChild(form);

    var file = document.createElement('input');
    file.type = 'file'; file.id = 'chat-file';
    file.accept = 'image/png,image/jpeg,image/gif,image/webp';
    file.style.display = 'none';
    body.appendChild(file);

    var statusEl = document.createElement('div'); statusEl.id = 'chat-status'; statusEl.className = 'chat-status';
    body.appendChild(statusEl);

    var hint = document.createElement('div'); hint.className = 'chat-hint';
    hint.textContent = 'Markdown supported · paste or attach an image · Ctrl/⌘-Enter to send';
    body.appendChild(hint);

    return { body:body, form:form, textarea:ta, imageBtn:imgBtn, fileInput:file, status:statusEl };
  }

  function init(deps){
    ensureStyles();
    var built = buildComposeBody();
    textarea = built.textarea; form = built.form; status = built.status;
    imageBtn = built.imageBtn; fileInput = built.fileInput;
    SESSION_BASE = deps.sessionBase; closeCompose = deps.closeCompose;

    /* PRODUCT_DECISION: insert before the closed-panel so the open state
       shows above the keyhelp side. ChatRightSidebar built both the
       wrapper and the closed-panel; we ride on top with our compose body. */
    var rightSidebar = document.getElementById('chat-right-sidebar');
    var closedPanel = document.getElementById('chat-closed-panel');
    rightSidebar.insertBefore(built.body, closedPanel);
    ChatRightSidebar.registerComposeBody(built.body);

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
  /* PRODUCT_DECISION: SSE echo arrived for our pending cid — clear the box and re-enable. */
  function ackIfPending(cid){
    if(!(pendingCid && cid===pendingCid)) return;
    if(pendingTimer){ clearTimeout(pendingTimer); pendingTimer=null; }
    pendingCid=null; textarea.value=''; status.textContent=''; status.style.color='';
    setComposeEnabled(true); textarea.focus();
  }

  return { init:init, isPending:isPending, ackIfPending:ackIfPending,
           insertAtCursor:insertAtCursor, setMarkdown:setMarkdown, focus:focus };
})();
