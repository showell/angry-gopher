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
  var fwdBtn=document.getElementById('chat-fwd');
  var composeBody=document.getElementById('chat-compose-body');
  var closedPanel=document.getElementById('chat-closed-panel');
  var openComposeBtn=document.getElementById('chat-open-compose');
  function toBottom(){ history.scrollTop=history.scrollHeight; }
  /* Compose is closeable: Esc on an empty box closes it and hands focus back
     to the feed; "c" (or the panel button) reopens it. Closing swaps the
     compose body for a panel with the reopen button + a keyboard cheatsheet,
     while the panel itself stays put — so the feed never changes width/position. */
  function openCompose(){ closedPanel.style.display='none'; composeBody.style.display=''; textarea.focus(); }
  function closeCompose(){ composeBody.style.display='none'; closedPanel.style.display=''; history.focus({preventScroll:true}); }
  openComposeBtn.addEventListener('click',openCompose);
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
  /* Persistent "selected message" (Zulip-style cursor) + a navigation history.
     At most one message is selected; it shows a steady highlight ring. The
     selection moves when you click a message / MSG_ link, and otherwise FOLLOWS
     scrolling: the topmost message fully in view, or — when one message is too
     tall for any to be fully visible — the topmost whose beginning (top edge)
     shows.

     Navigation history has browser back/forward semantics: `entries` is the
     trail of *committed* selections and `pos` points at the current one. ←/→
     move `pos` without mutating the trail; any FRESH navigation (recordNav)
     drops the forward tail and appends — so going back and then navigating
     elsewhere resets the forward stack. A click/link jump commits immediately;
     a scroll- or arrow-driven change commits only after a 700ms pause, so
     scrolling past messages doesn't churn the trail — only where you settle. */
  var selected=null, suppressSyncUntil=0;
  function idxOf(el){ return el?el.getAttribute('data-i'):null; }
  function selectMsg(el){
    if(!el||el===selected) return;
    if(selected) selected.classList.remove('selected');
    selected=el; el.classList.add('selected');
  }
  var entries=[], pos=-1, commitTimer=null;
  function curEntry(){ return pos>=0?entries[pos]:null; }
  function drifted(){ return selected&&idxOf(selected)!==curEntry(); } /* scrolled away from the committed pos */
  function updateNav(){
    backBtn.disabled=!(pos>0||drifted()); /* drift enables ← as a "recover to where I was" */
    fwdBtn.disabled=!(pos<entries.length-1);
  }
  function recordNav(idx){
    if(idx===null||idx===curEntry()) return; /* ignore re-selecting the current entry */
    entries.length=pos+1;                    /* drop the forward tail — fresh nav resets it */
    entries.push(idx); pos=entries.length-1;
    updateNav();
  }
  function commitSelection(idx, immediate){
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; }
    if(immediate) recordNav(idx);
    else commitTimer=setTimeout(function(){ commitTimer=null; recordNav(idx); }, 700);
  }
  /* Select + record: immediate=true for a click/link jump, false to debounce
     a scroll- or arrow-driven change. */
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
    if(el && el!==selected){ selectAndCommit(el, false); updateNav(); } /* enables ← as you drift away */
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
    div._body=m.body; /* raw markdown source, kept for quote-reply */
    var meta=document.createElement('div'); meta.className='chat-meta';
    meta.appendChild(document.createTextNode(m.from+' · '+m.time+' '));
    var quote=document.createElement('button'); quote.type='button'; quote.className='msg-quote';
    quote.title='Quote this message in a reply (or press r)'; quote.textContent='quote-reply'; meta.appendChild(quote);
    var body=document.createElement('div'); body.className='chat-body';
    body.innerHTML=m.html; /* sanitized server-side */
    div.appendChild(meta); div.appendChild(body);
    bubbles.appendChild(div);
    var span=document.createElement('span'); span.setAttribute('data-i',m.index);
    span.textContent=m.enc; transcript.appendChild(span); /* literal on-disk block */
  }
  /* Quote-reply: drop the target message into the compose box as a fenced
     block and focus it, ready to type the reply underneath. The MSG_ header
     line linkifies back to the original; the ~~~ quote fence keeps the quoted
     text verbatim (its own MSG_ refs aren't re-linked, being inside a fence). */
  function quoteReply(el){
    if(!el) return;
    var hash=el.getAttribute('data-hash'), mine=el.classList.contains('mine');
    var body=el._body!=null?el._body:'';
    openCompose(); /* ensure it's visible before we type into it */
    insertAtCursor('In MSG_'+hash+' '+(mine?'I said':'you said')+':\n~~~ quote\n'+body+'\n~~~\n\n');
    textarea.focus();
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
    if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){ e.preventDefault(); send(); return; }
    if(e.key==='Escape'&&textarea.value.trim()===''){ e.preventDefault(); closeCompose(); } /* empty only — never lose a draft */
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
  function scrollIndexToTop(idx){
    if(idx===null||idx===undefined) return null;
    var el=bubbles.querySelector('.chat-msg[data-i="'+idx+'"]');
    if(!el||el.offsetParent===null) return null;
    el.scrollIntoView({block:'start',behavior:'smooth'});
    return el;
  }
  /* Navigate to entries[pos] without recording it, so ←/→ don't create new
     history themselves (and the scroll they trigger is suppressed). */
  function goToEntry(){
    if(pos<0) return;
    suppressSyncUntil=Date.now()+800;
    var el=scrollIndexToTop(entries[pos]); if(el) selectMsg(el);
    updateNav();
  }
  /* ← walks back through the committed trail. If you've scrolled away without
     settling, the first press recovers your committed position (and drops the
     pending commit, so the forward tail survives); from there each press steps
     back one. → redoes a back, as long as nothing fresh has reset the tail. */
  backBtn.addEventListener('click',function(){
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; }
    if(drifted()){ goToEntry(); return; } /* recover to entries[pos] */
    if(pos>0){ pos--; goToEntry(); }
  });
  fwdBtn.addEventListener('click',function(){
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; }
    if(pos<entries.length-1){ pos++; goToEntry(); }
  });
  updateNav();
  bubbles.addEventListener('click',function(e){
    var t=e.target;
    var qb=t.closest&&t.closest('.msg-quote');
    if(qb){ var mm=qb.closest('.chat-msg'); if(mm) quoteReply(mm); return; }
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
  /* --- keyboard navigation of the feed (cursor-aware) --- */
  function visibleMsgs(){
    var out=[], els=bubbles.querySelectorAll('.chat-msg');
    for(var i=0;i<els.length;i++) if(els[i].offsetParent!==null) out.push(els[i]);
    return out;
  }
  /* Scroll the feed (only the feed, never the page) just enough to bring el
     fully into view — a "nearest" reveal. */
  function revealInFeed(el){
    var hr=history.getBoundingClientRect(), r=el.getBoundingClientRect();
    if(r.top<hr.top) history.scrollTop+=r.top-hr.top;
    else if(r.bottom>hr.bottom) history.scrollTop+=r.bottom-hr.bottom;
  }
  /* Move the cursor by delta messages (clamped), revealing it. Scroll-driven
     reselection is briefly suppressed so our explicit pick isn't overridden. */
  function moveCursor(delta){
    var msgs=visibleMsgs();
    if(!msgs.length){ history.scrollTop+=delta*40; return; } /* transcript view: just scroll */
    var idx=selected?msgs.indexOf(selected):-1;
    if(idx<0){ var c=selectionCandidate(); idx=c?msgs.indexOf(c):0; if(idx<0) idx=0; }
    else idx=Math.max(0,Math.min(msgs.length-1,idx+delta));
    suppressSyncUntil=Date.now()+400;
    selectAndCommit(msgs[idx],false); revealInFeed(msgs[idx]); updateNav();
  }
  /* Jump cursor + feed to the very top (bottom=false) or bottom (bottom=true). */
  function cursorToExtreme(bottom){
    history.scrollTop=bottom?history.scrollHeight:0;
    var msgs=visibleMsgs(); if(!msgs.length) return;
    suppressSyncUntil=Date.now()+400;
    selectAndCommit(bottom?msgs[msgs.length-1]:msgs[0],true); updateNav();
  }
  /* PgUp/PgDn: page the feed if it can scroll that way (cursor follows the
     scroll via the scroll listener); if it can't, send the cursor to the extreme. */
  function pageNav(dir){
    var canScroll=dir<0 ? history.scrollTop>0
                        : history.scrollTop+history.clientHeight<history.scrollHeight-1;
    if(canScroll) history.scrollTop+=dir*Math.max(40,history.clientHeight-40);
    else cursorToExtreme(dir>0);
  }
  /* Override these keys when reading the feed (not when typing in compose). */
  document.addEventListener('keydown',function(e){
    var ae=document.activeElement;
    if(ae&&(ae.tagName==='TEXTAREA'||ae.tagName==='INPUT'||ae.isContentEditable)) return;
    if(e.ctrlKey||e.metaKey||e.altKey) return;
    switch(e.key){
      case 'c': e.preventDefault(); openCompose(); return;
      case 'b': e.preventDefault(); backBtn.click(); return; /* disabled buttons ignore click */
      case 'f': e.preventDefault(); fwdBtn.click(); return;
      case 'r': if(selected){ e.preventDefault(); quoteReply(selected); } return;
      case 'ArrowDown': e.preventDefault(); moveCursor(1); return;
      case 'ArrowUp':   e.preventDefault(); moveCursor(-1); return;
      case 'Home':      e.preventDefault(); cursorToExtreme(false); return;
      case 'End':       e.preventDefault(); cursorToExtreme(true); return;
      case 'PageDown':  e.preventDefault(); pageNav(1); return;
      case 'PageUp':    e.preventDefault(); pageNav(-1); return;
    }
  });
  textarea.focus();
})();
