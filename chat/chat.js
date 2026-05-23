(function(){
  var root=document.getElementById('chat-root');
  var PARTNER=root.dataset.partner;
  var history=document.getElementById('chat-history');
  var bubbles=document.getElementById('chat-bubbles');
  var transcript=document.getElementById('chat-transcript');
  var views=document.getElementById('chat-views');
  var form=document.getElementById('chat-form');
  var textarea=document.getElementById('chat-body');
  var status=document.getElementById('chat-status');
  var imageBtn=document.getElementById('chat-image-btn');
  var fileInput=document.getElementById('chat-file');
  var lockBtn=document.getElementById('chat-lock');
  var backBtn=document.getElementById('chat-back');
  var locked=false;
  function toBottom(){ history.scrollTop=history.scrollHeight; }
  function addMessage(m){
    var empty=document.getElementById('chat-empty'); if(empty) empty.remove();
    var div=document.createElement('div');
    div.className='chat-msg '+(m.mine?'mine':'theirs');
    div.id='msg-'+m.hash; div.setAttribute('data-i',m.index); div.setAttribute('data-hash',m.hash);
    var meta=document.createElement('div'); meta.className='chat-meta';
    meta.appendChild(document.createTextNode(m.from+' · '+m.time+' '));
    var refer=document.createElement('button'); refer.type='button'; refer.className='msg-refer';
    refer.title='Reference this message'; refer.textContent='refer'; meta.appendChild(refer);
    var body=document.createElement('div'); body.className='chat-body';
    body.innerHTML=m.html; /* sanitized server-side */
    div.appendChild(meta); div.appendChild(body);
    bubbles.appendChild(div);
    var span=document.createElement('span'); span.setAttribute('data-i',m.index);
    span.textContent=m.enc; transcript.appendChild(span); /* literal on-disk block */
  }
  /* Anchor scrolling on the same MESSAGE across view switches: find the
     topmost visible [data-i] element, then bring that same index back to
     the top after the layout changes (rendered/raw/transcript differ). */
  function topIndex(){
    var els=history.querySelectorAll('[data-i]'), htop=history.getBoundingClientRect().top;
    for(var i=0;i<els.length;i++){
      if(els[i].offsetParent===null) continue;
      if(els[i].getBoundingClientRect().bottom>htop+1) return els[i].getAttribute('data-i');
    }
    return null;
  }
  function scrollToIndex(idx){
    if(idx===null) return;
    var els=history.querySelectorAll('[data-i="'+idx+'"]');
    for(var i=0;i<els.length;i++){
      if(els[i].offsetParent===null) continue;
      history.scrollTop+=els[i].getBoundingClientRect().top-history.getBoundingClientRect().top;
      return;
    }
  }
  function setView(v){
    var idx=topIndex();
    history.className='chat-history view-'+v;
    var links=views.querySelectorAll('a');
    for(var i=0;i<links.length;i++){ links[i].className=(links[i].getAttribute('data-view')===v)?'active':''; }
    scrollToIndex(idx);
  }
  views.addEventListener('click',function(e){
    var a=e.target.closest('a[data-view]'); if(!a) return;
    e.preventDefault(); setView(a.getAttribute('data-view'));
  });
  lockBtn.addEventListener('click',function(){
    locked=!locked;
    lockBtn.textContent=locked?'🔒 Locked':'🔓 Unlocked';
    lockBtn.setAttribute('aria-pressed',locked?'true':'false');
    lockBtn.classList.toggle('locked',locked);
    if(!locked) toBottom(); /* unlocking catches up to the latest */
  });
  toBottom();
  /* Always replay the full backlog (since=0); reconnects resume from
     Last-Event-ID automatically. The client builds the whole feed. */
  var es=new EventSource('/chat/stream?with='+encodeURIComponent(PARTNER)+'&since=0');
  es.onmessage=function(e){ addMessage(JSON.parse(e.data)); if(!locked) toBottom(); };
  function send(){
    var text=textarea.value;
    if(!text.trim()) return;
    textarea.value=''; status.textContent='';
    fetch('/chat/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'with='+encodeURIComponent(PARTNER)+'&body='+encodeURIComponent(text)
    }).then(function(r){ if(!r.ok) throw new Error('status '+r.status); textarea.focus(); })
      .catch(function(){ textarea.value=text; status.textContent='Failed to send — your text is preserved.'; });
  }
  form.addEventListener('submit',function(e){ e.preventDefault(); send(); });
  textarea.addEventListener('keydown',function(e){
    if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){ e.preventDefault(); send(); }
  });
  /* --- image upload (button + clipboard paste) --- */
  function insertAtCursor(text){
    var s=textarea.selectionStart, e=textarea.selectionEnd, v=textarea.value;
    textarea.value=v.slice(0,s)+text+v.slice(e);
    textarea.selectionStart=textarea.selectionEnd=s+text.length; textarea.focus();
  }
  /* Reject oversized images up front with a clear message — the server is
     fronted by a 1 MB body cap, so a big upload otherwise fails opaquely.
     Keep MAX_IMAGE_BYTES in sync with Caddy's request_body max_size. */
  var MAX_IMAGE_BYTES = 1000000;
  function uploadImage(file){
    if(!file) return;
    if(file.size > MAX_IMAGE_BYTES){
      status.style.color='';
      status.textContent='That image is '+(file.size/1048576).toFixed(1)+' MB — too big to send (limit 1 MB). Try compressing or resizing it.';
      return;
    }
    status.style.color='#888'; status.textContent='Uploading image…';
    var fd=new FormData(); fd.append('file',file);
    fetch('/chat/upload?with='+encodeURIComponent(PARTNER),{method:'POST',body:fd})
      .then(function(r){
        if(r.status===413||r.status===403) throw 'toobig';
        if(!r.ok) throw 'failed';
        return r.json();
      })
      .then(function(d){
        var alt=(d.name||'image').replace(/[\[\]\r\n]/g,'');
        insertAtCursor('!['+alt+']('+d.url+')');
        status.textContent=''; status.style.color='';
      })
      .catch(function(e){
        status.style.color='';
        status.textContent = (e==='toobig')
          ? 'That image is too big to send (limit 1 MB). Try compressing or resizing it.'
          : 'Image upload failed.';
      });
  }
  imageBtn.addEventListener('click',function(){ fileInput.click(); });
  fileInput.addEventListener('change',function(){ uploadImage(fileInput.files[0]); fileInput.value=''; });
  textarea.addEventListener('paste',function(e){
    var files=e.clipboardData&&e.clipboardData.files;
    if(files) for(var i=0;i<files.length;i++){
      if(files[i].type.indexOf('image/')===0){ e.preventDefault(); uploadImage(files[i]); return; }
    }
  });
  /* --- click any image to zoom (range slider scales height; scroll to pan) --- */
  function showImagePopup(src){
    var dlg=document.createElement('dialog'); dlg.className='chat-img-dialog';
    var controls=document.createElement('div'); controls.className='chat-img-controls';
    var range=document.createElement('input'); range.type='range';
    range.min='1'; range.max='8'; range.step='0.05'; range.value='1';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click',function(){ dlg.close(); });
    controls.appendChild(range); controls.appendChild(close);
    var scroll=document.createElement('div'); scroll.className='chat-img-scroll';
    var img=document.createElement('img'); img.alt='';
    scroll.appendChild(img);
    dlg.appendChild(controls); dlg.appendChild(scroll);
    dlg.addEventListener('close',function(){ dlg.remove(); });
    document.body.appendChild(dlg);
    /* fitW/fitH = largest size that fits the fixed container (computed once
       the image's natural size + the container size are known); the slider
       then multiplies that, overflowing into scroll when >1. */
    var fitW=0, fitH=0;
    function applyZoom(){ if(!fitW) return; var z=parseFloat(range.value); img.style.width=(fitW*z)+'px'; img.style.height=(fitH*z)+'px'; }
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
  function flashMsg(el){ el.classList.remove('msg-flash'); void el.offsetWidth; el.classList.add('msg-flash'); }
  /* Back-nav stack: jumping to a MSG_ link remembers the message you
     clicked FROM; the ← button scrolls back to it (and flashes it), one
     step per chained jump. */
  var navStack=[];
  function updateBack(){ backBtn.disabled = navStack.length===0; }
  function scrollIndexToTop(idx){
    if(idx===null||idx===undefined) return null;
    var el=bubbles.querySelector('.chat-msg[data-i="'+idx+'"]');
    if(!el||el.offsetParent===null) return null;
    el.scrollIntoView({block:'start',behavior:'smooth'});
    return el;
  }
  backBtn.addEventListener('click',function(){
    if(!navStack.length) return;
    var el=scrollIndexToTop(navStack.pop()); updateBack();
    if(el) flashMsg(el); /* highlight the message we returned to */
  });
  updateBack();
  bubbles.addEventListener('click',function(e){
    var t=e.target;
    var rb=t.closest&&t.closest('.msg-refer');
    if(rb){ var mm=rb.closest('.chat-msg'); if(mm) insertAtCursor('MSG_'+mm.getAttribute('data-hash')+' '); return; }
    var a=t.closest&&t.closest('a.msg-ref');
    if(a){ e.preventDefault();
      var src=a.closest('.chat-msg'); /* the message we're clicking from */
      var tgt=document.getElementById(a.getAttribute('href').slice(1));
      if(tgt){ if(src) navStack.push(src.getAttribute('data-i')); updateBack();
        tgt.scrollIntoView({block:'center',behavior:'smooth'}); flashMsg(tgt); }
      return; }
    if(t&&t.tagName==='IMG'&&t.closest('.chat-body')) showImagePopup(t.src);
  });
  textarea.focus();
})();
