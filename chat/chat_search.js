/* PRODUCT_DECISION: two-phase search palette, across every topic the viewer
   can see, ANSWERED BY THE SERVER (metal-vmm 155; Steve: the client is dumb).
   Phase 1 (typing) asks /chat/search/words?prefix= for words, each with how
   many messages hold it. Phase 2 (Enter) asks /chat/search/messages?word= for
   the messages, shown as excerpts with the word marked, in the server's
   order. The server tokenizes; this file never does: the word it searches is
   the word the server suggested, or what was typed. Choosing a result jumps
   within this topic, or opens the other topic at the message. */
window.ChatSearch = (function(){
  'use strict';

  /* PRODUCT_DECISION: widget owns its own CSS. The modal's rules are
     heavily state/pseudo-driven (.sel, :hover, ::backdrop, mark, and a
     few descendant selectors) so a single lazy <style> block is cleaner
     than per-element inline. Class-scoped to .chat-search-modal /
     .chat-sr-* so nothing leaks. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      /* PRODUCT_DECISION: pinned to a fixed top offset and grows downward as
         results fill in — never vertically re-centering. */
      + '.chat-search-modal { position:fixed; top:56px; bottom:auto; left:0; right:0;'
      +                    ' margin:0 auto; width:600px; max-width:92vw;'
      +                    ' max-height:calc(100vh - 80px); padding:0;'
      +                    ' border:1px solid var(--cc-quote-border); border-radius:10px;'
      +                    ' background:var(--cc-bg); color:var(--cc-fg);'
      +                    ' display:flex; flex-direction:column; }'
      + '.chat-search-modal::backdrop { background:var(--cc-backdrop); }'
      + '.chat-sr-input { margin:0; border:none; border-bottom:1px solid var(--cc-input-border);'
      +                ' border-radius:10px 10px 0 0; font-size:16px;'
      +                ' padding:12px 16px; font-family:inherit; outline:none;'
      +                ' background:var(--cc-bg); color:var(--cc-fg); }'
      + '.chat-sr-status { font-size:12px; color:var(--cc-muted-fg); padding:6px 16px;'
      +                 ' border-bottom:1px solid var(--cc-soft-border); flex:none; }'
      + '.chat-sr-list { overflow-y:auto; padding:4px 0; flex:1 1 auto; min-height:0; }'
      + '.chat-sr-row { padding:7px 16px; cursor:pointer;'
      +              ' border-left:3px solid transparent; }'
      + '.chat-sr-row.sel { background:var(--cc-search-sel-bg); border-left-color:var(--cc-accent); }'
      + '.chat-sr-row:hover { background:var(--cc-quote-bg); }'
      + '.chat-sr-tok { font-weight:bold; color:var(--cc-search-tok-fg); display:flex;'
      +              ' align-items:baseline; gap:8px; }'
      + '.chat-sr-cnt { font-weight:normal; font-size:11px; color:var(--cc-soft-muted-fg); }'
      + '.chat-sr-rhead { font-size:11px; color:var(--cc-muted-fg); margin-bottom:2px; }'
      /* phase 2: a result's excerpt, the raw markdown around the word */
      + '.chat-sr-ctx { font-family:ui-monospace,Menlo,Consolas,monospace;'
      +              ' font-size:12px; color:var(--cc-body-muted-fg); white-space:pre-wrap;'
      +              ' overflow-wrap:anywhere; margin-top:3px;'
      +              ' max-height:4.6em; overflow:hidden; }'
      + '.chat-search-modal mark { background:var(--cc-search-mark-bg); color:inherit;'
      +                          ' border-radius:2px; padding:0; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* PRODUCT_DECISION: host-supplied refs populated by init(). jumpToId(id)
     focuses a bubble of the open topic; sessionBase is the open topic's URL
     ("/chat/c/1_2/ChitChat"), to tell a result here from one elsewhere;
     focusFeed restores keyboard focus after the modal closes. */
  var focusFeed, jumpToId, sessionBase;

  /* PRODUCT_DECISION: the server's words, never re-read here (metal-vmm
     QUEUE 157(d)): the shortest word comes from the page (init), each
     answer says its own cap ("most"), and each message comes as its excerpt
     already cut, the word marked as the index read it. This file once kept
     a regex for a word's edges, a copy of the cap and of the shortest word,
     and they had come apart from the server's on Unicode spaces. */
  var SEARCH_MIN, DEBOUNCE_MS=150;
  /* PRODUCT_DECISION: builds <mark>s as DOM nodes (never innerHTML): the raw
     body is untrusted text. */
  function markedInto(node,before,mark,after){
    if(before) node.appendChild(document.createTextNode(before));
    if(mark){ var mk=document.createElement('mark'); mk.textContent=mark; node.appendChild(mk); }
    if(after) node.appendChild(document.createTextNode(after));
  }

  /* **ONE QUESTION IN FLIGHT THAT COUNTS**: every request takes a number, and
     an answer that is not the newest one asked is dropped, so a slow reply to
     "la" never paints over the reply to "lay". */
  var asked=0;
  function ask(url, done){
    var mine=++asked;
    fetch(url,{credentials:'same-origin'}).then(function(r){
      /* The /chat gate answers a session gone by sending to the login page. */
      if(r.redirected) return {status:401, json:null};
      return r.json().then(function(j){ return {status:r.status, json:j}; },
                          function(){ return {status:r.status, json:null}; });
    }).then(function(a){
      if(mine!==asked || !SR) return;
      if(a.status===401){ SR.status.textContent='You are signed out; reload the page to sign in again.'; return; }
      if(a.status===429){ SR.status.textContent='Searching too fast; one moment and try again.'; return; }
      if(a.status===503){ SR.status.textContent='Search is still getting ready; try again in a moment.'; return; }
      if(a.status!==200 || !a.json){ SR.status.textContent='Search failed ('+a.status+').'; console.error('chat search: '+url+' answered '+a.status); return; }
      done(a.json);
    }, function(err){
      if(mine!==asked || !SR) return;
      SR.status.textContent='Search failed: the server could not be reached.';
      console.error('chat search: '+url+': '+err);
    });
  }
  function unreadableNote(n){ return n>0 ? (' · '+n+(n===1?' topic':' topics')+' could not be read') : ''; }

  /* PRODUCT_DECISION: SR is the live modal state or null. Shape:
     { dlg, input, list, status, phase:'suggest'|'results', items, sel, term, timer } */
  var SR=null;
  function openSearchModal(){
    if(SR){ SR.input.focus(); return; }
    ensureStyles();
    var dlg=document.createElement('dialog'); dlg.className='chat-search-modal';
    var input=document.createElement('input'); input.type='text'; input.className='chat-sr-input';
    input.placeholder='Search every topic…'; input.autocomplete='off';
    var status=document.createElement('div'); status.className='chat-sr-status';
    var list=document.createElement('div'); list.className='chat-sr-list';
    dlg.appendChild(input); dlg.appendChild(status); dlg.appendChild(list);
    document.body.appendChild(dlg);
    SR={ dlg:dlg, input:input, list:list, status:status, phase:'suggest', items:[], sel:-1, term:'', timer:null };
    input.addEventListener('input', function(){ SR.phase='suggest'; scheduleSuggest(); });
    dlg.addEventListener('keydown', onSearchKey);
    /* PRODUCT_DECISION: own the Esc. Results-phase: step back to suggest. Suggest-phase: close. */
    dlg.addEventListener('cancel', function(e){
      e.preventDefault();
      if(!SR) return;
      if(SR.phase==='results'){ SR.phase='suggest'; SR.input.focus(); scheduleSuggest(); }
      else closeSearchModal();
    });
    dlg.addEventListener('click', onSearchClick);
    dlg.addEventListener('close', function(){ if(SR && SR.timer) clearTimeout(SR.timer); asked++; dlg.remove(); SR=null; focusFeed(); });
    dlg.showModal(); input.focus(); renderPrompt();
  }
  function closeSearchModal(){ if(SR) SR.dlg.close(); }
  function paintSel(){
    var rows=SR.list.querySelectorAll('.chat-sr-row');
    for(var i=0;i<rows.length;i++) rows[i].classList.toggle('sel', i===SR.sel);
    if(SR.sel>=0 && rows[SR.sel]) rows[SR.sel].scrollIntoView({block:'nearest'});
  }
  function renderPrompt(){
    SR.list.textContent=''; SR.items=[]; SR.sel=-1;
    SR.status.textContent='Type at least '+SEARCH_MIN+' characters to search every topic…';
  }
  /* PRODUCT_DECISION: typing waits DEBOUNCE_MS for a pause before asking, so
     a word typed quickly is one question, not one a keystroke. */
  /* PRODUCT_DECISION: the list empties as soon as the text changes, so Enter
     before the new words arrive searches what is typed, never a word left
     over from the last prefix. */
  function scheduleSuggest(){
    if(SR.timer) clearTimeout(SR.timer);
    var q=SR.input.value.trim();
    asked++;
    SR.list.textContent=''; SR.items=[]; SR.sel=-1;
    if(q.length<SEARCH_MIN){ renderPrompt(); return; }
    SR.status.textContent='Searching…';
    SR.timer=setTimeout(function(){ if(SR && SR.phase==='suggest'){ SR.timer=null; suggest(q); } }, DEBOUNCE_MS);
  }
  // lint:called-once the-step-the-debounce-timer-runs
  function suggest(q){
    SR.status.textContent='Searching…';
    ask('/chat/search/words?prefix='+encodeURIComponent(q), function(j){
      if(SR.phase!=='suggest') return;
      SR.list.textContent=''; SR.items=[]; SR.sel=-1;
      var words=j.words||[];
      if(!words.length){ SR.status.textContent='No word starts with “'+q+'” — press Enter to search it anyway.'+unreadableNote(j.unreadable); return; }
      SR.status.textContent=(words.length===j.most?'The top '+j.most+' words':words.length+(words.length===1?' word':' words'))+' · ↑↓ choose, Enter to search'+unreadableNote(j.unreadable);
      for(var i=0;i<words.length;i++){
        var w=words[i];
        var row=document.createElement('div'); row.className='chat-sr-row'; row.setAttribute('data-i',i);
        var head=document.createElement('div'); head.className='chat-sr-tok';
        /* BROWSER_WORKAROUND: wrap the highlighted word in ONE child so the flex
           row's gap:8px only sits between word-and-count, never inside the word. */
        /* Every word answered begins with the prefix as the server read it. */
        var tok=document.createElement('span'); markedInto(tok, '', w.word.slice(0, j.prefix.length), w.word.slice(j.prefix.length)); head.appendChild(tok);
        var cnt=document.createElement('span'); cnt.className='chat-sr-cnt'; cnt.textContent=w.count+(w.count===1?' msg':' msgs');
        head.appendChild(cnt);
        row.appendChild(head);
        SR.list.appendChild(row); SR.items.push({word:w.word});
      }
      SR.sel=0; paintSel();
    });
  }
  /* The conversation a result is in, as a reader names it: a channel by its
     name, a DM as one; and whether choosing it leaves this page. */
  // lint:called-once named-for-the-row-it-labels
  function whereLabel(m){
    var here=(m.conv+'/'+encodeURIComponent(m.sid))===sessionBase;
    var conv=m.kind==='channel' ? ('#'+m.conv.slice(m.conv.lastIndexOf('/')+1)) : 'a direct message';
    return here ? (m.sid+' (this topic)') : (conv+' · '+m.sid+' →');
  }
  function runResults(word, keepSel){
    if(SR.timer){ clearTimeout(SR.timer); SR.timer=null; }
    var was=keepSel ? SR.sel : 0;
    SR.term=word; SR.phase='results'; SR.list.textContent=''; SR.items=[]; SR.sel=-1;
    SR.status.textContent='Searching…';
    ask('/chat/search/messages?word='+encodeURIComponent(word), function(j){
      if(SR.phase!=='results' || SR.term!==word) return;
      var msgs=j.messages||[];
      if(!msgs.length){ SR.status.textContent='No messages hold “'+word+'”. Esc to refine.'+unreadableNote(j.unreadable); return; }
      var shown=msgs.length<j.matched ? (' (the first '+msgs.length+' shown)') : '';
      SR.status.textContent=j.matched+(j.matched===1?' message':' messages')+shown+' — ↑↓ choose, Enter to go · Esc to refine'+unreadableNote(j.unreadable);
      for(var k=0;k<msgs.length;k++){
        var m=msgs[k];
        var row=document.createElement('div'); row.className='chat-sr-row'; row.setAttribute('data-i',k);
        var head=document.createElement('div'); head.className='chat-sr-rhead';
        head.textContent=whereLabel(m)+' · '+m.from+' · '+Message.formatLocalTime(m.date);
        var ctx=document.createElement('div'); ctx.className='chat-sr-ctx'; markedInto(ctx, m.before, m.mark, m.after);
        row.appendChild(head); row.appendChild(ctx);
        SR.list.appendChild(row); SR.items.push({conv:m.conv, sid:m.sid, id:m.id});
      }
      SR.sel=Math.min(Math.max(was,0), SR.items.length-1); paintSel();
    });
  }
  function finalizeSearch(){
    var it=SR.items[SR.sel];
    var word=(SR.sel>=0 && it && it.word) ? it.word : SR.input.value.trim();
    if(word.length>=SEARCH_MIN) runResults(word);
  }
  function chooseResult(){
    if(SR.sel<0||!SR.items[SR.sel]) return;
    var it=SR.items[SR.sel];
    var base=it.conv+'/'+encodeURIComponent(it.sid);
    closeSearchModal();
    /* PRODUCT_DECISION: a result in the open topic jumps to its bubble (and
       pushes the nav stack); one elsewhere opens its topic at the message. */
    if(base===sessionBase) jumpToId(it.id);
    else window.location.href=base+'#msg-'+encodeURIComponent(it.id);
  }
  function onSearchKey(e){
    if(e.key==='ArrowDown'){ e.preventDefault(); if(SR.items.length){ SR.sel=Math.min(SR.items.length-1,SR.sel+1); paintSel(); } }
    else if(e.key==='ArrowUp'){ e.preventDefault(); if(SR.items.length){ SR.sel=Math.max(0,SR.sel-1); paintSel(); } }
    else if(e.key==='Enter'){ e.preventDefault(); if(SR.phase==='suggest') finalizeSearch(); else chooseResult(); }
  }
  function onSearchClick(e){
    if(e.target===SR.dlg){ closeSearchModal(); return; } /* PRODUCT_DECISION: backdrop click closes. */
    var row=e.target.closest && e.target.closest('.chat-sr-row'); if(!row) return;
    SR.sel=parseInt(row.getAttribute('data-i'),10); paintSel();
    if(SR.phase==='suggest') finalizeSearch(); else chooseResult();
  }
  // lint:called-once external-trigger-from-chat-js
  function refreshOpenSearch(){
    /* PRODUCT_DECISION: triggered by chat.js when a message streamed in while
       the modal was open: ask the same question again. */
    if(!SR) return;
    if(SR.phase==='suggest') scheduleSuggest(); else runResults(SR.term, true);
  }

  function init(deps){
    if(!(deps.minWord>0)) throw new Error('ChatSearch.init: the page gave no shortest word');
    SEARCH_MIN  = deps.minWord;
    focusFeed   = deps.focusFeed;
    jumpToId    = deps.jumpToId;
    sessionBase = deps.sessionBase;
    /* PRODUCT_DECISION: ChatSearch owns its own trigger end-to-end —
       creates the 🔍 button, styles it to match the navbar via
       ChatMiddlePane's helper, drops it next to back/fwd. The navbar
       doesn't know about search; it just lent us a slot. */
    var searchBtn = ChatMiddlePane.makeNavButton({
      label: '🔍',
      title: 'Search every topic (/)',
    });
    searchBtn.style.marginLeft = '4px';
    searchBtn.addEventListener('click', openSearchModal);
    deps.navbar.appendChild(searchBtn);
  }
  function isOpen(){ return !!SR; }
  function refreshIfOpen(){ if(SR) refreshOpenSearch(); }

  return { init:init, open:openSearchModal, isOpen:isOpen, refreshIfOpen:refreshIfOpen };
})();
