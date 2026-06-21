/* /chat/recent client — flat reverse-chronological feed of activity.

   Server ships the initial rows as inline JSON (#recent-data) next to the
   mount slot (#recent-mount). This script builds the table, holds an
   EventSource on /chat/recent/stream for upserts, and re-humanizes the
   Ago column on a 20s tick (from each row's data-ts).

   ALL styling for this page is client-side — the server emits zero CSS for
   /chat/recent. A small injected <style> (below) sets the table spacing,
   top-aligns cells, and caps the page width; per-cell inline styles handle
   the Ago column (right-align/tabular-nums) and the excerpt/context spans. */
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
     inter-column and inter-row gaps directly: 5px/4px over the UA default
     2px/2px. Cells top-align so a multi-line excerpt doesn't vertically
     center the short cells beside it. */
  var layoutStyle = document.createElement('style');
  layoutStyle.textContent =
      '.app-body-wrap { max-width: 800px; }'
    + '#recent-mount table { width: 100%; border-collapse: separate; border-spacing: 5px 4px; }'
    + '#recent-mount th, #recent-mount td { vertical-align: top; }';
  document.head.appendChild(layoutStyle);

  /* Ago column: right-aligned tabular nums in a tight nowrap column, so the
     short relative ages ("5m", "2h", "3d") line up. Applied per cell so the
     page emits no CSS of its own. */
  var AGO_STYLE_TH = {
    textAlign:'right', fontVariantNumeric:'tabular-nums',
    whiteSpace:'nowrap', width:'1%',
  };
  /* metaFg (not mutedFg) for Ago + Message: the muted gray washed out
     against both light and dark backgrounds, so these use the higher-contrast
     meta token. */
  var AGO_STYLE_TD = {
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
  var thWho   = document.createElement('th'); thWho.textContent = 'Who';
  Object.assign(thWho.style, WHO_STYLE);
  var thWhat  = document.createElement('th'); thWhat.textContent = 'What';
  var thAgo   = document.createElement('th'); thAgo.textContent = 'Ago';
  Object.assign(thAgo.style, AGO_STYLE_TH);
  var thMsg   = document.createElement('th'); thMsg.textContent = 'Message';
  headRow.appendChild(thWho); headRow.appendChild(thWhat);
  headRow.appendChild(thAgo); headRow.appendChild(thMsg);
  thead.appendChild(headRow); tableEl.appendChild(thead);
  var tbodyEl = document.createElement('tbody');
  tableEl.appendChild(tbodyEl);
  mount.appendChild(tableEl);

  var emptyEl = document.createElement('p');
  Object.assign(emptyEl.style, { color: ChatColors.mutedFg });
  emptyEl.textContent = 'Nothing yet.';

  /* The "Ago" header carries the relative-time framing, so the cells drop the
     redundant " ago" suffix — "5m", "2h", "3d" ("just now" is its own phrase). */
  function humanize(iso){
    var d=Date.now()-new Date(iso).getTime();
    if(d<60000) return 'just now';
    var m=Math.floor(d/60000);
    if(m<60) return m+'m';
    var h=Math.floor(m/60);
    if(h<24) return h+'h';
    return Math.floor(h/24)+'d';
  }

  function rePaintAges(){
    var rows=tbodyEl.querySelectorAll('tr[data-ts]');
    for(var i=0;i<rows.length;i++){
      var tr=rows[i], ts=tr.dataset.ts; if(!ts) continue;
      var ago=tr.querySelector('td.recent-ago');
      if(ago) ago.textContent=humanize(ts);
    }
  }
  setInterval(rePaintAges, 20000);

  // lint:called-once row-factory
  function buildRow(evt){
    var tr=document.createElement('tr');
    var ago=document.createElement('td');
    /* The class is kept ONLY as a query handle for rePaintAges; styling
       is inline. */
    ago.className='recent-ago';
    Object.assign(ago.style, AGO_STYLE_TD);
    ago.textContent=humanize(evt.at);
    /* Who: the author, already rendered "You" server-side for the viewer.
       Empty for legacy sessions with no recorded author. */
    var who=document.createElement('td');
    Object.assign(who.style, WHO_STYLE);
    who.textContent=evt.who||'';
    var what=document.createElement('td');
    tr.dataset.ts=evt.at;
    if(evt.kind==='chat'){
      tr.dataset.key='chat:'+evt.url;
      /* Lead with the topic (the scannable thing) and link it to the
         transcript; the partner/channel context trails in parens. where is
         "to <partner>" (DM) or "in <channel>" (channel). */
      var a=document.createElement('a');
      a.href=evt.url; a.textContent=evt.topic;
      what.appendChild(a);
      what.appendChild(document.createTextNode(evt.where ? ' (message '+evt.where+')' : ' (message)'));
    }else if(evt.kind==='doc'){
      tr.dataset.key='doc:'+evt.slug;
      var da=document.createElement('a');
      da.href='/chat/docs/'+encodeURIComponent(evt.slug);
      da.textContent=evt.title||evt.slug;
      what.appendChild(da);
      what.appendChild(document.createTextNode(' (edited)'));
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
    tr.appendChild(who); tr.appendChild(what);
    tr.appendChild(ago); tr.appendChild(preview);
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
