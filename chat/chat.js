(function(){
  var root=document.getElementById('chat-root');
  var CONV=root.dataset.conv;
  var SESSION=root.dataset.session;
  /* PRODUCT_DECISION: API URL space mirrors disk layout under {ChatDataRoot}/<conv>/sessions/<sid>. */
  var SESSION_BASE='/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(SESSION);

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

  /* ===== domain actions (called from Message clicks AND ChatHelp keys) =====
     PRODUCT_DECISION: doQuote/doRefer/doEdit/navigateRef call pane.focusBubble,
     which is captured by closure from the var pane below. The actions are
     CALLED later (from Message instances built inside the pane's renderBubble
     callback), so the forward reference is safe. */
  var pane;

  function doQuote(msg){
    if(ChatCompose.isPending()) return;
    pane.focusBubble(msg.getIndex() + 1);
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor(
      'In MSG_'+msg.getId()+' '+(msg.isMine()?'I said':'you said')+
      ':\n~~~ quote\n'+msg.getMarkdown()+'\n~~~\n\n'
    );
  }
  function doRefer(msg){
    if(ChatCompose.isPending()) return;
    pane.focusBubble(msg.getIndex() + 1);
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor('See MSG_'+msg.getId()+' ');
  }
  /* PRODUCT_DECISION: Edit composes a NEW message with an "Edit of MSG_<hash>"
     backlink and the caret at the start of the original body. Append-only +
     transparent — no copy/paste, the backlink wires the relation. */
  function doEdit(msg){
    if(ChatCompose.isPending()) return;
    pane.focusBubble(msg.getIndex() + 1);
    var prefix='Edit of MSG_'+msg.getId()+'\n\n';
    ChatRightSidebar.openCompose();
    ChatCompose.setMarkdown(prefix+msg.getMarkdown(), prefix.length);
  }

  /* ===== cross-session vs same-session MSG_ ref navigation =====
     PRODUCT_DECISION: cross-session refs open in a new tab — the source tab
     stays parked, no nav-stack to engineer. Same-session refs scroll +
     select via pane.focusBubble. */
  function navigateRef(refEl){
    var hashTarget=refEl.getAttribute('href').replace(/^#/, '');
    var id=hashTarget.replace(/^msg-/, '');
    var cut=id.lastIndexOf('_');
    if(cut<=0) return;
    var targetSession=id.substring(0,cut);
    if(targetSession===SESSION){
      var msg=findById(id);
      if(msg) pane.focusBubble(msg.getIndex() + 1);
      return;
    }
    window.open('/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(targetSession)+'#msg-'+id, '_blank');
  }

  /* ===== middle pane — owns wrapper + navbar + back/fwd + history + bubbles ===== */
  pane = ChatMiddlePane.init({
    mount: document.getElementById('chat-feed'),
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
    onSelect: function(idx){
      var msg=messages[idx-1];
      if(!msg) return;
      /* BROWSER_WORKAROUND: window.history — chat.js shadows the global `history`
         with the #chat-history DOM element near the top of this IIFE. */
      window.history.replaceState({}, '', '#msg-'+msg.getId());
    },
  });

  /* ===== one append wraps view + supersession + empty-removal =====
     EDIT_RE: markdown starting with "Edit of MSG_<hash>" causes the original
     Message to redraw in-place; append-only on disk, only the rendered view
     changes. */
  /* PRODUCT_DECISION: empty-state placeholder is a chat-page convention
     (the colored-bubbles demo doesn't want one), so chat.js seeds it
     into pane.bubbles itself and removes it on first append. */
  (function(){
    var empty = document.createElement('p');
    empty.id = 'chat-empty';
    empty.className = 'muted';
    empty.textContent = 'No messages yet. Say hello 👋';
    pane.bubbles.appendChild(empty);
  })();

  var EDIT_RE=/^Edit of MSG_([A-Za-z0-9-]+_[0-9]+)\b/;
  function appendMessage(m){
    var empty=document.getElementById('chat-empty'); if(empty) empty.remove();
    pane.append(m);
    var em=(m.markdown||'').match(EDIT_RE);
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
    pane.endBacklog(opts);
  }

  es.addEventListener('backlog-size', function(e){
    /* PRODUCT_DECISION: per-connection reset — fires on initial load AND every reconnect. */
    wasCaughtUpAtBacklogStart=pane.caughtUp();
    inBacklog=true; backlogSeen=0;
    backlogSize=parseInt(e.data,10) || 0;
    pane.startBacklog(backlogSize);
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
    var stick=pane.caughtUp();
    appendMessage(m);
    if(stick){
      /* PRODUCT_DECISION: scroll to bottom + select the LAST message (debounced).
         cursorToExtreme(true) with stick→false would record-too-fast on a burst. */
      pane.cursorToExtreme(true);
    }
    if(m.cid){
      /* PRODUCT_DECISION: our message round-tripped (saved + echoed). The
         status-bar ping doubles as a self-test for #chat-notify — every
         send exercises the same DOM target the other-conv ping uses, so
         a regression there shows up the next time you talk to anyone. */
      ChatCompose.ackIfPending(m.cid);
      ChatNotify.show('✓ '+m.id+' sent');
    }
    if(ChatSearch.isOpen()) ChatSearch.refreshIfOpen();
  };

  /* ===== sibling module wiring ===== */
  ChatSearch.init({
    bubbles:   pane.bubbles,
    navbar:    pane.navbar,
    focusFeed: pane.focus,
    jumpToEl: function(el){
      /* PRODUCT_DECISION: search holds the original feed bubble; translate
         data-id back to its Message + view-idx and focus. */
      var id=el && el.getAttribute && el.getAttribute('data-id');
      var msg=id ? findById(id) : null;
      if(msg) pane.focusBubble(msg.getIndex()+1);
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
    onClose: pane.focus,
  });
  /* PRODUCT_DECISION: keys map 1:1 to the chat-keyhelp panel on the closed-compose side.
     Arrow / Home / End / PgUp / PgDn are NOT here — MessageView owns those internally. */
  ChatHelp.init({
    openCompose: ChatRightSidebar.openCompose,
    back:        pane.back,
    forward:     pane.forward,
    getSelectedMessage: function(){
      var idx=pane.getSelected();
      return idx>0 ? messages[idx-1] : null;
    },
    quoteReply:  doQuote,
    referReply:  doRefer,
    editMessage: doEdit,
  });
  ChatCompose.focus();
})();
