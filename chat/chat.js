(function(){
  var root=document.getElementById('chat-root');
  var CONV=root.dataset.conv;
  var SESSION=root.dataset.session;
  /* PRODUCT_DECISION: API URL space mirrors disk layout under {ChatDataRoot}/<conv>/sessions/<sid>. */
  var SESSION_BASE='/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(SESSION);

  /* ===== message store — parallel to MessageView's bubble list =====
     PRODUCT_DECISION: chat.js holds the SSE records as plain data
     (`records`), and the corresponding Message widgets (`messages`) in
     the same order. Records are what every domain action reads — quote,
     refer, edit, search, navigateRef, onSelect, finishBacklog — because
     the data lives there. Message widgets only own the bubble DOM +
     click routing + in-place supersession; their public API is just
     {render, markEdited, getElement}. byId indexes both arrays by
     message id for O(1) lookup. Server-assigned index is 0-based; the
     view index is 1-based; the two stay consistent because we always
     append in order. */
  var records = [];
  var messages = [];
  var byId = new Map(); // id -> position in records / messages
  function recordById(id){ var i=byId.get(id); return i==null ? null : records[i]; }   // lint:null-undefined-check map-get
  // lint:called-once supersession-only — named to match recordById sibling
  function widgetById(id){ var i=byId.get(id); return i==null ? null : messages[i]; }  // lint:null-undefined-check map-get

  /* ===== domain actions (called from Message clicks AND ChatHelp keys) =====
     PRODUCT_DECISION: doQuote/doRefer/doEdit/navigateRef call pane.focusBubble,
     which is captured by closure from the var pane below. The actions are
     CALLED later (from Message instances built inside the pane's renderBubble
     callback), so the forward reference is safe. */
  var pane;

  function doQuote(rec){
    if(ChatCompose.isPending()) return;
    pane.focusBubble(rec.index + 1);
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor(
      'In MSG_'+rec.id+' '+(rec.mine?'I said':'you said')+
      ':\n~~~ quote\n'+rec.markdown+'\n~~~\n\n'
    );
  }
  function doRefer(rec){
    if(ChatCompose.isPending()) return;
    pane.focusBubble(rec.index + 1);
    ChatRightSidebar.openCompose();
    ChatCompose.insertAtCursor('See MSG_'+rec.id+' ');
  }
  /* PRODUCT_DECISION: Edit composes a NEW message with an "Edit of MSG_<hash>"
     backlink and the caret at the start of the original markdown. Append-only +
     transparent — no copy/paste, the backlink wires the relation. */
  function doEdit(rec){
    if(ChatCompose.isPending()) return;
    pane.focusBubble(rec.index + 1);
    var prefix='Edit of MSG_'+rec.id+'\n\n';
    ChatRightSidebar.openCompose();
    ChatCompose.setMarkdown(prefix+rec.markdown, prefix.length);
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
      var rec=recordById(id);
      if(rec) pane.focusBubble(rec.index + 1);
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
      byId.set(m.id, records.length);
      records.push(m);
      messages.push(msg);
      return msg.render();
    },
    onSelect: function(idx){
      var rec=records[idx-1];
      if(!rec) return;
      /* BROWSER_WORKAROUND: window.history — chat.js shadows the global `history`
         with the #chat-history DOM element near the top of this IIFE. */
      window.history.replaceState({}, '', '#msg-'+rec.id);
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
    if(em){ var orig=widgetById(em[1]); if(orig) orig.markEdited(m.id); }
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
      var rec=recordById(wantFocusID);
      wantFocusID=null;
      if(rec) opts.focusIdx=rec.index+1;
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
         a regression there shows up the next time you talk to anyone.
         The link parallels the cross-conv ping shape; click focuses the
         bubble in the current feed (same-session always, since we just
         sent it). */
      ChatCompose.ackIfPending(m.cid);
      var link=document.createElement('a');
      link.href='#msg-'+m.id;
      link.textContent='✓ '+m.id+' sent';
      link.addEventListener('click', function(e){
        e.preventDefault();
        var rec=recordById(m.id);
        if(rec) pane.focusBubble(rec.index+1);
      });
      ChatNotify.show(link);
    }
    if(ChatSearch.isOpen()) ChatSearch.refreshIfOpen();
  };

  /* ===== sibling module wiring ===== */
  ChatSearch.init({
    navbar:    pane.navbar,
    focusFeed: pane.focus,
    records:   records, /* live ref — same array chat.js pushes onto */
    jumpToId: function(id){
      var rec=recordById(id);
      if(rec) pane.focusBubble(rec.index+1);
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
      return idx>0 ? records[idx-1] : null;
    },
    quoteReply:  doQuote,
    referReply:  doRefer,
    editMessage: doEdit,
  });
  ChatCompose.focus();
})();
