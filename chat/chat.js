(function(){
  var root=document.getElementById('chat-root');
  var CONV=root.dataset.conv;
  var SESSION=root.dataset.session;
  /* PRODUCT_DECISION: API URL space mirrors disk layout under {ChatDataRoot}/<conv>/sessions/<sid>. */
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
  function toBottom(){ armedScroll(function(){ history.scrollTop=history.scrollHeight; }); }
  function caughtUp(){
    var els=history.querySelectorAll('[data-i]');
    for(var i=els.length-1;i>=0;i--){
      if(els[i].offsetParent===null) continue; /* BROWSER_WORKAROUND: offsetParent===null skips the hidden view (rendered vs transcript). */
      return els[i].getBoundingClientRect().bottom<=history.getBoundingClientRect().bottom+1;
    }
    return true; /* PRODUCT_DECISION: empty feed sticks, so first messages land at the bottom. */
  }
  /* PRODUCT_DECISION: nav-history has browser back/forward semantics. Click/link
     jumps commit immediately; scroll/arrow-driven changes debounce 700ms so
     scrolling past messages doesn't churn the trail. */
  var selected=null;
  function idxOf(el){ return el?el.getAttribute('data-i'):null; }
  function selectMsg(el){
    if(!el||el===selected) return;
    if(selected) selected.classList.remove('selected');
    selected=el; el.classList.add('selected');
  }
  var entries=[], pos=-1, commitTimer=null;
  function curEntry(){ return pos>=0?entries[pos]:null; }
  function drifted(){ return selected&&idxOf(selected)!==curEntry(); }
  function updateNav(){
    backBtn.disabled=!(pos>0||drifted()); /* PRODUCT_DECISION: drift enables ← as "recover to where I was". */
    fwdBtn.disabled=!(pos<entries.length-1);
  }
  function recordNav(idx){
    /* PRODUCT_DECISION: curEntry()=null when nav-history empty; ignore re-select. lint:null-undefined-check legit-absence-sentinel */
    if(idx===null||idx===curEntry()) return;
    entries.length=pos+1; /* PRODUCT_DECISION: drop the forward tail — fresh nav resets it. */
    entries.push(idx); pos=entries.length-1;
    updateNav();
  }
  function commitSelection(idx, immediate){
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; }
    if(immediate) recordNav(idx);
    else commitTimer=setTimeout(function(){ commitTimer=null; recordNav(idx); }, 700);
  }
  /* PRODUCT_DECISION: immediate=true for click/link jumps; false to debounce scroll/arrow changes. */
  function selectAndCommit(el, immediate){ if(el){ selectMsg(el); commitSelection(idxOf(el), immediate); } }
  function selectionCandidate(){
    var els=bubbles.querySelectorAll('.chat-msg'), hr=history.getBoundingClientRect();
    var beginningVisible=null, straddler=null;
    for(var i=0;i<els.length;i++){
      var el=els[i]; if(el.offsetParent===null) continue;
      var r=el.getBoundingClientRect();
      if(r.top>=hr.top-1 && r.bottom<=hr.bottom+1) return el; /* PRODUCT_DECISION: topmost fully in view. */
      if(!beginningVisible && r.top>=hr.top-1 && r.top<hr.bottom) beginningVisible=el; /* PRODUCT_DECISION: top edge shows. */
      if(!straddler && r.top<hr.top && r.bottom>hr.top) straddler=el; /* PRODUCT_DECISION: covers viewport top. */
    }
    return beginningVisible||straddler||null;
  }
  /* PRODUCT_DECISION: programmatic jumps suppress scroll-driven reselection until
     the scroll actually goes quiet (not for a fixed window) — a far jump animates
     past any time guess. armedScroll() bundles arm + scroll so call sites can't forget. */
  var progScroll=false, progScrollTimer=null;
  function endProgScroll(){ progScroll=false; progScrollTimer=null; }
  function armScrollSuppress(){
    progScroll=true;
    if(progScrollTimer) clearTimeout(progScrollTimer);
    progScrollTimer=setTimeout(endProgScroll, 150); /* PRODUCT_DECISION: re-armed by each scroll event below. */
  }
  function armedScroll(scroll){ armScrollSuppress(); scroll(); }
  function syncSelectionToScroll(){
    if(progScroll) return;
    var el=selectionCandidate();
    if(el && el!==selected){ selectAndCommit(el, false); updateNav(); }
  }
  /* BROWSER_WORKAROUND: image loads grow scrollHeight from under us, indistinguishable
     from a user scroll via scrollTop. progScroll is the source of truth: while set,
     scrolls are ours; outside that 150ms window, the user's. */
  var rafPending=false;
  var userScrolledFeed=false;
  history.addEventListener('scroll',function(){
    if(progScroll){
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
    div._body=m.body; /* PRODUCT_DECISION: keep raw markdown source on the element for quote-reply. */
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
    body.innerHTML=m.html; /* PRODUCT_DECISION: m.html is sanitized server-side. */
    div.appendChild(meta); div.appendChild(body);
    bubbles.appendChild(div);
    var span=document.createElement('span'); span.setAttribute('data-i',m.index);
    span.textContent=m.enc; transcript.appendChild(span); /* PRODUCT_DECISION: literal on-disk block for transcript view. */
    var em=(m.body||'').match(EDIT_RE);
    if(em){ var orig=document.getElementById('msg-'+em[1]); if(orig) markEdited(orig, m.id); }
  }
  /* PRODUCT_DECISION: a body starting with "Edit of MSG_<hash>" supersedes that
     original — render an "Edited in MSG_<this>" link there, demote its content
     to a spoiler. Append-only: the on-disk record stays untouched, only the
     rendered view changes (transcript still shows both byte-for-byte). */
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
    orig.textContent=origEl._body;
    spoiler.appendChild(orig);
    bodyEl.appendChild(note); bodyEl.appendChild(spoiler);
  }
  function referReply(el){
    if(!el||ChatCompose.isPending()) return;
    selectAndCommit(el,true);
    var hash=el.getAttribute('data-id');
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor('See MSG_'+hash+' ');
  }
  function quoteReply(el){
    if(!el||ChatCompose.isPending()) return; /* PRODUCT_DECISION: don't disturb a send awaiting its ack. */
    selectAndCommit(el,true);
    var hash=el.getAttribute('data-id'), mine=el.classList.contains('mine');
    var body=el._body;
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor('In MSG_'+hash+' '+(mine?'I said':'you said')+':\n~~~ quote\n'+body+'\n~~~\n\n');
  }
  /* PRODUCT_DECISION: Edit composes a NEW message with an "Edit of MSG_<hash>"
     backlink and the caret at the start of the original body. Append-only +
     transparent — no copy/paste, the backlink wires the relation. */
  function editMessage(el){
    if(!el||ChatCompose.isPending()) return;
    selectAndCommit(el,true);
    var prefix='Edit of MSG_'+el.getAttribute('data-id')+'\n\n';
    ChatRightSidebar.openCompose();
    ChatCompose.setBody(prefix+el._body, prefix.length); /* PRODUCT_DECISION: caret at the start of the original content. */
  }
  /* PRODUCT_DECISION: anchor scrolling on the same MESSAGE across view switches
     (rendered/raw/transcript). topIndex captures the currently-topmost data-i,
     scrollToIndex brings it back after the layout changes. */
  function topIndex(){
    var els=history.querySelectorAll('[data-i]'), htop=history.getBoundingClientRect().top;
    for(var i=0;i<els.length;i++){
      if(els[i].offsetParent===null) continue;
      if(els[i].getBoundingClientRect().bottom>htop+1) return els[i].getAttribute('data-i');
    }
    return null;
  }
  function scrollToIndex(idx){
    if(idx===null) return; // lint:null-undefined-check topIndex-returns-null-on-empty-feed
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
  /* PRODUCT_DECISION: #msg-<hash> fragments (e.g. from Docs' Post-to-chat) get
     remembered, then consumed by finishBacklog once the backlog has landed. */
  var wantFocusID=(function(){
    var m=(location.hash||'').match(/^#msg-([A-Za-z0-9_-]+)$/);
    return m ? m[1] : null;
  })();
  /* PRODUCT_DECISION: backlog phase batches DOM-only appends to skip per-message
     scroll/select/refresh — 1000-message conversations crawled without this.
     One final scroll happens in finishBacklog. The same path runs on EventSource
     reconnects (server re-sends preamble + post-Last-Event-ID slice). */
  var inBacklog=true, backlogSize=null, backlogSeen=0;
  var wasCaughtUpAtBacklogStart=true;
  function finishBacklog(){
    inBacklog=false;
    var focusEl=null, anchorToBottom=false;
    if(wantFocusID){
      focusEl=document.getElementById('msg-'+wantFocusID);
      wantFocusID=null; /* PRODUCT_DECISION: consumed; reconnect backlogs fall through to caughtUp. */
    } else if(wasCaughtUpAtBacklogStart){
      anchorToBottom=true;
    }
    /* PRODUCT_DECISION: from here on only INTENTIONAL post-anchor user scrolls
       stop the stabilizer. armScrollSuppress on every programmatic scroll keeps
       our own activity from tripping it. */
    userScrolledFeed=false;
    if(focusEl){
      armedScroll(function(){ focusEl.scrollIntoView({block:'center',behavior:'auto'}); });
      selectAndCommit(focusEl,true);
    } else if(anchorToBottom){
      toBottom();
      /* PRODUCT_DECISION: explicit pick of the LAST message, mirroring End-key path.
         syncSelectionToScroll would pick topmost-fully-in-view — wrong when the
         user just landed at the bottom. */
      var msgs=visibleMsgs();
      if(msgs.length) selectAndCommit(msgs[msgs.length-1], true);
    } else {
      /* PRODUCT_DECISION: reconnect case — keep whatever scroll/selection the user had. */
      syncSelectionToScroll();
    }
    /* BROWSER_WORKAROUND: image decode grows scrollHeight without moving scrollTop,
       so we re-anchor on each <img> load (plus a couple rAF passes), up to 5s.
       userScrolledFeed is set only outside our armScrollSuppress window, so
       layout growth from image decode doesn't get misread as a user scroll. */
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
      reapply(focusEl); /* PRODUCT_DECISION: returning false stops calls — image listeners are once-only. */
    }
    var imgs=bubbles.querySelectorAll('img');
    for(var i=0;i<imgs.length;i++){
      if(!imgs[i].complete){
        imgs[i].addEventListener('load', fire, {once:true});
        imgs[i].addEventListener('error', fire, {once:true});
      }
    }
    /* BROWSER_WORKAROUND: two rAF passes catch non-image layout settling (font load, etc.). */
    requestAnimationFrame(function(){ fire(); requestAnimationFrame(fire); });
  }
  var es=new EventSource(SESSION_BASE+'/stream?since=0');
  /* BROWSER_WORKAROUND: bfcache restores frozen pages including the torn-down
     SSE streams (dead feed, no live messages). Open EventSources usually block
     bfcache outright, but this is belt-and-suspenders for browsers that cache anyway. */
  window.addEventListener('pageshow', function(e){ if(e.persisted) location.reload(); });
  es.addEventListener('backlog-size', function(e){
    /* PRODUCT_DECISION: per-connection reset — fires on initial load AND every reconnect. */
    wasCaughtUpAtBacklogStart=caughtUp();
    inBacklog=true; backlogSeen=0;
    backlogSize=parseInt(e.data,10) || 0;
    if(backlogSize===0) finishBacklog();
  });
  es.onmessage=function(e){
    var m=JSON.parse(e.data);
    if(inBacklog){
      addMessage(m);
      backlogSeen++;
      if(backlogSize!==null && backlogSeen>=backlogSize) finishBacklog(); // lint:null-undefined-check backlogSize-null-until-preamble-arrives
      return;
    }
    /* PRODUCT_DECISION: capture caughtUp BEFORE the append — the just-arrived
       bubble is off-screen until we scroll, so a post-append check always reads false. */
    var stick=caughtUp();
    addMessage(m);
    if(stick){
      toBottom();
      /* PRODUCT_DECISION: pick the LAST message (not syncSelectionToScroll's
         topmost-fully-in-view). Debounced commit so a burst doesn't flood the
         back/forward stack. */
      var msgs=visibleMsgs();
      if(msgs.length) selectAndCommit(msgs[msgs.length-1], false);
    } else {
      syncSelectionToScroll();
    }
    if(m.cid) ChatCompose.ackIfPending(m.cid); /* PRODUCT_DECISION: our message round-tripped (saved + echoed). */
    if(ChatSearch.isOpen()) ChatSearch.refreshIfOpen();
  };
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
    /* PRODUCT_DECISION: fitW/fitH = largest size that fits the fixed container
       (computed once natural + container sizes are known); the slider multiplies. */
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
  function showCodePopup(text){
    var dlg=document.createElement('dialog'); dlg.className='chat-code-dialog';
    var controls=document.createElement('div'); controls.className='chat-code-controls';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click',function(){ dlg.close(); });
    controls.appendChild(close);
    var pre=document.createElement('pre'); pre.className='chat-code-view'; pre.textContent=text;
    dlg.appendChild(controls); dlg.appendChild(pre);
    /* PRODUCT_DECISION: dialog is fit-content (CSS) capped at 80vw/80vh; the <pre>
       scrolls when the code is larger. */
    dlg.addEventListener('close',function(){ dlg.remove(); });
    dlg.addEventListener('click',function(e){ if(e.target===dlg) dlg.close(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }
  /* PRODUCT_DECISION: shared click classifier so every body-rendering surface
     (feed, search results) has ONE notion of "what did you click" and only
     decides what differs. */
  function hitInBody(t){
    if(t.tagName==='IMG') return {kind:'image', src:t.src};
    var pre=t.closest&&t.closest('pre'); if(pre) return {kind:'pre', text:pre.textContent};
    if(t.closest&&t.closest('a.msg-ref')) return {kind:'msgref', el:t.closest('a.msg-ref')};
    if(t.closest&&t.closest('a')) return {kind:'link'}; /* PRODUCT_DECISION: external link, server-baked target=_blank, no JS needed. */
    return {kind:'plain'};
  }
  /* BROWSER_WORKAROUND: native <dialog>s stack — popups opened over the search
     modal close back to it. Returns true if the hit was handled. */
  function openHitMedia(hit){
    if(hit.kind==='image'){ showImagePopup(hit.src); return true; }
    if(hit.kind==='pre'){ showCodePopup(hit.text); return true; }
    return false;
  }
  /* PRODUCT_DECISION: MSG_ refs whose target lives in another session full-page
     navigate, MPA-style. The receiving page's wantFocusID path finishes the trip
     via location.hash. Cross-session refs are rare enough that the page load
     isn't worth avoiding. */
  function navigateRef(ref){
    var hashTarget=ref.getAttribute('href').replace(/^#/, '');
    var tgt=document.getElementById(hashTarget);
    if(tgt){
      armedScroll(function(){ tgt.scrollIntoView({block:'center',behavior:'auto'}); });
      selectAndCommit(tgt,true);
      return;
    }
    /* PRODUCT_DECISION: parse <session>_<n> out of msg-<id>; session is everything
       before the LAST underscore (session ids may contain hyphens but no
       underscores by construction). */
    var id=hashTarget.replace(/^msg-/, '');
    var cut=id.lastIndexOf('_');
    if(cut<=0) return;
    var targetSession=id.substring(0,cut);
    if(targetSession===SESSION) return; /* PRODUCT_DECISION: same session but target missing — give up. */
    location.href='/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(targetSession)+'#msg-'+id;
  }
  function scrollIndexToTop(idx){
    var el=bubbles.querySelector('.chat-msg[data-i="'+idx+'"]');
    if(!el||el.offsetParent===null) return null;
    el.scrollIntoView({block:'start',behavior:'auto'});
    return el;
  }
  function goToEntry(){
    if(pos<0) return;
    var el; armedScroll(function(){ el=scrollIndexToTop(entries[pos]); }); if(el) selectMsg(el);
    updateNav();
  }
  /* PRODUCT_DECISION: ← walks the committed trail. If drifted, the first press
     recovers entries[pos] (and drops the pending commit, so the forward tail
     survives); from there each press steps back. → redoes a back. */
  backBtn.addEventListener('click',function(){
    if(commitTimer){ clearTimeout(commitTimer); commitTimer=null; }
    if(drifted()){ goToEntry(); return; }
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
    var msg=t.closest&&t.closest('.chat-msg'); /* PRODUCT_DECISION: any click on a bubble selects it (image / pre / MSG_ ref included). */
    if(msg) selectAndCommit(msg,true);
    var hit=hitInBody(t);
    if(hit.kind==='msgref'){ e.preventDefault(); navigateRef(hit.el); return; }
    openHitMedia(hit);
  });
  function visibleMsgs(){
    var out=[], els=bubbles.querySelectorAll('.chat-msg');
    for(var i=0;i<els.length;i++) if(els[i].offsetParent!==null) out.push(els[i]);
    return out;
  }
  /* PRODUCT_DECISION: scroll only the feed (never the page), with a pad below so
     the selected-border isn't clipped and the next bubble peeks through.
     Taller-than-window: pin top instead. */
  function revealInFeed(el){
    var hr=history.getBoundingClientRect(), r=el.getBoundingClientRect();
    var padBot=48; /* PRODUCT_DECISION: selected-border + peek of next bubble. */
    var padTop=6;  /* PRODUCT_DECISION: breathing room above the top selected-border. */
    if(r.top<hr.top+padTop) history.scrollTop+=r.top-hr.top-padTop;
    else if(r.bottom>hr.bottom-padBot){
      var delta=r.bottom-(hr.bottom-padBot);
      if(r.top-delta<hr.top+padTop) delta=r.top-hr.top-padTop; /* PRODUCT_DECISION: taller than window — pin top. */
      history.scrollTop+=delta;
    }
  }
  function moveCursor(delta){
    var msgs=visibleMsgs();
    if(!msgs.length){ history.scrollTop+=delta*40; return; } /* PRODUCT_DECISION: transcript view — just scroll. */
    var idx=selected?msgs.indexOf(selected):-1;
    if(idx<0){ var c=selectionCandidate(); idx=c?msgs.indexOf(c):0; if(idx<0) idx=0; }
    else idx=Math.max(0,Math.min(msgs.length-1,idx+delta));
    selectAndCommit(msgs[idx],false); armedScroll(function(){ revealInFeed(msgs[idx]); }); updateNav();
  }
  function cursorToExtreme(bottom){
    armedScroll(function(){ history.scrollTop=bottom?history.scrollHeight:0; });
    var msgs=visibleMsgs(); if(!msgs.length) return;
    selectAndCommit(bottom?msgs[msgs.length-1]:msgs[0],true); updateNav();
  }
  /* PRODUCT_DECISION: PgUp/PgDn pages the feed if scrollable; if not, sends the cursor to the extreme. */
  function pageNav(dir){
    var canScroll=dir<0 ? history.scrollTop>0
                        : history.scrollTop+history.clientHeight<history.scrollHeight-1;
    if(canScroll) history.scrollTop+=dir*Math.max(40,history.clientHeight-40);
    else cursorToExtreme(dir>0);
  }
  ChatSearch.init({
    bubbles: bubbles, history: history,
    selectAndCommit: selectAndCommit, armedScroll: armedScroll,
    scrollToIndex: scrollToIndex, updateNav: updateNav, idxOf: idxOf,
    hitInBody: hitInBody, openHitMedia: openHitMedia,
  });
  ChatLeftSidebar.init({ conv: CONV });
  /* PRODUCT_DECISION: chat.js opens compose for quote/refer/edit; chat_help opens
     for the "c" keybind; compose closes itself on Esc-empty. */
  ChatRightSidebar.init({
    composeBody: composeBody, closedPanel: closedPanel,
    textarea: textarea, history: history,
  });
  ChatCompose.init({
    textarea: textarea, form: form, status: status,
    imageBtn: imageBtn, fileInput: fileInput,
    sessionBase: SESSION_BASE,
    closeCompose: ChatRightSidebar.closeCompose,
  });
  /* PRODUCT_DECISION: keys map 1:1 to the chat-keyhelp panel on the closed-compose side. */
  ChatHelp.init({
    openCompose: ChatRightSidebar.openCompose,
    backBtn: backBtn, fwdBtn: fwdBtn,
    toggleView: toggleView,
    getSelected: function(){ return selected; },
    quoteReply: quoteReply, referReply: referReply, editMessage: editMessage,
    moveCursor: moveCursor, cursorToExtreme: cursorToExtreme, pageNav: pageNav,
  });
  textarea.focus();
})();
