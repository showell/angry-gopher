/* PRODUCT_DECISION: two-phase search palette.
   Phase 1 autocompletes against EXACT corpus tokens (no stemming).
   Phase 2 (Enter) lists messages containing the chosen term as literal
   substrings, RENDERED with highlighting, forward-chronological.
   No index: token map rebuilds on open + linear scan on Enter — milliseconds. */
window.ChatSearch = (function(){
  'use strict';

  /* PRODUCT_DECISION: host-supplied refs/helpers populated by init().
     jumpToEl(el) is the one feed-side callback — given a feed bubble DOM,
     scroll it into focus + select it + record on nav stack. Body-click
     classification + popups come from Message.* statics (no callbacks). */
  var bubbles, history;
  var jumpToEl;

  var SEARCH_MIN=2, SUGGEST_CAP=10, SNIPPET_PAD=90;
  /* PRODUCT_DECISION: smart-case — case-sensitive only if the query has uppercase. */
  function smartIndexOf(hay,q,from){ return /[A-Z]/.test(q)?hay.indexOf(q,from||0):hay.toLowerCase().indexOf(q.toLowerCase(),from||0); }
  /* PRODUCT_DECISION: tokens are whitespace-delimited words with edge
     punctuation trimmed; internal punctuation kept so "foo.com" / "https://x"
     survive as one token. */
  // lint:called-once named-algorithm
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
        if(map[t]){ map[t].count++; map[t].sample=els[i]; } else map[t]={count:1,sample:els[i]}; /* PRODUCT_DECISION: sample = most recent msg with this token. */
      }
    }
    return map;
  }
  // lint:called-once named-algorithm
  function suggestTokens(map,q){
    q=q.toLowerCase(); var pre=[], sub=[];
    for(var t in map){ var k=t.indexOf(q); if(k===0) pre.push(t); else if(k>0) sub.push(t); }
    function byCount(a,b){ return map[b].count-map[a].count || (a<b?-1:1); }
    pre.sort(byCount); sub.sort(byCount); return pre.concat(sub); /* PRODUCT_DECISION: prefix matches first. */
  }
  /* PRODUCT_DECISION: builds <mark>s as DOM nodes (never innerHTML) — the raw
     body is untrusted text. */
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
  /* PRODUCT_DECISION: walks TEXT NODES only so links/images/code markup survive
     untouched. Rendered-HTML sibling of highlightInto (which builds from plain text). */
  // lint:called-once named-algorithm
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
  // lint:called-once named-algorithm
  function appendSnippet(node,body,term){
    var idx=smartIndexOf(body,term,0), start=0, end=body.length;
    if(idx>=0){ start=Math.max(0,idx-SNIPPET_PAD); end=Math.min(body.length,idx+term.length+SNIPPET_PAD); }
    else end=Math.min(body.length,180);
    if(start>0) node.appendChild(document.createTextNode('…'));
    highlightInto(node, body.slice(start,end), term);
    if(end<body.length) node.appendChild(document.createTextNode('…'));
  }
  /* PRODUCT_DECISION: SR is the live modal state or null. Shape:
     { dlg, input, list, status, phase:'suggest'|'results', map, items, sel, term } */
  var SR=null;
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
    /* PRODUCT_DECISION: own the Esc. Results-phase: step back to suggest. Suggest-phase: close. */
    dlg.addEventListener('cancel', function(e){
      e.preventDefault();
      if(!SR) return;
      if(SR.phase==='results'){ SR.phase='suggest'; SR.input.focus(); renderSuggest(); }
      else closeSearchModal();
    });
    dlg.addEventListener('click', onSearchClick);
    dlg.addEventListener('close', function(){ dlg.remove(); SR=null; history.focus({preventScroll:true}); });
    dlg.showModal(); input.focus(); renderSuggest();
  }
  function closeSearchModal(){ if(SR) SR.dlg.close(); }
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
      /* BROWSER_WORKAROUND: wrap the highlighted token in ONE child so the flex
         row's gap:8px only sits between token-and-count, never between <mark>
         and the rest of the token (which would print "pro" + " " + "bably"). */
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
    for(var i=0;i<els.length;i++){ if(smartIndexOf(els[i]._body||'', term, 0) >= 0) res.push(els[i]); }
    /* PRODUCT_DECISION: forward-chronological — matches the rest of the chat
       system (transcript, Images), which reads more naturally than newest-first. */
    if(!res.length){ SR.status.textContent='No messages contain “'+term+'”. Esc to refine.'; return; }
    SR.status.textContent=res.length+(res.length===1?' message — Enter to go':' messages — ↑↓ choose, Enter to go')+' · Esc to refine';
    for(var k=0;k<res.length;k++){
      var el=res[k], meta=el.querySelector('.chat-meta');
      var row=document.createElement('div'); row.className='chat-sr-row'; row.setAttribute('data-i',k);
      var head=document.createElement('div'); head.className='chat-sr-rhead';
      head.textContent=(meta&&meta.firstChild?meta.firstChild.nodeValue:'').trim();
      var body=document.createElement('div'); body.className='chat-sr-rbody';
      var src=el.querySelector('.chat-body'); /* PRODUCT_DECISION: reuse the feed's server-rendered HTML. */
      if(src){ var clone=src.cloneNode(true); highlightRendered(clone, term); body.appendChild(clone); }
      else highlightInto(body, el._body||'', term); /* APOLOGY: defensive fallback for missing rendered body. */
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
    jumpToEl(el); /* PRODUCT_DECISION: jump + push nav stack. */
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
    if(SR.phase==='suggest'){ finalizeSearch(); return; }
    /* PRODUCT_DECISION: results-mode click behavior differs from the feed only here. */
    var hit=Message.classifyBodyClick(e.target);
    if(hit.kind==='msgref'){ e.preventDefault(); return; } /* PRODUCT_DECISION: MSG_ refs inert inside search. */
    if(hit.kind==='image'){  ChatImagePopup.show(hit.src);   return; }
    if(hit.kind==='pre'){    Message.showCodePopup(hit.text);   return; }
    if(hit.kind==='link') return;                          /* PRODUCT_DECISION: external link → new tab. */
    chooseResult();                                        /* PRODUCT_DECISION: plain click → jump to this message. */
  }
  // lint:called-once external-trigger-from-chat-js
  function refreshOpenSearch(){
    /* PRODUCT_DECISION: triggered by chat.js when a message streamed in while the modal was open. */
    if(!SR) return; SR.map=buildTokenIndex();
    if(SR.phase==='suggest') renderSuggest(); else runResults(SR.term);
  }

  function init(deps){
    bubbles=deps.bubbles; history=deps.history;
    jumpToEl=deps.jumpToEl;
    var searchBtn=document.getElementById('chat-search-btn');
    if(searchBtn) searchBtn.addEventListener('click', openSearchModal);
  }
  function isOpen(){ return !!SR; }
  function refreshIfOpen(){ if(SR) refreshOpenSearch(); }

  return { init:init, open:openSearchModal, isOpen:isOpen, refreshIfOpen:refreshIfOpen };
})();
