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
  var backBtn=document.getElementById('chat-back');
  var fwdBtn=document.getElementById('chat-fwd');

  /* ===== Message tracking — parallel to MessageView's bubble list =====
     PRODUCT_DECISION: chat.js holds Message instances so it can look them up
     by id (for "Edit of MSG_<id>" supersession + same-session navigateRef
     targets). msg.getIndex() is server-assigned 0-based; view index is
     1-based; the two are kept consistent because we always append in order. */
  var messages = [];
  function findById(id){
    for(var i = 0; i < messages.length; i++){
      if(messages[i].getId() === id) return messages[i];
    }
    return null;
  }

  /* ===== domain actions (called from Message clicks AND ChatHelp keys) ===== */
  function doQuote(msg){
    if(ChatCompose.isPending()) return;
    view.focusBubble(msg.getIndex() + 1);
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor(
      'In MSG_'+msg.getId()+' '+(msg.isMine()?'I said':'you said')+
      ':\n~~~ quote\n'+msg.getBody()+'\n~~~\n\n'
    );
  }
  function doRefer(msg){
    if(ChatCompose.isPending()) return;
    view.focusBubble(msg.getIndex() + 1);
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor('See MSG_'+msg.getId()+' ');
  }
  /* PRODUCT_DECISION: Edit composes a NEW message with an "Edit of MSG_<hash>"
     backlink and the caret at the start of the original body. Append-only +
     transparent — no copy/paste, the backlink wires the relation. */
  function doEdit(msg){
    if(ChatCompose.isPending()) return;
    view.focusBubble(msg.getIndex() + 1);
    var prefix='Edit of MSG_'+msg.getId()+'\n\n';
    ChatRightSidebar.openCompose();
    ChatCompose.setBody(prefix+msg.getBody(), prefix.length);
  }

  /* ===== cross-session vs same-session MSG_ ref navigation =====
     PRODUCT_DECISION: cross-session refs open in a new tab — the source tab
     stays parked, no nav-stack to engineer. Same-session refs scroll +
     select via view.focusBubble. */
  function navigateRef(refEl){
    var hashTarget=refEl.getAttribute('href').replace(/^#/, '');
    var id=hashTarget.replace(/^msg-/, '');
    var cut=id.lastIndexOf('_');
    if(cut<=0) return;
    var targetSession=id.substring(0,cut);
    if(targetSession===SESSION){
      var msg=findById(id);
      if(msg) view.focusBubble(msg.getIndex() + 1);
      return;
    }
    window.open('/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(targetSession)+'#msg-'+id, '_blank');
  }

  /* ===== nav stack — instantiated AFTER `view` is created (below) =====
     The state-machine itself lives in chat/nav_stack.js. chat.js wires
     the three bindings: walk (consume = view.focusBubble), onChange
     (UI = back/fwd button enable), currentSelection (drift = the live
     view selection). Click/link jumps commit immediately; settling
     debounces 700ms before pushing (MessageView's setSelectedBubble). */
  var nav;

  /* ===== "is the feed scrolled to the bottom" =====
     PRODUCT_DECISION: works across both rendered + transcript views (queries
     [data-i] on #chat-history). True when empty so first messages stick. */
  function caughtUp(){
    var els=history.querySelectorAll('[data-i]');
    for(var i=els.length-1;i>=0;i--){
      if(els[i].offsetParent===null) continue; /* BROWSER_WORKAROUND: offsetParent===null skips the hidden view. */
      return els[i].getBoundingClientRect().bottom<=history.getBoundingClientRect().bottom+1;
    }
    return true;
  }

  /* ===== view switching (rendered / transcript) =====
     PRODUCT_DECISION: anchor scrolling on the same MESSAGE across view
     switches. We capture the topmost data-i BEFORE the view change
     (matching across both bubble + transcript spans, since both have
     data-i), then scroll the NEW view's element with that data-i to
     the top. */
  function setView(v){
    var htop=history.getBoundingClientRect().top;
    var anchorIdx=null;
    var probes=history.querySelectorAll('[data-i]');
    for(var i=0;i<probes.length;i++){
      if(probes[i].offsetParent===null) continue;
      if(probes[i].getBoundingClientRect().bottom>htop+1){ anchorIdx=probes[i].getAttribute('data-i'); break; }
    }
    history.className='chat-history view-'+v;
    var links=views.querySelectorAll('a');
    for(var i=0;i<links.length;i++){ links[i].className=(links[i].getAttribute('data-view')===v)?'active':''; }
    if(anchorIdx!==null){ // lint:null-undefined-check anchorIdx-null-when-feed-empty
      var targets=history.querySelectorAll('[data-i="'+anchorIdx+'"]');
      for(var j=0;j<targets.length;j++){
        if(targets[j].offsetParent===null) continue;
        history.scrollTop+=targets[j].getBoundingClientRect().top-history.getBoundingClientRect().top;
        break;
      }
    }
  }
  function toggleView(){ setView(history.className.indexOf('view-transcript')>=0?'rendered':'transcript'); }
  views.addEventListener('click',function(e){
    var a=e.target.closest('a[data-view]'); if(!a) return;
    e.preventDefault(); setView(a.getAttribute('data-view'));
  });

  /* ===== MessageView setup ===== */
  var view = MessageView.create({
    container: history,
    list:      bubbles,
    renderBubble: function(idx, m){
      var msg = Message.create(m, {
        onQuote:  doQuote,
        onRefer:  doRefer,
        onEdit:   doEdit,
        onMsgRef: navigateRef,
      });
      messages.push(msg);
      return msg.render();
    },
    setSelectedBubble: function(idx){
      if(idx<=0) return;
      var msg=messages[idx-1];
      if(!msg) return;
      /* BROWSER_WORKAROUND: window.history — chat.js shadows the global `history`
         with the #chat-history DOM element near the top of this IIFE. */
      window.history.replaceState({}, '', '#msg-'+msg.getId());
      nav.push(idx);
    },
  });

  /* ===== nav stack instantiation + back / forward bindings ===== */
  nav = NavStack.create({
    gotoMessage:      function(idx){ view.focusBubble(idx, {silent:true}); },
    onChange:         function(canBack, canFwd){ backBtn.disabled=!canBack; fwdBtn.disabled=!canFwd; },
    currentSelection: view.getSelected,
  });
  backBtn.addEventListener('click', nav.back);
  fwdBtn.addEventListener('click', nav.forward);

  /* ===== one append wraps view + transcript + supersession + empty-removal =====
     PRODUCT_DECISION: transcript span — literal on-disk block, sibling DOM tree
     to #chat-bubbles inside #chat-history; managed directly here because
     MessageView is rectangle-list-only. EDIT_RE supersession: a body starting
     with "Edit of MSG_<hash>" causes the original Message to redraw in-place;
     append-only on disk, only the rendered view changes. */
  var EDIT_RE=/^Edit of MSG_([A-Za-z0-9-]+_[0-9]+)\b/;
  function appendMessage(m){
    var empty=document.getElementById('chat-empty'); if(empty) empty.remove();
    view.append(m);
    var span=document.createElement('span');
    span.setAttribute('data-i', m.index); span.textContent=m.enc;
    transcript.appendChild(span);
    var em=(m.body||'').match(EDIT_RE);
    if(em){ var orig=findById(em[1]); if(orig) orig.markEdited(m.id); }
  }

  /* ===== entry-point fragment (#msg-<id>) ===== */
  /* PRODUCT_DECISION: #msg-<hash> fragments (e.g. from Docs' Post-to-chat) get
     remembered, then consumed by endBacklog once the backlog has landed. */
  var wantFocusID=(function(){
    var m=(location.hash||'').match(/^#msg-([A-Za-z0-9_-]+)$/);
    return m ? m[1] : null;
  })();

  /* ===== SSE stream + backlog batch mode ===== */
  var es=new EventSource(SESSION_BASE+'/stream?since=0');
  /* BROWSER_WORKAROUND: bfcache restores frozen pages including torn-down SSE
     streams. Open EventSources usually block bfcache outright, but this is
     belt-and-suspenders for browsers that cache anyway. */
  window.addEventListener('pageshow', function(e){ if(e.persisted) location.reload(); });

  var inBacklog=false, backlogSize=0, backlogSeen=0;
  var wasCaughtUpAtBacklogStart=true;

  function finishBacklog(){
    inBacklog=false;
    var opts={};
    if(wantFocusID){
      var msg=findById(wantFocusID);
      wantFocusID=null;
      if(msg) opts.focusIdx=msg.getIndex()+1;
    } else if(wasCaughtUpAtBacklogStart){
      opts.anchor='bottom';
    }
    view.endBacklog(opts);
  }

  es.addEventListener('backlog-size', function(e){
    /* PRODUCT_DECISION: per-connection reset — fires on initial load AND every reconnect. */
    wasCaughtUpAtBacklogStart=caughtUp();
    inBacklog=true; backlogSeen=0;
    backlogSize=parseInt(e.data,10) || 0;
    view.startBacklog(backlogSize);
    if(backlogSize===0) finishBacklog();
  });

  es.onmessage=function(e){
    var m=JSON.parse(e.data);
    if(inBacklog){
      appendMessage(m);
      backlogSeen++;
      if(backlogSize!==null && backlogSeen>=backlogSize) finishBacklog(); // lint:null-undefined-check backlogSize-null-until-preamble-arrives
      return;
    }
    /* PRODUCT_DECISION: capture caughtUp BEFORE the append — the just-arrived
       bubble is off-screen until we scroll, so a post-append check always reads false. */
    var stick=caughtUp();
    appendMessage(m);
    if(stick){
      /* PRODUCT_DECISION: scroll to bottom + select the LAST message (debounced).
         cursorToExtreme(true) with stick→false would record-too-fast on a burst. */
      view.cursorToExtreme(true);
    }
    if(m.cid) ChatCompose.ackIfPending(m.cid); /* PRODUCT_DECISION: our message round-tripped (saved + echoed). */
    if(ChatSearch.isOpen()) ChatSearch.refreshIfOpen();
  };

  /* ===== sibling module wiring ===== */
  ChatSearch.init({
    bubbles: bubbles, history: history,
    jumpToEl: function(el){
      /* PRODUCT_DECISION: search holds the original feed bubble; translate
         data-id back to its Message + view-idx and focus. */
      var id=el && el.getAttribute && el.getAttribute('data-id');
      var msg=id ? findById(id) : null;
      if(msg) view.focusBubble(msg.getIndex()+1);
    },
  });
  ChatLeftSidebar.init({ conv: CONV });
  ChatCompose.init({
    sessionBase: SESSION_BASE,
    closeCompose: ChatRightSidebar.closeCompose,
  });
  /* PRODUCT_DECISION: chat.js opens compose for quote/refer/edit; chat_help opens
     for the "c" keybind; compose closes itself on Esc-empty. */
  ChatRightSidebar.init({
    onOpen:  function(){ ChatCompose.focus(); },
    onClose: function(){ history.focus({preventScroll:true}); },
  });
  /* PRODUCT_DECISION: keys map 1:1 to the chat-keyhelp panel on the closed-compose side.
     Arrow / Home / End / PgUp / PgDn are NOT here — MessageView owns those internally. */
  ChatHelp.init({
    openCompose: ChatRightSidebar.openCompose,
    backBtn:     backBtn,
    fwdBtn:      fwdBtn,
    toggleView:  toggleView,
    getSelectedMessage: function(){
      var idx=view.getSelected();
      return idx>0 ? messages[idx-1] : null;
    },
    quoteReply:  doQuote,
    referReply:  doRefer,
    editMessage: doEdit,
  });
  ChatCompose.focus();
})();
