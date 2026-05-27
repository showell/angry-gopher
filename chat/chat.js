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
  var selected=null;
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
  /* A programmatic jump (MSG_ link, back/forward, search, arrow, paging)
     suppresses scroll-driven reselection so the smooth-scroll animation can't
     steal the selection back. We suppress until the scroll actually goes QUIET,
     not for a fixed window: a far jump animates well past any time guess, and a
     centered target means the "topmost visible" the detector would pick isn't
     the target anyway — so a fixed window let the detector wake mid-flight and
     land on the wrong message. armScrollSuppress() must be called right before
     each programmatic scroll. */
  var progScroll=false, progScrollTimer=null;
  function endProgScroll(){ progScroll=false; progScrollTimer=null; }
  function armScrollSuppress(){
    progScroll=true;
    if(progScrollTimer) clearTimeout(progScrollTimer);
    progScrollTimer=setTimeout(endProgScroll, 150); /* re-armed by each scroll event below */
  }
  function syncSelectionToScroll(){
    if(progScroll) return;
    var el=selectionCandidate();
    if(el && el!==selected){ selectAndCommit(el, false); updateNav(); } /* enables ← as you drift away */
  }
  var rafPending=false;
  history.addEventListener('scroll',function(){
    if(progScroll){ /* our own animated scroll: stay suppressed until it's idle for 150ms */
      if(progScrollTimer) clearTimeout(progScrollTimer);
      progScrollTimer=setTimeout(endProgScroll, 150);
      return;
    }
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
    meta.appendChild(document.createTextNode(' '));
    var refer=document.createElement('button'); refer.type='button'; refer.className='msg-refer';
    refer.title='Drop a "See MSG_…" reference into the compose box without quoting'; refer.textContent='refer'; meta.appendChild(refer);
    var body=document.createElement('div'); body.className='chat-body';
    body.innerHTML=m.html; /* sanitized server-side */
    div.appendChild(meta); div.appendChild(body);
    bubbles.appendChild(div);
    var span=document.createElement('span'); span.setAttribute('data-i',m.index);
    span.textContent=m.enc; transcript.appendChild(span); /* literal on-disk block */
    var em=(m.body||'').match(EDIT_RE); /* "Edit of MSG_<hash>" → supersede that original */
    if(em){ var orig=document.getElementById('msg-'+em[1]); if(orig) markEdited(orig, m.hash); }
  }
  /* A message whose body starts with "Edit of MSG_<hash>" supersedes that
     original: render a forward "Edited in MSG_<this>" link on the original and
     demote its content to a small verbatim quote. Append-only — the stored
     record is untouched; this is purely the rendered view (Transcript still
     shows both messages byte-for-byte). */
  var EDIT_RE=/^Edit of MSG_([0-9A-F]{6})\b/;
  function markEdited(origEl, editHash){
    var bodyEl=origEl.querySelector('.chat-body'); if(!bodyEl) return;
    bodyEl.textContent='';
    var note=document.createElement('div'); note.className='chat-edited-note';
    note.appendChild(document.createTextNode('Edited in '));
    var link=document.createElement('a'); link.className='msg-ref'; link.href='#msg-'+editHash;
    link.textContent='MSG_'+editHash; note.appendChild(link);
    var orig=document.createElement('div'); orig.className='chat-edited-orig';
    orig.textContent=origEl._body!=null?origEl._body:'';
    bodyEl.appendChild(note); bodyEl.appendChild(orig);
  }
  /* Quote-reply: drop the target message into the compose box as a fenced
     block and focus it, ready to type the reply underneath. The MSG_ header
     line linkifies back to the original; the ~~~ quote fence keeps the quoted
     text verbatim (its own MSG_ refs aren't re-linked, being inside a fence). */
  /* Drop a bare "See MSG_<hash>" reference into the compose box — the
     lightweight cousin of quoteReply when you just want to point at a
     message without dragging its body into the reply. */
  function referReply(el){
    if(!el||pendingCid) return;
    selectAndCommit(el,true); /* record the referenced message on the nav stack */
    var hash=el.getAttribute('data-hash');
    openCompose();
    insertAtCursor('See MSG_'+hash+' ');
  }
  function quoteReply(el){
    if(!el||pendingCid) return; /* don't disturb a send awaiting its ack */
    selectAndCommit(el,true); /* record the quoted message on the nav stack */
    var hash=el.getAttribute('data-hash'), mine=el.classList.contains('mine');
    var body=el._body!=null?el._body:'';
    openCompose(); /* ensure it's visible before we type into it */
    insertAtCursor('In MSG_'+hash+' '+(mine?'I said':'you said')+':\n~~~ quote\n'+body+'\n~~~\n\n');
    textarea.focus();
  }
  /* Edit: load the message back into compose with a transparent
     "Edit of MSG_<hash>" backlink prepended and the caret at the start of the
     original content. Append-only + transparent — it's just a new message that
     references the original (no copy/paste, automatic backlink). */
  function editMessage(el){
    if(!el||pendingCid) return; /* don't disturb a send awaiting its ack */
    selectAndCommit(el,true); /* record the edited message on the nav stack */
    var prefix='Edit of MSG_'+el.getAttribute('data-hash')+'\n\n';
    openCompose();
    textarea.value=prefix+(el._body!=null?el._body:'');
    textarea.setSelectionRange(prefix.length, prefix.length); /* caret at the start of the content */
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
  function toggleView(){ setView(history.className.indexOf('view-transcript')>=0?'rendered':'transcript'); }
  views.addEventListener('click',function(e){
    var a=e.target.closest('a[data-view]'); if(!a) return;
    e.preventDefault(); setView(a.getAttribute('data-view'));
  });
  toBottom();
  /* If we arrived with a #msg-<hash> fragment (e.g. from Docs' Post-to-chat),
     remember the target so finishBacklog can scroll+select+push it onto
     the nav stack once the backlog has fully landed. */
  var wantFocusHash=(function(){
    var m=(location.hash||'').match(/^#msg-([0-9A-Fa-f]+)$/);
    return m ? m[1].toUpperCase() : null;
  })();
  /* Backlog phase: the server sends a `backlog-size` preamble before
     replaying any messages, so we know how many to expect. While
     inBacklog is true we ONLY append to the DOM — no toBottom, no
     syncSelectionToScroll, no ack/search-refresh work. One final scroll
     happens in finishBacklog. Eliminates the per-message scroll avalanche
     that made 1000-message conversations crawl on initial load.
     The same path runs on EventSource reconnects (the server re-sends
     the preamble for the post-Last-Event-ID slice); reconnect backlogs
     only auto-scroll if the user was caught up before the gap. */
  var inBacklog=true, backlogSize=null, backlogSeen=0;
  var wasCaughtUpAtBacklogStart=true;
  function finishBacklog(){
    inBacklog=false;
    if(wantFocusHash){
      var el=document.getElementById('msg-'+wantFocusHash);
      if(el){
        armScrollSuppress();
        el.scrollIntoView({block:'center',behavior:'smooth'});
        selectAndCommit(el,true); /* pushes the message onto the back/forward stack */
      }
      wantFocusHash=null; /* consumed; reconnect backlogs use the caughtUp fallback below */
    } else if(wasCaughtUpAtBacklogStart){
      toBottom();
    }
    syncSelectionToScroll();
  }
  var es=new EventSource('/chat/stream?with='+encodeURIComponent(PARTNER)+'&since=0');
  es.addEventListener('backlog-size', function(e){
    /* Reset per-connection: fires on initial load AND on every reconnect. */
    wasCaughtUpAtBacklogStart=caughtUp();
    inBacklog=true; backlogSeen=0;
    backlogSize=parseInt(e.data,10) || 0;
    if(backlogSize===0) finishBacklog(); /* nothing to wait for */
  });
  es.onmessage=function(e){
    var m=JSON.parse(e.data);
    addMessage(m);
    if(inBacklog){
      backlogSeen++;
      if(backlogSize!==null && backlogSeen>=backlogSize) finishBacklog();
      return; /* skip per-message scroll/select/refresh during backlog */
    }
    /* Live path: an individual message arriving post-backlog. */
    var stick=caughtUp();
    if(stick) toBottom();
    syncSelectionToScroll();
    if(pendingCid&&m.cid===pendingCid) ackSend(); /* our message round-tripped: saved + echoed */
    if(searchModalOpen()) refreshOpenSearch(); /* keep an open search current as messages stream in */
  };
  /* Resilient send: a send is confirmed only when our own message echoes back
     over SSE carrying the same client-id (proof it was both saved AND
     broadcast). Until then the compose box stays disabled with its text kept;
     if no echo arrives within the timeout (or the POST itself fails), we pop a
     "host may be down" modal and re-enable for a manual retry. No auto-retry —
     the point is just to make an outage transparent. */
  var pendingCid=null, pendingTimer=null;
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
    fetch('/chat/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'with='+encodeURIComponent(PARTNER)+'&body='+encodeURIComponent(text)+'&cid='+encodeURIComponent(cid)
    }).then(function(r){ if(!r.ok) throw new Error('status '+r.status); /* success is confirmed by the SSE echo */ })
      .catch(hostDown);
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
  /* --- click any code/pre block to view it full-size in a monospace modal --- */
  function showCodePopup(text){
    var dlg=document.createElement('dialog'); dlg.className='chat-code-dialog';
    var controls=document.createElement('div'); controls.className='chat-code-controls';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click',function(){ dlg.close(); });
    controls.appendChild(close);
    var pre=document.createElement('pre'); pre.className='chat-code-view'; pre.textContent=text;
    dlg.appendChild(controls); dlg.appendChild(pre);
    /* The dialog is fit-content (CSS) capped at 80vw/80vh; the <pre> scrolls
       when the code is larger. Esc (native) or a backdrop click also close it. */
    dlg.addEventListener('close',function(){ dlg.remove(); });
    dlg.addEventListener('click',function(e){ if(e.target===dlg) dlg.close(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }
  /* Classify a click inside a rendered message body into a semantic target, so
     every surface that renders a body (the feed, the search-results modal)
     shares ONE notion of "what did you click" and only has to decide the few
     behaviors that genuinely differ between them. */
  function hitInBody(t){
    if(t.tagName==='IMG') return {kind:'image', src:t.src};
    var pre=t.closest&&t.closest('pre'); if(pre) return {kind:'pre', text:pre.textContent};
    if(t.closest&&t.closest('a.msg-ref')) return {kind:'msgref', el:t.closest('a.msg-ref')};
    if(t.closest&&t.closest('a')) return {kind:'link'}; /* external link: server-baked target=_blank, no JS */
    return {kind:'plain'};
  }
  /* Image + code popups are identical on every surface: they're native
     <dialog>s, so opened over the search modal they stack and closing returns
     to it. Returns true if it handled the hit. */
  function openHitMedia(hit){
    if(hit.kind==='image'){ showImagePopup(hit.src); return true; }
    if(hit.kind==='pre'){ showCodePopup(hit.text); return true; }
    return false;
  }
  /* Feed-only: jump to a MSG_ ref's target and select it. The caller records
     the source first so Back returns there. */
  function navigateRef(ref){
    var tgt=document.getElementById(ref.getAttribute('href').slice(1));
    if(!tgt) return;
    armScrollSuppress();
    tgt.scrollIntoView({block:'center',behavior:'smooth'}); selectAndCommit(tgt,true);
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
    armScrollSuppress();
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
    var rb=t.closest&&t.closest('.msg-refer');
    if(rb){ var rmm=rb.closest('.chat-msg'); if(rmm) referReply(rmm); return; }
    var msg=t.closest&&t.closest('.chat-msg'); /* any click on a bubble selects it (incl. image / pre / MSG_ ref source) */
    if(msg) selectAndCommit(msg,true);
    var hit=hitInBody(t);
    if(hit.kind==='msgref'){ e.preventDefault(); navigateRef(hit.el); return; } /* feed: jump to the target */
    openHitMedia(hit); /* image→zoom, pre→code; link/plain need nothing more */
  });
  /* --- keyboard navigation of the feed (cursor-aware) --- */
  function visibleMsgs(){
    var out=[], els=bubbles.querySelectorAll('.chat-msg');
    for(var i=0;i<els.length;i++) if(els[i].offsetParent!==null) out.push(els[i]);
    return out;
  }
  /* Scroll the feed (only the feed, never the page) just enough to bring el
     into view. When scrolling down, leave a small pad below so the selected-
     border isn't clipped at the viewport edge and a sliver of the next
     message peeks through — easier to tell you aren't at the bottom. If the
     message is taller than viewport-minus-pad, pin its top instead so its
     top stays visible (the bottom can overflow; arrow-down again from there
     resolves it normally). */
  function revealInFeed(el){
    var hr=history.getBoundingClientRect(), r=el.getBoundingClientRect();
    var padBot=48; /* selected-border + a peek of the next bubble */
    var padTop=6;  /* just enough breathing room to see the top selected-border */
    if(r.top<hr.top+padTop) history.scrollTop+=r.top-hr.top-padTop;
    else if(r.bottom>hr.bottom-padBot){
      var delta=r.bottom-(hr.bottom-padBot);
      if(r.top-delta<hr.top+padTop) delta=r.top-hr.top-padTop; /* taller than window: pin top with breathing room */
      history.scrollTop+=delta;
    }
  }
  /* Move the cursor by delta messages (clamped), revealing it. Scroll-driven
     reselection is briefly suppressed so our explicit pick isn't overridden. */
  function moveCursor(delta){
    var msgs=visibleMsgs();
    if(!msgs.length){ history.scrollTop+=delta*40; return; } /* transcript view: just scroll */
    var idx=selected?msgs.indexOf(selected):-1;
    if(idx<0){ var c=selectionCandidate(); idx=c?msgs.indexOf(c):0; if(idx<0) idx=0; }
    else idx=Math.max(0,Math.min(msgs.length-1,idx+delta));
    armScrollSuppress();
    selectAndCommit(msgs[idx],false); revealInFeed(msgs[idx]); updateNav();
  }
  /* Jump cursor + feed to the very top (bottom=false) or bottom (bottom=true). */
  function cursorToExtreme(bottom){
    history.scrollTop=bottom?history.scrollHeight:0;
    var msgs=visibleMsgs(); if(!msgs.length) return;
    armScrollSuppress();
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
  /* --- search modal: a two-phase palette over the WHOLE transcript.
     Phase 1 autocompletes against the EXACT tokens present in the conversation
     (type "apo" → "apoorva", and "aporva" too if that typo exists somewhere) —
     suggestions are real corpus words, so it's autocomplete without stemming.
     Phase 2 (Enter) lists every message containing the chosen term, RENDERED
     (a clone of the feed's server HTML) with the term highlighted, newest first
     (you're usually looking back); ↑↓ choose, Enter jumps there (closing the
     modal, pushing the nav stack). Inside a rendered result, images/code pop the
     same modals (stacked over search), external links open in a new tab, and
     MSG_ refs are inert. The match is always a literal substring, so URLs,
     code, and punctuation are findable verbatim. No index: the token map is
     rebuilt on open (milliseconds) and the message scan is one linear pass. */
  var searchBtn=document.getElementById('chat-search-btn');
  var SEARCH_MIN=2, SUGGEST_CAP=10, SNIPPET_PAD=90;
  /* smart-case: case-sensitive only if the query carries an uppercase letter */
  function smartIndexOf(hay,q,from){ return /[A-Z]/.test(q)?hay.indexOf(q,from||0):hay.toLowerCase().indexOf(q.toLowerCase(),from||0); }
  function smartHit(body,q){ return smartIndexOf(body,q,0)>=0; }
  /* tokens = whitespace-delimited words with surrounding punctuation trimmed
     (internal punctuation kept, so "foo.com" / "https://x" survive as tokens). */
  function tokenize(body){
    var raw=body.split(/\s+/), out=[];
    for(var i=0;i<raw.length;i++){
      var w=raw[i].replace(/^[^\p{L}\p{N}]+/u,'').replace(/[^\p{L}\p{N}]+$/u,'').toLowerCase();
      if(w.length>=2) out.push(w);
    }
    return out;
  }
  function buildTokenIndex(){
    var map=Object.create(null), els=bubbles.querySelectorAll('.chat-msg');
    for(var i=0;i<els.length;i++){
      var toks=tokenize(els[i]._body||''), seen=Object.create(null);
      for(var j=0;j<toks.length;j++){
        var t=toks[j]; if(seen[t]) continue; seen[t]=1;
        if(map[t]){ map[t].count++; map[t].sample=els[i]; } else map[t]={count:1,sample:els[i]}; /* sample = most recent msg with it */
      }
    }
    return map;
  }
  function suggestTokens(map,q){
    q=q.toLowerCase(); var pre=[], sub=[];
    for(var t in map){ var k=t.indexOf(q); if(k===0) pre.push(t); else if(k>0) sub.push(t); }
    function byCount(a,b){ return map[b].count-map[a].count || (a<b?-1:1); }
    pre.sort(byCount); sub.sort(byCount); return pre.concat(sub); /* prefix matches first */
  }
  /* append `text` to `node` with every occurrence of `term` wrapped in <mark>
     (built as DOM nodes, never innerHTML — the raw body is untrusted text). */
  function highlightInto(node,text,term){
    if(!term){ node.appendChild(document.createTextNode(text)); return; }
    var pos=0,m;
    while((m=smartIndexOf(text,term,pos))>=0){
      if(m>pos) node.appendChild(document.createTextNode(text.slice(pos,m)));
      var mk=document.createElement('mark'); mk.textContent=text.slice(m,m+term.length); node.appendChild(mk);
      pos=m+term.length;
    }
    if(pos<text.length) node.appendChild(document.createTextNode(text.slice(pos)));
  }
  /* Highlight `term` inside an already-rendered subtree, wrapping matches in
     <mark> by walking TEXT NODES only — so links, images, and code markup
     survive untouched. (highlightInto above builds from plain text; this is its
     rendered-HTML sibling, used for phase-2 results.) */
  function highlightRendered(root,term){
    if(!term) return;
    var walk=document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false), nodes=[], n;
    while((n=walk.nextNode())) nodes.push(n);
    for(var i=0;i<nodes.length;i++){
      var node=nodes[i], text=node.nodeValue;
      if(smartIndexOf(text,term,0)<0) continue;
      var frag=document.createDocumentFragment();
      highlightInto(frag, text, term);
      node.parentNode.replaceChild(frag, node);
    }
  }
  function appendSnippet(node,body,term){
    var idx=smartIndexOf(body,term,0), start=0, end=body.length;
    if(idx>=0){ start=Math.max(0,idx-SNIPPET_PAD); end=Math.min(body.length,idx+term.length+SNIPPET_PAD); }
    else end=Math.min(body.length,180);
    if(start>0) node.appendChild(document.createTextNode('…'));
    highlightInto(node, body.slice(start,end), term);
    if(end<body.length) node.appendChild(document.createTextNode('…'));
  }
  /* active modal state, or null when closed:
     { dlg, input, list, status, phase:'suggest'|'results', map, items, sel, term } */
  var SR=null;
  function searchModalOpen(){ return !!SR; }
  function openSearchModal(){
    if(SR){ SR.input.focus(); return; }
    var dlg=document.createElement('dialog'); dlg.className='chat-search-modal';
    var input=document.createElement('input'); input.type='text'; input.className='chat-sr-input';
    input.placeholder='Search messages…'; input.autocomplete='off';
    var status=document.createElement('div'); status.className='chat-sr-status';
    var list=document.createElement('div'); list.className='chat-sr-list';
    dlg.appendChild(input); dlg.appendChild(status); dlg.appendChild(list);
    document.body.appendChild(dlg);
    SR={ dlg:dlg, input:input, list:list, status:status, phase:'suggest', map:buildTokenIndex(), items:[], sel:-1, term:'' };
    input.addEventListener('input', function(){ SR.phase='suggest'; renderSuggest(); });
    dlg.addEventListener('keydown', onSearchKey);
    dlg.addEventListener('cancel', function(e){ e.preventDefault(); escSearch(); }); /* own the Esc */
    dlg.addEventListener('click', onSearchClick);
    dlg.addEventListener('close', function(){ dlg.remove(); SR=null; history.focus({preventScroll:true}); });
    dlg.showModal(); input.focus(); renderSuggest();
  }
  function closeSearchModal(){ if(SR) SR.dlg.close(); }
  function escSearch(){ if(!SR) return; if(SR.phase==='results'){ SR.phase='suggest'; SR.input.focus(); renderSuggest(); } else closeSearchModal(); }
  function paintSel(){
    var rows=SR.list.querySelectorAll('.chat-sr-row');
    for(var i=0;i<rows.length;i++) rows[i].classList.toggle('sel', i===SR.sel);
    if(SR.sel>=0 && rows[SR.sel]) rows[SR.sel].scrollIntoView({block:'nearest'});
  }
  function renderSuggest(){
    var q=SR.input.value.trim(); SR.list.textContent=''; SR.items=[]; SR.sel=-1;
    if(q.length<SEARCH_MIN){ SR.status.textContent='Type at least '+SEARCH_MIN+' characters to search…'; return; }
    var toks=suggestTokens(SR.map,q);
    if(!toks.length){ SR.status.textContent='No matching words — press Enter to search “'+q+'” literally.'; return; }
    SR.status.textContent = toks.length>SUGGEST_CAP ? (toks.length+' words match — keep typing to narrow') : (toks.length+(toks.length===1?' word':' words')+' · ↑↓ choose, Enter to search');
    var shown=toks.slice(0,SUGGEST_CAP);
    for(var i=0;i<shown.length;i++){
      var t=shown[i], info=SR.map[t];
      var row=document.createElement('div'); row.className='chat-sr-row'; row.setAttribute('data-i',i);
      var head=document.createElement('div'); head.className='chat-sr-tok';
      /* Wrap the highlighted token in ONE child so the flex row's gap:8px
         only sits between token-and-count, never between <mark> and the
         rest of the token (which would print "pro" + " " + "bably"). */
      var tok=document.createElement('span'); highlightInto(tok, t, q.toLowerCase()); head.appendChild(tok);
      var cnt=document.createElement('span'); cnt.className='chat-sr-cnt'; cnt.textContent=info.count+(info.count===1?' msg':' msgs');
      head.appendChild(cnt);
      var ctx=document.createElement('div'); ctx.className='chat-sr-ctx'; appendSnippet(ctx, info.sample._body||'', t);
      row.appendChild(head); row.appendChild(ctx);
      SR.list.appendChild(row); SR.items.push({tok:t});
    }
    SR.sel=0; paintSel();
  }
  function runResults(term){
    SR.term=term; SR.phase='results'; SR.list.textContent=''; SR.items=[]; SR.sel=-1;
    var els=bubbles.querySelectorAll('.chat-msg'), res=[];
    for(var i=0;i<els.length;i++){ if(smartHit(els[i]._body||'', term)) res.push(els[i]); }
    res.reverse(); /* newest first — searching back through history is the common case */
    if(!res.length){ SR.status.textContent='No messages contain “'+term+'”. Esc to refine.'; return; }
    SR.status.textContent=res.length+(res.length===1?' message — Enter to go':' messages — ↑↓ choose, Enter to go')+' · Esc to refine';
    for(var k=0;k<res.length;k++){
      var el=res[k], meta=el.querySelector('.chat-meta');
      var row=document.createElement('div'); row.className='chat-sr-row'; row.setAttribute('data-i',k);
      var head=document.createElement('div'); head.className='chat-sr-rhead';
      head.textContent=(meta&&meta.firstChild?meta.firstChild.nodeValue:'').trim();
      var body=document.createElement('div'); body.className='chat-sr-rbody';
      var src=el.querySelector('.chat-body'); /* reuse the feed's server-rendered HTML */
      if(src){ var clone=src.cloneNode(true); highlightRendered(clone, term); body.appendChild(clone); }
      else highlightInto(body, el._body||'', term); /* defensive: no rendered body */
      row.appendChild(head); row.appendChild(body);
      SR.list.appendChild(row); SR.items.push({el:el});
    }
    SR.sel=0; paintSel();
  }
  function finalizeSearch(){
    var term=(SR.sel>=0 && SR.items[SR.sel] && SR.items[SR.sel].tok) ? SR.items[SR.sel].tok : SR.input.value.trim();
    if(term) runResults(term);
  }
  function chooseResult(){
    if(SR.sel<0||!SR.items[SR.sel]) return;
    var el=SR.items[SR.sel].el;
    closeSearchModal();
    armScrollSuppress();
    selectAndCommit(el,true); scrollToIndex(idxOf(el)); updateNav(); /* jump + push nav stack */
  }
  function onSearchKey(e){
    if(e.key==='ArrowDown'){ e.preventDefault(); if(SR.items.length){ SR.sel=Math.min(SR.items.length-1,SR.sel+1); paintSel(); } }
    else if(e.key==='ArrowUp'){ e.preventDefault(); if(SR.items.length){ SR.sel=Math.max(0,SR.sel-1); paintSel(); } }
    else if(e.key==='Enter'){ e.preventDefault(); if(SR.phase==='suggest') finalizeSearch(); else chooseResult(); }
  }
  function onSearchClick(e){
    if(e.target===SR.dlg){ closeSearchModal(); return; } /* backdrop click */
    var row=e.target.closest && e.target.closest('.chat-sr-row'); if(!row) return;
    SR.sel=parseInt(row.getAttribute('data-i'),10); paintSel();
    if(SR.phase==='suggest'){ finalizeSearch(); return; }
    /* results: a click inside the rendered body acts in place; the two
       behaviors that differ from the feed live here and nowhere else. */
    var hit=hitInBody(e.target);
    if(hit.kind==='msgref'){ e.preventDefault(); return; } /* search: MSG_ refs are inert */
    if(openHitMedia(hit)) return;                          /* image→zoom, pre→code (stacked) */
    if(hit.kind==='link') return;                          /* external link → new tab */
    chooseResult();                                        /* plain click → go to this message */
  }
  function refreshOpenSearch(){ /* a message streamed in while the modal is open */
    if(!SR) return; SR.map=buildTokenIndex();
    if(SR.phase==='suggest') renderSuggest(); else runResults(SR.term);
  }
  searchBtn.addEventListener('click', openSearchModal);
  /* Override these keys when reading the feed (not when typing in compose). */
  document.addEventListener('keydown',function(e){
    var ae=document.activeElement;
    if(ae&&(ae.tagName==='TEXTAREA'||ae.tagName==='INPUT'||ae.isContentEditable)) return;
    if(e.ctrlKey||e.metaKey||e.altKey) return;
    switch(e.key){
      case 'c': e.preventDefault(); openCompose(); return;
      case 'b': e.preventDefault(); backBtn.click(); return; /* disabled buttons ignore click */
      case 'f': e.preventDefault(); fwdBtn.click(); return;
      case 't': e.preventDefault(); toggleView(); return;
      case '/': e.preventDefault(); openSearchModal(); return;
      case 'r': if(selected){ e.preventDefault(); quoteReply(selected); } return;
      case 'e': if(selected){ e.preventDefault(); editMessage(selected); } return;
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
