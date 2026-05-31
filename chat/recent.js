/* PRODUCT_DECISION: two jobs on /chat/recent — 20s tick re-humanizes When
   cells from data-ts, and an EventSource on /chat/recent/stream upserts one
   row per pushed event (replace-in-place by data-key, insert sorted by
   data-ts desc). DOM is the model; no client-side cache. */
(function(){
  'use strict';

  var emptyEl=document.getElementById('recent-empty');
  var tableEl=document.getElementById('recent-table');
  if(!tableEl) return;
  /* BROWSER_WORKAROUND: rows live under <tbody>, not directly under <table>.
     tableEl.insertBefore(tr, otherTr) throws because otherTr's parent is the
     tbody, not the table. Server emits the <tbody> explicitly. */
  var tbodyEl=tableEl.querySelector('tbody');
  if(!tbodyEl) return;

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
    var when=document.createElement('td'); when.className='recent-when';
    when.textContent=humanize(evt.at);
    var what=document.createElement('td');
    tr.dataset.ts=evt.at;
    if(evt.kind==='chat'){
      tr.dataset.key='chat:'+evt.conv+'/'+evt.sid;
      var a=document.createElement('a');
      a.href='/chat/c/'+encodeURIComponent(evt.conv)+'/'+encodeURIComponent(evt.sid);
      a.textContent=evt.sid;
      what.appendChild(document.createTextNode('New message in '));
      what.appendChild(a);
      var partner=document.createElement('span'); partner.className='muted';
      partner.textContent=' (with '+(evt.partner||'')+')';
      what.appendChild(partner);
    }else if(evt.kind==='doc'){
      tr.dataset.key='doc:'+evt.slug;
      var da=document.createElement('a');
      da.href='/chat/docs/'+encodeURIComponent(evt.slug);
      da.textContent=evt.title||evt.slug;
      what.appendChild(document.createTextNode('You edited '));
      what.appendChild(da);
    }else{
      return null;
    }
    tr.appendChild(when); tr.appendChild(what);
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
    var key=evt.kind==='chat' ? 'chat:'+evt.conv+'/'+evt.sid : 'doc:'+evt.slug;
    var existing=tbodyEl.querySelector('tr[data-key="'+key+'"]');
    if(existing) existing.remove();
    var tr=buildRow(evt); if(!tr) return;
    insertSorted(tr);
    if(emptyEl){ emptyEl.remove(); emptyEl=null; tableEl.hidden=false; }
  }

  var es=new EventSource('/chat/recent/stream');
  es.onmessage=function(e){
    var evt; try{ evt=JSON.parse(e.data); }catch(err){ console.error('recent: malformed JSON from /chat/recent/stream', e.data, err); return; }
    if(!evt||!evt.kind||!evt.at) return;
    upsert(evt);
  };
})();
