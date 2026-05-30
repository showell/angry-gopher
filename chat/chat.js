(function(){
  var root=document.getElementById('chat-root');
  var CONV=root.dataset.conv;
  var SESSION=root.dataset.session;
  /* All API endpoints live under the session's URL prefix (mirrors the
     on-disk path under {ChatDataRoot}/<conv>/sessions/<sid>). */
  var SESSION_BASE='/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(SESSION);
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
  function toBottom(){ armedScroll(function(){ history.scrollTop=history.scrollHeight; }); }
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
     land on the wrong message. Every programmatic scroll must arm suppression
     first — route them all through armedScroll() so the arm can't be forgotten. */
  var progScroll=false, progScrollTimer=null;
  function endProgScroll(){ progScroll=false; progScrollTimer=null; }
  function armScrollSuppress(){
    progScroll=true;
    if(progScrollTimer) clearTimeout(progScrollTimer);
    progScrollTimer=setTimeout(endProgScroll, 150); /* re-armed by each scroll event below */
  }
  /* The one way to scroll programmatically: arm suppression, then scroll.
     Bundling them means no call site can do the scroll while forgetting the
     arm (which would let the scroll listener steal the selection mid-flight). */
  function armedScroll(scroll){ armScrollSuppress(); scroll(); }
  function syncSelectionToScroll(){
    if(progScroll) return;
    var el=selectionCandidate();
    if(el && el!==selected){ selectAndCommit(el, false); updateNav(); } /* enables ← as you drift away */
  }
  var rafPending=false;
  /* True iff the user has scrolled the feed themselves (not us via
     toBottom / scrollIntoView). The post-backlog stabilizer reads this
     to decide when to stop chasing layout growth — position-distance
     heuristics are no good here because image loads grow scrollHeight
     out from under us, which looks indistinguishable from a user scroll
     if you only watch scrollTop. progScroll is the source of truth:
     while it's set (a 150ms window after each armScrollSuppress), every
     scroll event is ours; outside that, it's the user. */
  var userScrolledFeed=false;
  history.addEventListener('scroll',function(){
    if(progScroll){ /* our own animated scroll: stay suppressed until it's idle for 150ms */
      if(progScrollTimer) clearTimeout(progScrollTimer);
      progScrollTimer=setTimeout(endProgScroll, 150);
      return;
    }
    userScrolledFeed=true;
    if(rafPending) return; rafPending=true;
    requestAnimationFrame(function(){ rafPending=false; syncSelectionToScroll(); });
  });
  function addMessage(m){
    var empty=document.getElementById('chat-empty'); if(empty) empty.remove();
    var div=document.createElement('div');
    div.className='chat-msg '+(m.mine?'mine':'theirs');
    div.id='msg-'+m.id; div.setAttribute('data-i',m.index); div.setAttribute('data-id',m.id);
    div._body=m.body; /* raw markdown source, kept for quote-reply */
    var meta=document.createElement('div'); meta.className='chat-meta';
    meta.appendChild(document.createTextNode('#'+(m.index+1)+' '+m.from+' · '+m.time+' '));
    var quote=document.createElement('button'); quote.type='button'; quote.className='msg-quote';
    quote.title='Quote this message in a reply (q)'; quote.textContent='quote-reply'; meta.appendChild(quote);
    meta.appendChild(document.createTextNode(' '));
    var refer=document.createElement('button'); refer.type='button'; refer.className='msg-refer';
    refer.title='Drop a "See MSG_…" reference into the compose box without quoting (r)'; refer.textContent='refer'; meta.appendChild(refer);
    meta.appendChild(document.createTextNode(' '));
    var edit=document.createElement('button'); edit.type='button'; edit.className='msg-edit';
    edit.title='Load this message back into compose with an "Edit of MSG_…" backlink (e)'; edit.textContent='edit'; meta.appendChild(edit);
    var body=document.createElement('div'); body.className='chat-body';
    body.innerHTML=m.html; /* sanitized server-side */
    div.appendChild(meta); div.appendChild(body);
    bubbles.appendChild(div);
    var span=document.createElement('span'); span.setAttribute('data-i',m.index);
    span.textContent=m.enc; transcript.appendChild(span); /* literal on-disk block */
    var em=(m.body||'').match(EDIT_RE); /* "Edit of MSG_<hash>" → supersede that original */
    if(em){ var orig=document.getElementById('msg-'+em[1]); if(orig) markEdited(orig, m.id); }
  }
  /* A message whose body starts with "Edit of MSG_<hash>" supersedes that
     original: render a forward "Edited in MSG_<this>" link on the original and
     demote its content to a small verbatim quote. Append-only — the stored
     record is untouched; this is purely the rendered view (Transcript still
     shows both messages byte-for-byte). */
  var EDIT_RE=/^Edit of MSG_([A-Za-z0-9-]+_[0-9]+)\b/;
  function markEdited(origEl, editID){
    var bodyEl=origEl.querySelector('.chat-body'); if(!bodyEl) return;
    bodyEl.textContent='';
    var note=document.createElement('div'); note.className='chat-edited-note';
    note.appendChild(document.createTextNode('Edited in '));
    var link=document.createElement('a'); link.className='msg-ref'; link.href='#msg-'+editID;
    link.textContent='MSG_'+editID; note.appendChild(link);
    var spoiler=document.createElement('details'); spoiler.className='chat-edited-spoiler';
    var summary=document.createElement('summary'); summary.textContent='original'; spoiler.appendChild(summary);
    var orig=document.createElement('div'); orig.className='chat-edited-orig';
    orig.textContent=origEl._body!=null?origEl._body:'';
    spoiler.appendChild(orig);
    bodyEl.appendChild(note); bodyEl.appendChild(spoiler);
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
    var hash=el.getAttribute('data-id');
    openCompose();
    insertAtCursor('See MSG_'+hash+' ');
  }
  function quoteReply(el){
    if(!el||pendingCid) return; /* don't disturb a send awaiting its ack */
    selectAndCommit(el,true); /* record the quoted message on the nav stack */
    var hash=el.getAttribute('data-id'), mine=el.classList.contains('mine');
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
    var prefix='Edit of MSG_'+el.getAttribute('data-id')+'\n\n';
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
  var wantFocusID=(function(){
    var m=(location.hash||'').match(/^#msg-([A-Za-z0-9_-]+)$/);
    return m ? m[1] : null;
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
    var focusEl=null, anchorToBottom=false;
    if(wantFocusID){
      focusEl=document.getElementById('msg-'+wantFocusID);
      wantFocusID=null; /* consumed; reconnect backlogs use the caughtUp fallback below */
    } else if(wasCaughtUpAtBacklogStart){
      anchorToBottom=true;
    }
    /* Reset the user-scroll flag right before the initial anchor: from
       here on, only an INTENTIONAL post-anchor user scroll should stop
       the stabilizer. armScrollSuppress on every programmatic scrollTop
       keeps our own activity from tripping it. */
    userScrolledFeed=false;
    if(focusEl){
      armedScroll(function(){ focusEl.scrollIntoView({block:'center',behavior:'auto'}); });
      selectAndCommit(focusEl,true); /* pushes the message onto the back/forward stack */
    } else if(anchorToBottom){
      toBottom();
      /* Mirror cursorToExtreme(true) (the End-key path): explicitly select
         the LAST message rather than relying on syncSelectionToScroll, which
         picks the topmost-fully-in-view — that's the wrong choice when the
         user just landed at the bottom of the feed. */
      var msgs=visibleMsgs();
      if(msgs.length) selectAndCommit(msgs[msgs.length-1], true);
    } else {
      /* Reconnect case: keep whatever scroll/selection the user had. */
      syncSelectionToScroll();
    }
    /* Belt-and-suspenders: re-anchor as each <img> fires `load` (plus a
       few rAF passes), up to a 5s cap. We stop the moment the user
       scrolls intentionally — userScrolledFeed is set by the scroll
       listener only outside our armScrollSuppress windows, so layout
       growth from image decode (which moves the bottom without moving
       scrollTop) doesn't get misread as a user scroll. */
    if(focusEl) stabilizeOn(focusEl, anchorOnFocus);
    else if(anchorToBottom) stabilizeOn(null, anchorOnBottom);
  }
  function anchorOnFocus(el){
    if(userScrolledFeed) return false;
    armedScroll(function(){ el.scrollIntoView({block:'center',behavior:'auto'}); });
    return true;
  }
  function anchorOnBottom(){
    if(userScrolledFeed) return false;
    toBottom();
    return true;
  }
  function stabilizeOn(focusEl, reapply){
    var stopAt=Date.now()+5000;
    function fire(){
      if(Date.now()>stopAt) return;
      reapply(focusEl); /* if it returns false, we just stop calling — image listeners are once-only */
    }
    var imgs=bubbles.querySelectorAll('img');
    for(var i=0;i<imgs.length;i++){
      if(!imgs[i].complete){
        imgs[i].addEventListener('load', fire, {once:true});
        imgs[i].addEventListener('error', fire, {once:true});
      }
    }
    /* Two rAF passes catch non-image layout settling (font load, etc.). */
    requestAnimationFrame(function(){ fire(); requestAnimationFrame(fire); });
  }
  var es=new EventSource(SESSION_BASE+'/stream?since=0');
  /* Back/forward can restore this page from the bfcache — frozen, including
     these SSE streams, which the browser tore down when it cached the page.
     A restored page would show a dead feed (no new messages, no notifications).
     So if we were restored from bfcache (pageshow persisted), reload to get
     live streams back. Open EventSources usually block bfcache outright (so
     back is a normal reload that reconnects + replays the backlog); this is the
     belt-and-suspenders for browsers that cache anyway. */
  window.addEventListener('pageshow', function(e){ if(e.persisted) location.reload(); });
  es.addEventListener('backlog-size', function(e){
    /* Reset per-connection: fires on initial load AND on every reconnect. */
    wasCaughtUpAtBacklogStart=caughtUp();
    inBacklog=true; backlogSeen=0;
    backlogSize=parseInt(e.data,10) || 0;
    if(backlogSize===0) finishBacklog(); /* nothing to wait for */
  });
  es.onmessage=function(e){
    var m=JSON.parse(e.data);
    if(inBacklog){
      addMessage(m);
      backlogSeen++;
      if(backlogSize!==null && backlogSeen>=backlogSize) finishBacklog();
      return; /* skip per-message scroll/select/refresh during backlog */
    }
    /* Live path: capture caughtUp BEFORE the append (the just-arrived
       bubble is by definition off-screen until we scroll to it, so a
       post-append check would always read false). */
    var stick=caughtUp();
    addMessage(m);
    if(stick){
      toBottom();
      /* Same as finishBacklog's anchor-to-bottom path: when the feed
         anchors to the bottom, the cursor should land on the newest
         message — not on the topmost-fully-in-view that syncSelection-
         ToScroll would pick. Debounced commit so a burst of incoming
         messages doesn't flood the back/forward stack. */
      var msgs=visibleMsgs();
      if(msgs.length) selectAndCommit(msgs[msgs.length-1], false);
    } else {
      syncSelectionToScroll();
    }
    if(pendingCid&&m.cid===pendingCid) ackSend(); /* our message round-tripped: saved + echoed */
    if(ChatSearch.isOpen()) ChatSearch.refreshIfOpen(); /* keep an open search current as messages stream in */
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
    fetch(SESSION_BASE+'/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'body='+encodeURIComponent(text)+'&cid='+encodeURIComponent(cid)
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
     the source first so Back returns there. If the ref points at a message
     in ANOTHER session (id prefix differs from current SESSION), we
     full-page navigate to that session — the receiving page's wantFocusID
     path (location.hash → scroll+select after backlog) finishes the trip.
     MPA-style; cross-session refs are uncommon enough that a page load
     isn't worth avoiding. */
  function navigateRef(ref){
    var hashTarget=ref.getAttribute('href').replace(/^#/, '');
    var tgt=document.getElementById(hashTarget);
    if(tgt){
      armedScroll(function(){ tgt.scrollIntoView({block:'center',behavior:'auto'}); });
      selectAndCommit(tgt,true);
      return;
    }
    /* Parse <session-id>_<n> out of msg-<id>; session is everything
       before the LAST underscore (session-ids may contain hyphens but
       no underscores by construction). */
    var id=hashTarget.replace(/^msg-/, '');
    var cut=id.lastIndexOf('_');
    if(cut<=0) return;
    var targetSession=id.substring(0,cut);
    if(targetSession===SESSION) return; /* same session, target just missing — give up */
    location.href='/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(targetSession)+'#msg-'+id;
  }
  function scrollIndexToTop(idx){
    if(idx===null||idx===undefined) return null;
    var el=bubbles.querySelector('.chat-msg[data-i="'+idx+'"]');
    if(!el||el.offsetParent===null) return null;
    el.scrollIntoView({block:'start',behavior:'auto'});
    return el;
  }
  /* Navigate to entries[pos] without recording it, so ←/→ don't create new
     history themselves (and the scroll they trigger is suppressed). */
  function goToEntry(){
    if(pos<0) return;
    var el; armedScroll(function(){ el=scrollIndexToTop(entries[pos]); }); if(el) selectMsg(el);
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
    var eb=t.closest&&t.closest('.msg-edit');
    if(eb){ var emm=eb.closest('.chat-msg'); if(emm) editMessage(emm); return; }
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
    selectAndCommit(msgs[idx],false); armedScroll(function(){ revealInFeed(msgs[idx]); }); updateNav();
  }
  /* Jump cursor + feed to the very top (bottom=false) or bottom (bottom=true). */
  function cursorToExtreme(bottom){
    armedScroll(function(){ history.scrollTop=bottom?history.scrollHeight:0; });
    var msgs=visibleMsgs(); if(!msgs.length) return;
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
  /* The search modal (~180 lines) moved to chat_search.js so the feed
     code reads in isolation; chat.js hands it the shared helpers + DOM
     refs at init time. The cross-session notification feed + favicon-
     tab-alert is in notify.js (loaded as a third sibling on this and
     every other chat-subsystem page). */
  ChatSearch.init({
    bubbles: bubbles, history: history,
    selectAndCommit: selectAndCommit, armedScroll: armedScroll,
    scrollToIndex: scrollToIndex, updateNav: updateNav, idxOf: idxOf,
    hitInBody: hitInBody, openHitMedia: openHitMedia,
  });
  /* The left sidebar (Conversations / Pinned / Sessions / Add Topic
     form + pointer drag-to-pin) moved to chat_left_sidebar.js. Its
     only dep on chat.js is CONV (POST URLs), handed over here. */
  ChatLeftSidebar.init({ conv: CONV });
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
      case '/': e.preventDefault(); ChatSearch.open(); return;
      case 'q': if(selected){ e.preventDefault(); quoteReply(selected); } return;
      case 'r': if(selected){ e.preventDefault(); referReply(selected); } return;
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
