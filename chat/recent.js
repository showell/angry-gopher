/* /chat/recent client. Two jobs:
   - tick every 20s, re-humanize each row's When cell from its data-ts so
     "5m ago" rolls to "6m ago" without reloading the page;
   - hold an EventSource on /chat/recent/stream and upsert one row per
     pushed event (insertion at the right sorted slot, or replace-in-place
     for an existing key, then re-paint the When cell). No client-side
     state — the DOM is the model. Keys mirror the server-emitted
     data-key: "chat:<conv>/<sid>" or "doc:<slug>". */
(function(){
  'use strict';

  var emptyEl=document.getElementById('recent-empty');
  var tableEl=document.getElementById('recent-table');
  if(!tableEl) return;
  /* Rows live under <tbody>, not directly under <table>. Server emits it
     explicitly; tableEl.insertBefore(tr, otherTr) would throw because
     otherTr's parent is the tbody, not the table. */
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

  /* Insert tr so rows stay sorted by data-ts desc (newest first). The
     <thead> holds the column-header tr (no data-ts), so we only scan tbody
     rows. Equal timestamps tie-break stably by inserting the new row
     above the older one of the same instant. */
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
