/* ChatLeftSidebar — the conversation/sessions rail.

   Wire shape: Go ships an inline JSON payload (in a sibling
   <script type="application/json"> next to the mount slot) of three
   ordered arrays: conversations, pinned_sessions, sessions. Each item
   is {id, label, url, active} — labels and links, no rendered HTML.
   Empty-state strings ("Drag a session here to pin it", "No sessions
   yet") are the widget's concern, not the server's.

   Builds three sections + the Add-Topic form into a caller-supplied
   mount element. Subscribes to /chat/sidebar/stream for SSE upserts
   when a new partner messages the user or a new topic is added in
   THIS conv. Pointer-driven drag-to-pin moves a session item between
   the Pinned and Sessions <ul>s and POSTs pin/unpin to the server. */
window.ChatLeftSidebar = (function(){
  'use strict';

  var CONV; /* set at init from deps */
  var mount, convList, pinnedList, sessionList;

  /* PRODUCT_DECISION: widget owns its CSS. Selectors are scoped under
     .chat-sidebar so multiple ChatLeftSidebar mounts on one page (e.g.
     a /learn demo) don't collide. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-sidebar { width:180px; flex-shrink:0; overflow-y:auto;'
      +                ' border-right:1px solid #ddd; padding-right:14px;'
      +                ' font-size:13px; }'
      + '.chat-sidebar-section { margin-bottom:18px; }'
      + '.chat-sidebar-title { font-size:11px; text-transform:uppercase;'
      +                      ' letter-spacing:0.05em; color:#888;'
      +                      ' margin-bottom:6px; font-weight:bold; }'
      + '.chat-sidebar-list { list-style:none; padding:0; margin:0; }'
      + '.chat-sidebar-list li { margin:0; }'
      + '.chat-sidebar-list li a { display:block; padding:4px 8px;'
      +                          ' border-radius:3px; color:#000080;'
      +                          ' text-decoration:none; }'
      + '.chat-sidebar-list li a:hover { background:#f0f0ff; }'
      + '.chat-sidebar-list li a.active { background:#000080; color:white;'
      +                                 ' font-weight:bold; }'
      + '.chat-sidebar-list li.muted { color:#888; padding:4px 8px;'
      +                              ' font-style:italic; }'
      + '.chat-session-item { touch-action:none; cursor:grab;'
      +                     ' user-select:none; -webkit-user-select:none; }'
      + '.chat-session-item.dragging { opacity:0.5; cursor:grabbing; }'
      + '.chat-session-drop { min-height:14px; border-radius:4px; }'
      + '.chat-session-drop.drop-active { outline:2px dashed #1a5fb4;'
      +                                 ' outline-offset:-2px;'
      +                                 ' background:#eef3fb; }'
      + '.chat-pin-hint { font-size:11px; }'
      /* Drag ghost is appended to document.body (not the sidebar) so a
         narrow sidebar doesn't clip it; position:fixed makes that fine. */
      + '.chat-drag-ghost { position:fixed; z-index:1000; pointer-events:none;'
      +                   ' background:#000080; color:#fff; font-size:12px;'
      +                   ' padding:3px 9px; border-radius:4px;'
      +                   ' box-shadow:0 2px 8px rgba(0,0,0,0.35);'
      +                   ' opacity:0.92; white-space:nowrap; max-width:170px;'
      +                   ' overflow:hidden; text-overflow:ellipsis; }'
      + '.chat-add-topic { display:flex; flex-wrap:wrap; gap:4px;'
      +                  ' margin-top:8px; }'
      + '.chat-add-topic input { flex:1; min-width:0; padding:3px 6px;'
      +                        ' font-size:12px; border:1px solid #ccc;'
      +                        ' border-radius:3px; font-family:inherit; }'
      + '.chat-add-topic button { padding:3px 8px; font-size:12px; flex:none; }'
      + '.chat-add-topic-err { flex-basis:100%; color:#b00020; font-size:11px; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* ===== DOM builders (initial render + SSE upsert) ===== */

  function makeConvItem(rec){
    var li=document.createElement('li');
    li.setAttribute('data-uid', rec.id);
    var a=document.createElement('a');
    a.href=rec.url; a.textContent=rec.label;
    if(rec.active) a.className='active';
    li.appendChild(a);
    return li;
  }
  function makeSessionItem(rec){
    var li=document.createElement('li');
    li.className='chat-session-item';
    li.setAttribute('data-sid', rec.id);
    var a=document.createElement('a');
    a.href=rec.url; a.textContent=rec.label;
    a.setAttribute('draggable','false');
    if(rec.active) a.className='active';
    li.appendChild(a);
    attachDragHandlers(li);
    return li;
  }
  function buildSection(title, listClass, dataSection, items, emptyHint, itemFn){
    var box=document.createElement('div'); box.className='chat-sidebar-section';
    var t=document.createElement('div'); t.className='chat-sidebar-title';
    t.textContent=title; box.appendChild(t);
    var ul=document.createElement('ul');
    ul.className='chat-sidebar-list'+(listClass?' '+listClass:'');
    ul.setAttribute('data-section', dataSection);
    if(items && items.length){
      for(var i=0;i<items.length;i++) ul.appendChild(itemFn(items[i]));
    } else if(emptyHint){
      var li=document.createElement('li');
      li.className=emptyHint.className||'muted';
      li.textContent=emptyHint.text;
      ul.appendChild(li);
    }
    box.appendChild(ul);
    return { box:box, ul:ul };
  }
  // lint:called-once dom-builder-abstraction
  function buildAddTopicForm(){
    var form=document.createElement('form');
    form.id='chat-add-topic'; form.className='chat-add-topic';
    var input=document.createElement('input');
    input.type='text'; input.id='chat-topic-name';
    input.placeholder='new-topic'; input.autocomplete='off';
    input.maxLength=80; input.spellcheck=false;
    var btn=document.createElement('button');
    btn.type='submit'; btn.textContent='Add Topic';
    var err=document.createElement('div');
    err.className='chat-add-topic-err'; err.id='chat-topic-err';
    form.appendChild(input); form.appendChild(btn); form.appendChild(err);
    wireAddTopicSubmit(form, input, err, btn);
    return form;
  }

  function insertSorted(ul, li){
    var sid=li.getAttribute('data-sid'), items=ul.querySelectorAll('.chat-session-item');
    for(var i=0;i<items.length;i++){
      if(items[i].getAttribute('data-sid')>sid){ ul.insertBefore(li, items[i]); return; }
    }
    ul.appendChild(li);
  }
  function syncPinHint(){
    var has=pinnedList.querySelector('.chat-session-item');
    var hint=pinnedList.querySelector('.chat-pin-hint');
    if(has && hint) hint.remove();
    else if(!has && !hint){
      var li=document.createElement('li');
      li.className='muted chat-pin-hint';
      li.textContent='Drag a session here to pin it';
      pinnedList.appendChild(li);
    }
  }

  /* ===== Add-Topic submit (POST + redirect-on-success) ===== */

  // lint:called-once init-section
  function wireAddTopicSubmit(form, input, err, btn){
    var TOPIC_RE=/^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$/;
    form.addEventListener('submit', function(e){
      e.preventDefault();
      var name=input.value.trim();
      if(!TOPIC_RE.test(name)){ err.textContent='Letters, digits, and hyphens only.'; return; }
      err.textContent=''; btn.disabled=true;
      fetch('/chat/c/'+encodeURIComponent(CONV)+'/new',{
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'topic='+encodeURIComponent(name),
      }).then(function(r){
        if(r.ok) return r.json();
        return r.text().then(function(t){ throw (t&&t.trim())||('error '+r.status); });
      }).then(function(j){
        location.href='/chat/c/'+encodeURIComponent(j.conv)+'/'+encodeURIComponent(j.sid);
      }).catch(function(msg){
        err.textContent=(typeof msg==='string'?msg:'Could not add topic.');
        btn.disabled=false;
      });
    });
  }

  /* ===== drag-to-pin (pointer events) =====
     PRODUCT_DECISION: a 5px move threshold gates drag-start so a plain tap
     still navigates the link. Pointer is captured AT drag-start, not at
     pointerdown — capturing earlier steals the click. */
  var DRAG_THRESHOLD=5, drag=null;
  function sectionAt(x,y){ var el=document.elementFromPoint(x,y); return el?el.closest('[data-section]'):null; }
  function clearActive(){
    var a=mount.querySelectorAll('.chat-session-drop.drop-active');
    for(var i=0;i<a.length;i++) a[i].classList.remove('drop-active');
  }
  function onDown(e){
    if(e.button>0) return; /* PRODUCT_DECISION: primary button / touch / pen only. */
    var item=e.currentTarget;
    delete item.dataset.justDragged;
    drag={ item:item, sid:item.getAttribute('data-sid'), sourceUl:item.closest('[data-section]'),
           x0:e.clientX, y0:e.clientY, pointerId:e.pointerId, started:false };
  }
  function onMove(e){
    if(!drag) return;
    if(!drag.started){
      if(Math.hypot(e.clientX-drag.x0, e.clientY-drag.y0) < DRAG_THRESHOLD) return;
      drag.started=true; drag.item.classList.add('dragging');
      try{ drag.item.setPointerCapture(drag.pointerId); }catch(_){}
      /* BROWSER_WORKAROUND: pointer-events:none on the ghost so elementFromPoint's
         hit-test of the drop section isn't shadowed by it. */
      drag.ghost=document.createElement('div');
      drag.ghost.className='chat-drag-ghost';
      drag.ghost.textContent=drag.item.textContent.trim();
      document.body.appendChild(drag.ghost);
    }
    drag.ghost.style.left=(e.clientX+12)+'px';
    drag.ghost.style.top=(e.clientY+10)+'px';
    clearActive();
    var sec=sectionAt(e.clientX, e.clientY);
    if(sec && sec!==drag.sourceUl) sec.classList.add('drop-active');
  }
  function onUp(e){
    if(!drag) return;
    var d=drag; drag=null;
    if(d.started){ try{ d.item.releasePointerCapture(e.pointerId); }catch(_){} }
    d.item.classList.remove('dragging'); clearActive();
    if(d.ghost) d.ghost.remove();
    if(!d.started) return; /* PRODUCT_DECISION: tap, not drag — let the link navigate. */
    d.item.dataset.justDragged='1'; /* PRODUCT_DECISION: suppress the click that follows the drag. */
    var target=sectionAt(e.clientX, e.clientY);
    if(!target || target===d.sourceUl) return;
    var pin = target.getAttribute('data-section')==='pinned';
    insertSorted(target, d.item); syncPinHint(); /* PRODUCT_DECISION: optimistic — DOM moves before server confirms. */
    fetch('/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(d.sid)+'/'+(pin?'pin':'unpin'), {method:'POST'})
      .then(function(r){ if(!r.ok) throw 0; })
      .catch(function(){ insertSorted(d.sourceUl, d.item); syncPinHint(); }); /* PRODUCT_DECISION: revert on failure. */
  }
  function onClick(e){
    var item=e.currentTarget;
    if(item.dataset.justDragged){ delete item.dataset.justDragged; e.preventDefault(); e.stopPropagation(); }
  }
  // lint:called-once event-handler-bundle — invoked per session item, but only from makeSessionItem
  function attachDragHandlers(item){
    item.addEventListener('pointerdown', onDown);
    item.addEventListener('pointermove', onMove);
    item.addEventListener('pointerup', onUp);
    item.addEventListener('pointercancel', onUp);
    item.addEventListener('click', onClick);
  }

  /* ===== SSE stream — user-arrived, topic-added =====
     PRODUCT_DECISION: server pre-resolves evt.conv to the canonical pair-key
     from THIS recipient's perspective, so we just build the link.
     Idempotent on data-uid / data-sid. */

  // lint:called-once sse-event-handler
  function upsertPartner(evt){
    if(!evt.user_id || !evt.conv) return;
    if(convList.querySelector('li[data-uid="'+evt.user_id+'"]')) return;
    convList.appendChild(makeConvItem({
      id: evt.user_id,
      label: evt.user_name || evt.user_id,
      url: '/chat/c/' + encodeURIComponent(evt.conv),
      active: false,
    }));
  }
  // lint:called-once sse-event-handler
  function upsertSession(evt){
    if(!evt.conv || !evt.sid || evt.conv!==CONV) return;
    if(sessionList.querySelector('.chat-session-item[data-sid="'+evt.sid+'"]')) return;
    var placeholder=sessionList.querySelector('li.muted:not(.chat-pin-hint)');
    if(placeholder) placeholder.remove();
    insertSorted(sessionList, makeSessionItem({
      id: evt.sid,
      label: evt.sid,
      url: '/chat/c/' + encodeURIComponent(CONV) + '/' + encodeURIComponent(evt.sid),
      active: false,
    }));
  }
  // lint:called-once init-section
  function wireSidebarStream(){
    var es=new EventSource('/chat/sidebar/stream');
    es.onmessage=function(e){
      var evt; try{ evt=JSON.parse(e.data); }catch(err){
        console.error('sidebar: malformed JSON from /chat/sidebar/stream', e.data, err); return;
      }
      if(!evt||!evt.kind) return;
      if(evt.kind==='user-arrived') upsertPartner(evt);
      else if(evt.kind==='topic-added') upsertSession(evt);
    };
  }

  /* ===== init ===== */

  function init(deps){
    ensureStyles();
    CONV = deps.conv;
    mount = deps.mount;
    mount.className = 'chat-sidebar';

    var data = deps.data || {};
    var conv = buildSection('Conversations', '', 'conversations',
      data.conversations, null, makeConvItem);
    var pin  = buildSection('Pinned Sessions', 'chat-session-drop', 'pinned',
      data.pinned_sessions,
      { className: 'muted chat-pin-hint', text: 'Drag a session here to pin it' },
      makeSessionItem);
    var ses  = buildSection('Sessions', 'chat-session-drop', 'sessions',
      data.sessions,
      { className: 'muted', text: 'No sessions yet' },
      makeSessionItem);

    convList    = conv.ul;
    pinnedList  = pin.ul;
    sessionList = ses.ul;

    mount.appendChild(conv.box);
    mount.appendChild(pin.box);
    mount.appendChild(ses.box);
    mount.appendChild(buildAddTopicForm());

    wireSidebarStream();
  }
  return { init:init };
})();
