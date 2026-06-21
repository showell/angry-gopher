/* /chat/recent client — flat reverse-chronological feed of activity.

   Server ships the initial rows as inline JSON (#recent-data) next to the
   mount slot (#recent-mount). This script builds the table, holds an
   EventSource on /chat/recent/stream for upserts, and re-humanizes the
   When column on a 20s tick (from each row's data-ts).

   ALL styling for this page is client-side — the server emits zero CSS for
   /chat/recent. A small injected <style> (below) sets the table spacing and
   widens the page container; per-cell inline styles handle the When column
   (right-align/tabular-nums) and the muted excerpt/context spans. */
(function(){
  'use strict';

  var mount  = document.getElementById('recent-mount');
  var dataEl = document.getElementById('recent-data');
  if(!mount || !dataEl) return;

  var initial;
  try { initial = JSON.parse(dataEl.textContent); }
  catch(err){ console.error('recent: malformed JSON payload', err); return; }
  if(!Array.isArray(initial)) initial = [];

  /* Page-owned layout. border-spacing (not border-collapse) names the
     inter-column and inter-row gaps directly: 4px/3px is +2px between columns
     and +1px between rows over the UA default 2px/2px. The container is
     widened past the 820px chrome cap so the feed uses the horizontal space
     it has when the window is wide. */
  var layoutStyle = document.createElement('style');
  layoutStyle.textContent =
      '.app-body-wrap { max-width: 800px; }'
    + '#recent-mount table { width: 100%; border-collapse: separate; border-spacing: 4px 3px; }';
  document.head.appendChild(layoutStyle);

  /* PRODUCT_DECISION: When column inline-styles match what the dropped
     server-side .recent-when block did (right-align, tabular nums, tight
     nowrap column, muted color on td). Applied per cell so the page
     emits no CSS of its own. */
  var WHEN_STYLE_TH = {
    textAlign:'right', fontVariantNumeric:'tabular-nums',
    whiteSpace:'nowrap', width:'1%',
  };
  /* metaFg (not mutedFg) for When + Message: the muted gray washed out
     against both light and dark backgrounds, so these use the higher-contrast
     meta token. */
  var WHEN_STYLE_TD = {
    textAlign:'right', fontVariantNumeric:'tabular-nums',
    whiteSpace:'nowrap', width:'1%', color: ChatColors.metaFg,
  };

  /* Who column shrinks to its content (names are short). */
  var WHO_STYLE = { whiteSpace:'nowrap', width:'1%' };

  /* The Message column shows a plain-text preview the server already
     trimmed; we clamp the visible height to three lines with the
     -webkit-box line-clamp idiom (applied to an inner div so the td keeps
     normal table-cell layout). */
  var EXCERPT_STYLE = {
    color: ChatColors.metaFg, whiteSpace:'normal', maxWidth:'44ch',
    display:'-webkit-box', WebkitBoxOrient:'vertical', WebkitLineClamp:'3',
    overflow:'hidden',
  };

  var tableEl = document.createElement('table');
  var thead   = document.createElement('thead');
  var headRow = document.createElement('tr');
  var thWhen  = document.createElement('th'); thWhen.textContent = 'When';
  Object.assign(thWhen.style, WHEN_STYLE_TH);
  var thWho   = document.createElement('th'); thWho.textContent = 'Who';
  Object.assign(thWho.style, WHO_STYLE);
  var thWhat  = document.createElement('th'); thWhat.textContent = 'What';
  var thMsg   = document.createElement('th'); thMsg.textContent = 'Message';
  headRow.appendChild(thWhen); headRow.appendChild(thWho);
  headRow.appendChild(thWhat); headRow.appendChild(thMsg);
  thead.appendChild(headRow); tableEl.appendChild(thead);
  var tbodyEl = document.createElement('tbody');
  tableEl.appendChild(tbodyEl);
  mount.appendChild(tableEl);

  var emptyEl = document.createElement('p');
  Object.assign(emptyEl.style, { color: ChatColors.mutedFg });
  emptyEl.textContent = 'Nothing yet.';

  function humanize(iso){
    var d=Date.now()-new Date(iso).getTime();
    if(d<60000) return 'just now';
    var m=Math.floor(d/60000);
    if(m<60) return m+'m ago';
    var h=Math.floor(m/60);
    if(h<24) return h+'h ago';
    return Math.floor(h/24)+'d ago';
  }

  function rePaintAges(){
    var rows=tbodyEl.querySelectorAll('tr[data-ts]');
    for(var i=0;i<rows.length;i++){
      var tr=rows[i], ts=tr.dataset.ts; if(!ts) continue;
      var when=tr.querySelector('td.recent-when');
      if(when) when.textContent=humanize(ts);
    }
  }
  setInterval(rePaintAges, 20000);

  // lint:called-once row-factory
  function buildRow(evt){
    var tr=document.createElement('tr');
    var when=document.createElement('td');
    /* The class is kept ONLY as a query handle for rePaintAges; styling
       is inline. */
    when.className='recent-when';
    Object.assign(when.style, WHEN_STYLE_TD);
    when.textContent=humanize(evt.at);
    /* Who: the author, already rendered "You" server-side for the viewer.
       Empty for legacy sessions with no recorded author. */
    var who=document.createElement('td');
    Object.assign(who.style, WHO_STYLE);
    who.textContent=evt.who||'';
    var what=document.createElement('td');
    tr.dataset.ts=evt.at;
    if(evt.kind==='chat'){
      tr.dataset.key='chat:'+evt.url;
      /* "message <where> (<topic>)" — where is "to <partner>" (DM) or
         "in <channel>" (channel); the topic links to the transcript. */
      what.appendChild(document.createTextNode(evt.where ? 'message '+evt.where+' (' : 'message ('));
      var a=document.createElement('a');
      a.href=evt.url; a.textContent=evt.topic;
      what.appendChild(a);
      what.appendChild(document.createTextNode(')'));
    }else if(evt.kind==='doc'){
      tr.dataset.key='doc:'+evt.slug;
      var da=document.createElement('a');
      da.href='/chat/docs/'+encodeURIComponent(evt.slug);
      da.textContent=evt.title||evt.slug;
      what.appendChild(document.createTextNode('edited '));
      what.appendChild(da);
    }else{
      return null;
    }
    var preview=document.createElement('td');
    if(evt.kind==='chat' && evt.excerpt){
      var clamp=document.createElement('div');
      Object.assign(clamp.style, EXCERPT_STYLE);
      clamp.textContent=evt.excerpt;
      preview.appendChild(clamp);
    }
    tr.appendChild(when); tr.appendChild(who);
    tr.appendChild(what); tr.appendChild(preview);
    return tr;
  }

  /* PRODUCT_DECISION: data-ts desc (newest first); equal timestamps tie-break
     stably by inserting above the older row of the same instant. */
  // lint:called-once named-algorithm
  function insertSorted(tr){
    var ts=tr.dataset.ts;
    var rows=tbodyEl.querySelectorAll('tr[data-ts]');
    for(var i=0;i<rows.length;i++){
      if(rows[i].dataset.ts < ts){
        tbodyEl.insertBefore(tr, rows[i]);
        return;
      }
    }
    tbodyEl.appendChild(tr);
  }

  // lint:called-once sse-handler
  function upsert(evt){
    var key=evt.kind==='chat' ? 'chat:'+evt.url : 'doc:'+evt.slug;
    var existing=tbodyEl.querySelector('tr[data-key="'+key+'"]');
    if(existing) existing.remove();
    var tr=buildRow(evt); if(!tr) return;
    insertSorted(tr);
    if(emptyEl && emptyEl.parentNode){ emptyEl.remove(); }
  }

  /* Initial paint: server-provided rows are already newest-first, so a
     plain append per row preserves order. Empty state shows when the
     payload is empty. */
  for(var i=0;i<initial.length;i++){
    var tr=buildRow(initial[i]); if(tr) tbodyEl.appendChild(tr);
  }
  if(initial.length===0) mount.appendChild(emptyEl);

  var es=new EventSource('/chat/recent/stream');
  es.onmessage=function(e){
    var evt; try{ evt=JSON.parse(e.data); }catch(err){ console.error('recent: malformed JSON from /chat/recent/stream', e.data, err); return; }
    if(!evt||!evt.kind||!evt.at) return;
    upsert(evt);
  };
})();
