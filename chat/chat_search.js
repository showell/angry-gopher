/* Chat search modal — a two-phase palette over the WHOLE transcript.
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
   rebuilt on open (milliseconds) and the message scan is one linear pass.

   Loaded as a sibling of chat.js. chat.js calls ChatSearch.init(deps) once
   the conversation page DOM + the shared helpers are in place; on every
   incoming SSE message chat.js also calls ChatSearch.refreshIfOpen() so an
   open search stays current with newly streamed messages.

   Why a sibling file: search is ~180 lines of independent UI that almost
   never changes once it's working, and keeping it out of chat.js means the
   feed code (which DOES iterate) reads in isolation. The cost is a small
   init-time dependency table; the deps are stable. */
window.ChatSearch = (function(){
  'use strict';

  /* host-supplied refs and helpers, populated by init() */
  var bubbles, history;
  var selectAndCommit, armedScroll, scrollToIndex, updateNav, idxOf;
  var hitInBody, openHitMedia;

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
    selectAndCommit(el,true); armedScroll(function(){ scrollToIndex(idxOf(el)); }); updateNav(); /* jump + push nav stack */
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

  function init(deps){
    bubbles=deps.bubbles; history=deps.history;
    selectAndCommit=deps.selectAndCommit; armedScroll=deps.armedScroll;
    scrollToIndex=deps.scrollToIndex; updateNav=deps.updateNav; idxOf=deps.idxOf;
    hitInBody=deps.hitInBody; openHitMedia=deps.openHitMedia;
    var searchBtn=document.getElementById('chat-search-btn');
    if(searchBtn) searchBtn.addEventListener('click', openSearchModal);
  }
  function isOpen(){ return !!SR; }
  function refreshIfOpen(){ if(SR) refreshOpenSearch(); }

  return { init:init, isOpen:isOpen, refreshIfOpen:refreshIfOpen };
})();
