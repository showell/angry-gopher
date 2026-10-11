/* PRODUCT_DECISION: compose owns the send state machine — cid round-trip,
   optimistic disable, ack on SSE echo, hostDown timeout. Image upload (button
   + clipboard paste) lives here too. Also owns its entire DOM (form,
   textarea, Send/Image buttons, status line, markdown hint) and its CSS
   (form/textarea sizing, action-row layout, status/hint colors, and the
   host-down alert dialog). */
window.ChatCompose = (function(){
  'use strict';

  var textarea, form, status, uploadBtn, fileInput;
  var SESSION_BASE, closeCompose;
  var pendingCid=null, pendingTimer=null;
  /* PRODUCT_DECISION: the server's per-kind caps and accepted types, handed
     over by init from the page (metal-vmm QUEUE 157(d)): the server's own,
     where this file kept copies that "must match". */
  var MAX_IMAGE_BYTES, MAX_VIDEO_BYTES, UPLOAD_ACCEPT;

  /* PRODUCT_DECISION: widget owns its own CSS. Selectors are scoped to
     .chat-compose (the right-rail wrapper class set by ChatRightSidebar).
     The compose-body + form + textarea flex rules used to live in the
     server's landscape @media; with mobile/portrait support dropped they
     are always-on and belong here next to the elements they style. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-compose-body { display:flex; flex-direction:column; flex:1; min-height:0; }'
      + '.chat-compose form { margin:0; display:flex; flex-direction:column;'
      +                    ' flex:1; min-height:0; }'
      + '.chat-compose textarea { width:100%; flex:1; min-height:0; resize:vertical;'
      +                        ' box-sizing:border-box; font-family:inherit;'
      +                        ' font-size:14px; padding:8px;'
      +                        ' background:var(--cc-card-bg); color:var(--cc-fg);'
      +                        ' border:1px solid var(--cc-input-border); }'
      + '.chat-compose button { margin-top:8px; }'
      + '.chat-compose-actions { display:flex; gap:8px; margin-top:8px; }'
      + '.chat-compose-actions button { margin-top:0; }'
      + '.chat-status { font-size:12px; color:var(--cc-error); min-height:16px; margin-top:6px; }'
      + '.chat-hint { font-size:12px; color:var(--cc-soft-muted-fg); margin-top:8px; }'
      /* Plain "host may be down" alert — only ChatCompose builds these. */
      + '.chat-alert-dialog { max-width:90vw; border:1px solid var(--cc-dialog-border);'
      +                    ' background:var(--cc-bg); color:var(--cc-fg);'
      +                    ' border-radius:8px; padding:18px 20px; }'
      + '.chat-alert-dialog::backdrop { background:var(--cc-backdrop); }'
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
    status.style.color=ChatColors.mutedFg; status.textContent='Sending…';
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
  /* PRODUCT_DECISION: one upload path for images AND screencasts. The per-kind
     size limit is checked up front; the server's "kind" in the response decides
     whether we insert an <img> or a <video>. Other failures (e.g. the shared
     lifetime cap) surface the server's own message.
     PRODUCT_DECISION: an upload is PATIENT and VISIBLE. A slow link (a 1.8 MB
     photo from India took 27 s, 2026-10-11) shows its progress, by percent and
     megabytes, and then "Saving"; one upload at a time, the Upload button off
     while it runs; it gives up only after `upload_patience_ms`. XMLHttpRequest,
     not fetch: fetch cannot report how much of a body has gone. */
  var upload_patience_ms=5*60*1000;
  var uploading=false;
  function megabytes(n){ return (n/1048576).toFixed(1)+' MB'; }
  function uploadFile(file){
    if(!file) return;
    if(uploading){
      status.style.color=''; status.textContent='Still sending the last upload — one at a time, please.';
      return;
    }
    var isVideo=file.type.indexOf('video/')===0;
    var noun=isVideo?'screencast':'image';
    var cap=isVideo?MAX_VIDEO_BYTES:MAX_IMAGE_BYTES;
    if(file.size > cap){
      status.style.color='';
      status.textContent='That '+noun+' is '+megabytes(file.size)+' — too big to send (limit '+(cap/1048576)+' MB).'+(isVideo?'':' Try compressing or resizing it.');
      return;
    }
    uploading=true; uploadBtn.disabled=true;
    status.style.color=ChatColors.mutedFg;
    status.textContent='Uploading '+noun+': 0% of '+megabytes(file.size)+'…';
    var fd=new FormData(); fd.append('file',file);
    var xhr=new XMLHttpRequest();
    xhr.open('POST', SESSION_BASE+'/upload');
    xhr.timeout=upload_patience_ms;
    xhr.upload.onprogress=function(e){
      if(!e.lengthComputable) return;
      var pct=Math.floor(100*e.loaded/e.total);
      status.textContent = pct<100
        ? 'Uploading '+noun+': '+pct+'% of '+megabytes(e.total)+'…'
        : 'Saving '+noun+'…';
    };
    function done(msg){
      uploading=false; uploadBtn.disabled=false;
      status.style.color=''; status.textContent=msg;
    }
    xhr.onload=function(){
      if(xhr.status<200 || xhr.status>=300){
        var t=(xhr.responseText||'').trim();
        return done((t && t.charAt(0)!=='<' && t.length<200) ? t : 'Upload failed.');
      }
      var d;
      try { d=JSON.parse(xhr.responseText); } catch(e){ done('Upload failed: the answer did not read ('+e.message+').'); return; }
      if(d.kind==='video'){
        insertAtCursor('<video src="'+d.url+'"></video>');
      } else {
        /* BROWSER_WORKAROUND: HTML <img> with width/height so browsers reserve
           layout space before decode — keeps "scroll to bottom" stable when
           the image lands. Server may return 0 for unknown dims (e.g. webp
           without stdlib decoder); we omit the attrs in that case. */
        var alt=(d.name||'image').replace(/["<>\r\n]/g,'');
        var dims=(d.width>0 && d.height>0) ? ' width="'+d.width+'" height="'+d.height+'"' : '';
        insertAtCursor('<img src="'+d.url+'" alt="'+alt+'"'+dims+'>');
      }
      done('');
    };
    xhr.onerror=function(){ done('Upload failed: the connection dropped. Please try again.'); };
    xhr.ontimeout=function(){ done('Upload gave up after '+(upload_patience_ms/60000)+' minutes. Please try again.'); };
    xhr.send(fd);
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
    var upBtn = document.createElement('button'); upBtn.type = 'button'; upBtn.id = 'chat-upload-btn'; upBtn.textContent = 'Upload';
    actions.appendChild(sendBtn); actions.appendChild(upBtn);
    form.appendChild(actions);
    body.appendChild(form);

    var file = document.createElement('input');
    file.type = 'file'; file.id = 'chat-file';
    file.accept = UPLOAD_ACCEPT;
    file.style.display = 'none';
    body.appendChild(file);

    var statusEl = document.createElement('div'); statusEl.id = 'chat-status'; statusEl.className = 'chat-status';
    body.appendChild(statusEl);

    var hint = document.createElement('div'); hint.className = 'chat-hint';
    hint.textContent = 'Markdown supported · :emoji: autocompletes · attach an image or screencast · Ctrl/⌘-Enter to send';
    body.appendChild(hint);

    return { body:body, form:form, textarea:ta, uploadBtn:upBtn, fileInput:file, status:statusEl };
  }

  /* Takes the right rail ChatRightSidebar.init returned (deps.rail), and
     returns its body, which ChatResponsive.init takes (157(e)). */
  function init(deps){
    var rail=deps.rail;
    if(!rail || !rail.wrapper) throw new Error('ChatCompose.init: no rail (ChatRightSidebar.init returns it)');
    var u=deps.uploads;
    if(!u || !(u.imageMax>0) || !(u.videoMax>0) || !u.accept) throw new Error('ChatCompose.init: the page gave no upload limits');
    MAX_IMAGE_BYTES=u.imageMax; MAX_VIDEO_BYTES=u.videoMax; UPLOAD_ACCEPT=u.accept;
    ensureStyles();
    var built = buildComposeBody();
    textarea = built.textarea; form = built.form; status = built.status;
    uploadBtn = built.uploadBtn; fileInput = built.fileInput;
    SESSION_BASE = deps.sessionBase; closeCompose = deps.closeCompose;

    /* PRODUCT_DECISION: insert before the closed-panel so the open state
       shows above the keyhelp side. ChatRightSidebar built both the
       wrapper and the closed-panel; we ride on top with our compose body.
       The refs are the rail's (no global DOM queries), so this widget works
       whether or not the rail is attached to the page at init time. */
    rail.wrapper.insertBefore(built.body, rail.closedPanel);
    rail.registerComposeBody(built.body);

    form.addEventListener('submit', function(e){ e.preventDefault(); send(); });
    textarea.addEventListener('keydown', function(e){
      if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){ e.preventDefault(); send(); return; }
      if(e.key==='Escape'&&textarea.value.trim()===''){ e.preventDefault(); closeCompose(); } /* PRODUCT_DECISION: Esc closes only when empty — never lose a draft. */
    });
    ChatEmoji.attach(textarea); /* the :name: autocomplete; the whitelist lives in ChatEmoji */
    uploadBtn.addEventListener('click', function(){ fileInput.click(); });
    fileInput.addEventListener('change', function(){ uploadFile(fileInput.files[0]); fileInput.value=''; });
    textarea.addEventListener('paste', function(e){
      var files=e.clipboardData&&e.clipboardData.files;
      if(files) for(var i=0;i<files.length;i++){
        var t=files[i].type;
        if(t.indexOf('image/')===0 || t.indexOf('video/')===0){ e.preventDefault(); uploadFile(files[i]); return; }
      }
    });
    return { body: built.body };
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
