/* /chat/recent client — flat reverse-chronological feed of activity.

   Server ships the initial rows as inline JSON (#recent-data) next to the
   mount slot (#recent-mount). This script builds one tile per event, holds
   an EventSource on /chat/recent/stream for upserts, and re-humanizes the
   relative time on a 20s tick (from each tile's data-ts).

   ALL styling for this page is client-side — the server emits zero CSS for
   /chat/recent. The tile shape matches the Flutter recents item: a leading
   mark (avatar / channel bar), context + topic, relative time, and a one-
   line "Who: excerpt" preview. The feed itself stays a flat newest-first
   list; this file does not add search, filters, or section headers. */
(function(){
  'use strict';

  var mount  = document.getElementById('recent-mount');
  var dataEl = document.getElementById('recent-data');
  if(!mount || !dataEl) return;

  var initial;
  try { initial = JSON.parse(dataEl.textContent); }
  catch(err){ console.error('recent: malformed JSON payload', err); return; }
  if(!Array.isArray(initial)) initial = [];

  /* Identity colors for the channel bar — stable per channel name, not
     theme tokens (they don't flip with light/dark; stream colors don't
     either). */
  var CHANNEL_COLORS = [
    '#3faf8a','#5b8def','#e07a5f','#9b72cf',
    '#e2b340','#4ecdc4','#f28482','#7b8cde',
  ];

  // lint:called-once init-once-guard
  function ensureStyles(){
    if(document.getElementById('recent-style')) return;
    var s = document.createElement('style');
    s.id = 'recent-style';
    s.textContent = ''
      + '.app-body-wrap { max-width: 720px; }'
      + '.recent-list { display:flex; flex-direction:column; }'
      + '.recent-tile { display:flex; align-items:flex-start; gap:10px;'
      +              ' padding:10px 8px 10px 12px; text-decoration:none;'
      +              ' color:inherit; border-radius:10px; }'
      + '.recent-tile:hover { background:var(--cc-quote-bg); }'
      + '.recent-lead { flex:none; width:32px; display:flex; justify-content:center; }'
      + '.recent-avatar { width:32px; height:32px; border-radius:50%;'
      +                ' background:var(--cc-accent-soft-bg); color:var(--cc-accent);'
      +                ' font-size:13px; font-weight:700;'
      +                ' display:flex; align-items:center; justify-content:center; }'
      + '.recent-bar { width:8px; height:40px; margin-top:2px; border-radius:99px; }'
      + '.recent-body { flex:1; min-width:0; }'
      + '.recent-top { display:flex; align-items:baseline; gap:8px; }'
      + '.recent-context { flex:1; min-width:0; font-size:13px; font-weight:600;'
      +                 ' color:var(--cc-body-muted-fg); white-space:nowrap;'
      +                 ' overflow:hidden; text-overflow:ellipsis; }'
      + '.recent-topic { color:var(--cc-fg); font-weight:600; letter-spacing:-0.2px; }'
      + '.recent-dot { color:var(--cc-muted-fg); font-weight:600; }'
      + '.recent-ago { flex:none; font-size:12px; font-weight:500;'
      +             ' font-variant-numeric:tabular-nums; color:var(--cc-muted-fg); }'
      + '.recent-title { margin-top:1px; font-size:15px; font-weight:600;'
      +               ' letter-spacing:-0.2px; white-space:nowrap;'
      +               ' overflow:hidden; text-overflow:ellipsis; }'
      + '.recent-preview { margin-top:2px; font-size:13px; line-height:1.3;'
      +                 ' color:var(--cc-body-muted-fg); white-space:nowrap;'
      +                 ' overflow:hidden; text-overflow:ellipsis; }';
    document.head.appendChild(s);
  }
  ensureStyles();

  var listEl = document.createElement('div');
  listEl.className = 'recent-list';
  mount.appendChild(listEl);

  var emptyEl = document.createElement('p');
  Object.assign(emptyEl.style, { color: ChatColors.mutedFg });
  emptyEl.textContent = 'Nothing yet.';

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
    var tiles=listEl.querySelectorAll('.recent-tile[data-ts]');
    for(var i=0;i<tiles.length;i++){
      var tile=tiles[i], ts=tile.dataset.ts; if(!ts) continue;
      var ago=tile.querySelector('.recent-ago');
      if(ago) ago.textContent=humanize(ts);
    }
  }
  setInterval(rePaintAges, 20000);

  function eventKey(evt){
    return evt.kind==='chat' ? 'chat:'+evt.url : 'doc:'+evt.slug;
  }

  /* where is "to <partner>" (DM) or "in <channel>" (channel). Incoming DMs
     already name the partner in who; outgoing ones keep it only in where. */
  function partnerOf(evt){
    if(!evt.dm) return '';
    if(evt.who && evt.who!=='You') return evt.who;
    if(evt.where && evt.where.indexOf('to ')===0) return evt.where.slice(3);
    return '';
  }

  function channelOf(evt){
    if(evt.kind!=='chat' || evt.dm) return '';
    if(evt.where && evt.where.indexOf('in ')===0) return evt.where.slice(3);
    return '';
  }

  // lint:called-once lead-factory
  function buildLead(evt){
    var lead=document.createElement('div');
    lead.className='recent-lead';
    if(evt.kind==='chat' && evt.dm){
      var av=document.createElement('div');
      av.className='recent-avatar';
      var name=partnerOf(evt);
      av.textContent=name ? name.charAt(0).toUpperCase() : '?';
      lead.appendChild(av);
      return lead;
    }
    var bar=document.createElement('div');
    bar.className='recent-bar';
    if(evt.kind==='chat'){
      var ch=channelOf(evt);
      var h=0;
      for(var i=0;i<ch.length;i++) h=((h<<5)-h)+ch.charCodeAt(i);
      bar.style.background=CHANNEL_COLORS[Math.abs(h)%CHANNEL_COLORS.length];
    }else{
      bar.style.background=ChatColors.mutedFg;
    }
    lead.appendChild(bar);
    return lead;
  }

  // lint:called-once row-factory
  function buildTile(evt){
    if(evt.kind!=='chat' && evt.kind!=='doc') return null;
    var a=document.createElement('a');
    a.className='recent-tile';
    a.href=evt.kind==='chat' ? evt.url : '/chat/docs/'+encodeURIComponent(evt.slug);
    a.dataset.key=eventKey(evt);
    a.dataset.ts=evt.at;
    a.appendChild(buildLead(evt));

    var body=document.createElement('div');
    body.className='recent-body';

    var top=document.createElement('div');
    top.className='recent-top';
    var context=document.createElement('div');
    context.className='recent-context';
    if(evt.kind==='chat' && !evt.dm){
      var hash=document.createElement('span');
      hash.textContent='#'+(channelOf(evt)||'channel');
      var dot=document.createElement('span');
      dot.className='recent-dot';
      dot.textContent='  ·  ';
      var topic=document.createElement('span');
      topic.className='recent-topic';
      topic.textContent=evt.topic||'';
      context.appendChild(hash);
      context.appendChild(dot);
      context.appendChild(topic);
    }else if(evt.kind==='chat'){
      /* Partner in the subtitle, topic as the title: a Gopher DM is many
         named sessions with one person, not one conversation. */
      context.textContent=partnerOf(evt)||'direct message';
    }else{
      context.textContent='doc';
    }
    var ago=document.createElement('span');
    ago.className='recent-ago';
    ago.textContent=humanize(evt.at);
    top.appendChild(context);
    top.appendChild(ago);
    body.appendChild(top);

    if(evt.kind==='chat' && evt.dm){
      var title=document.createElement('div');
      title.className='recent-title';
      title.textContent=evt.topic||'';
      body.appendChild(title);
    }else if(evt.kind==='doc'){
      var dtitle=document.createElement('div');
      dtitle.className='recent-title';
      dtitle.textContent=evt.title||evt.slug||'';
      body.appendChild(dtitle);
    }

    if(evt.kind==='chat' && evt.excerpt){
      var who=evt.who ? evt.who.split(' ')[0] : '';
      var preview=document.createElement('div');
      preview.className='recent-preview';
      preview.textContent=who ? (who+': '+evt.excerpt) : evt.excerpt;
      body.appendChild(preview);
    }

    a.appendChild(body);
    return a;
  }

  /* PRODUCT_DECISION: data-ts desc (newest first); equal timestamps tie-break
     stably by inserting above the older tile of the same instant. */
  // lint:called-once named-algorithm
  function insertSorted(tile){
    var ts=tile.dataset.ts;
    var tiles=listEl.querySelectorAll('.recent-tile[data-ts]');
    for(var i=0;i<tiles.length;i++){
      if(tiles[i].dataset.ts < ts){
        listEl.insertBefore(tile, tiles[i]);
        return;
      }
    }
    listEl.appendChild(tile);
  }

  // lint:called-once sse-handler
  function upsert(evt){
    var key=eventKey(evt);
    var existing=listEl.querySelector('.recent-tile[data-key="'+key+'"]');
    if(existing) existing.remove();
    var tile=buildTile(evt); if(!tile) return;
    insertSorted(tile);
    if(emptyEl && emptyEl.parentNode){ emptyEl.remove(); }
  }

  /* Initial paint: server-provided rows are already newest-first, so a
     plain append per tile preserves order. Empty state shows when the
     payload is empty. */
  for(var i=0;i<initial.length;i++){
    var tile=buildTile(initial[i]); if(tile) listEl.appendChild(tile);
  }
  if(initial.length===0) mount.appendChild(emptyEl);

  var es=new EventSource('/chat/recent/stream');
  es.onmessage=function(e){
    var evt; try{ evt=JSON.parse(e.data); }catch(err){ console.error('recent: malformed JSON from /chat/recent/stream', e.data, err); return; }
    if(!evt||!evt.kind||!evt.at) return;
    upsert(evt);
  };
})();
