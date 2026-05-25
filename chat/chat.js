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
  var backBtn=document.getElementById('chat-back');
  function toBottom(){ history.scrollTop=history.scrollHeight; }
  /* "Caught up": the end of the last message in the feed is visible, so a new
     message should follow it down. If you've scrolled up into history, the
     last message's bottom is below the fold and we leave you where you are.
     (A last message taller than the viewport still counts as caught-up once
     you've scrolled to its bottom edge.) */
  function caughtUp(){
    var els=history.querySelectorAll('[data-i]');
    for(var i=els.length-1;i>=0;i--){
      if(els[i].offsetParent===null) continue; /* the hidden view (rendered vs transcript) */
      return els[i].getBoundingClientRect().bottom<=history.getBoundingClientRect().bottom+1;
    }
    return true; /* empty feed → stick, so the first messages land at the bottom */
  }
  /* Persistent "selected message" (Zulip-style cursor) + a navigation undo
     stack. At most one message is selected; it shows a steady highlight ring.
     The selection moves when you click a message / MSG_ link, and otherwise
     FOLLOWS scrolling: the topmost message fully in view, or — when one
     message is too tall for any to be fully visible — the topmost whose
     beginning (top edge) shows.

     navStack records the trail of *committed* selections so the ← button can
     walk back. A click/link jump commits immediately; a scroll-driven change
     commits only after a 700ms pause — so scrolling past messages to find one
     doesn't churn the stack, only the message you settle on is recorded. */
  var selected=null, suppressSyncUntil=0;
  function idxOf(el){ return el?el.getAttribute('data-i'):null; }
  function selectMsg(el){
    if(!el||el===selected) return;
    if(selected) selected.classList.remove('selected');
    selected=el; el.classList.add('selected');
  }
  var navStack=[], commitTimer=null;
  function canGoBack(){
    if(!navStack.length) return false;
    if(idxOf(selected)===navStack[navStack.length-1]) return navStack.length>=2;
    return true; /* selection has drifted away from the last stable one */
  }
  function updateBack(){ backBtn.disabled=!canGoBack(); }
  function pushCommit(idx){
    if(idx===null) return;
    if(navStack.length && navStack[navStack.length-1]===idx) return; /* no consecutive dup */
    navStack.push(idx); updateBack();
  }
  function commitSelection(idx, immediate){
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; }
    if(immediate) pushCommit(idx);
    else commitTimer=setTimeout(function(){ commitTimer=null; pushCommit(idx); }, 700);
  }
  /* Select + record on the nav stack: immediate=true for a click/link jump,
     false to debounce a scroll-driven change. */
  function selectAndCommit(el, immediate){ if(el){ selectMsg(el); commitSelection(idxOf(el), immediate); } }
  function selectionCandidate(){
    var els=bubbles.querySelectorAll('.chat-msg'), hr=history.getBoundingClientRect();
    var beginningVisible=null, straddler=null;
    for(var i=0;i<els.length;i++){
      var el=els[i]; if(el.offsetParent===null) continue;
      var r=el.getBoundingClientRect();
      if(r.top>=hr.top-1 && r.bottom<=hr.bottom+1) return el;                  /* topmost fully in view */
      if(!beginningVisible && r.top>=hr.top-1 && r.top<hr.bottom) beginningVisible=el; /* its top edge shows */
      if(!straddler && r.top<hr.top && r.bottom>hr.top) straddler=el;          /* covers the viewport top */
    }
    return beginningVisible||straddler||null;
  }
  /* A link/back jump suppresses scroll-driven reselection briefly so the
     smooth-scroll animation doesn't steal the selection back. */
  function syncSelectionToScroll(){
    if(Date.now()<suppressSyncUntil) return;
    var el=selectionCandidate();
    if(el && el!==selected){ selectAndCommit(el, false); updateBack(); } /* enables ← as you drift away */
  }
  var rafPending=false;
  history.addEventListener('scroll',function(){
    if(rafPending) return; rafPending=true;
    requestAnimationFrame(function(){ rafPending=false; syncSelectionToScroll(); });
  });
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
  toBottom();
  /* Always replay the full backlog (since=0); reconnects resume from
     Last-Event-ID automatically. The client builds the whole feed. */
  var es=new EventSource('/chat/stream?with='+encodeURIComponent(PARTNER)+'&since=0');
  es.onmessage=function(e){ var stick=caughtUp(); addMessage(JSON.parse(e.data)); if(stick) toBottom(); syncSelectionToScroll(); };
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
  /* Reject oversized images up front (the per-image limit), and otherwise
     surface the server's own message — e.g. the lifetime upload cap.
     MAX_IMAGE_BYTES must match Gopher's maxChatUploadBytes (and stay under
     Caddy's upload body cap). */
  var MAX_IMAGE_BYTES = 10*1024*1024;
  function uploadImage(file){
    if(!file) return;
    if(file.size > MAX_IMAGE_BYTES){
      status.style.color='';
      status.textContent='That image is '+(file.size/1048576).toFixed(1)+' MB — too big to send (limit 10 MB). Try compressing or resizing it.';
      return;
    }
    status.style.color='#888'; status.textContent='Uploading image…';
    var fd=new FormData(); fd.append('file',file);
    fetch('/chat/upload?with='+encodeURIComponent(PARTNER),{method:'POST',body:fd})
      .then(function(r){
        if(r.ok) return r.json();
        return r.text().then(function(t){
          t=(t||'').trim();
          throw (t && t.charAt(0)!=='<' && t.length<200) ? t : 'Image upload failed.';
        });
      })
      .then(function(d){
        var alt=(d.name||'image').replace(/[\[\]\r\n]/g,'');
        insertAtCursor('!['+alt+']('+d.url+')');
        status.textContent=''; status.style.color='';
      })
      .catch(function(msg){
        status.style.color='';
        status.textContent = (typeof msg==='string' && msg) ? msg : 'Image upload failed.';
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
  /* The ← button walks back through the committed-selection trail. If you've
     scrolled away without settling (selection != top of stack), it first
     snaps you back to that last stable selection; once you're on it, each
     press steps to the previous committed selection. */
  function scrollIndexToTop(idx){
    if(idx===null||idx===undefined) return null;
    var el=bubbles.querySelector('.chat-msg[data-i="'+idx+'"]');
    if(!el||el.offsetParent===null) return null;
    el.scrollIntoView({block:'start',behavior:'smooth'});
    return el;
  }
  backBtn.addEventListener('click',function(){
    if(!navStack.length) return;
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; } /* drop a pending scroll-commit */
    var cur=idxOf(selected), top=navStack[navStack.length-1], target;
    if(cur===top){
      if(navStack.length<2) return;          /* already at the oldest committed selection */
      navStack.pop();                         /* leave the current one... */
      target=navStack[navStack.length-1];     /* ...and go to the previous */
    } else {
      target=top;                             /* transient scroll-away: snap back to the last stable */
    }
    suppressSyncUntil=Date.now()+800;
    var el=scrollIndexToTop(target); if(el) selectMsg(el);
    updateBack();
  });
  updateBack();
  bubbles.addEventListener('click',function(e){
    var t=e.target;
    var rb=t.closest&&t.closest('.msg-refer');
    if(rb){ var mm=rb.closest('.chat-msg'); if(mm) insertAtCursor('MSG_'+mm.getAttribute('data-hash')+' '); return; }
    var a=t.closest&&t.closest('a.msg-ref');
    if(a){ e.preventDefault();
      var tgt=document.getElementById(a.getAttribute('href').slice(1));
      if(tgt){ suppressSyncUntil=Date.now()+800;
        tgt.scrollIntoView({block:'center',behavior:'smooth'}); selectAndCommit(tgt,true); }
      return; }
    var msg=t.closest&&t.closest('.chat-msg'); /* a plain click (incl. on an image) selects the message */
    if(msg) selectAndCommit(msg,true);
    if(t&&t.tagName==='IMG'&&t.closest('.chat-body')) showImagePopup(t.src);
  });
  textarea.focus();
})();
