/* PRODUCT_DECISION: left sidebar attaches behavior to server-rendered markup.
   One dep (CONV). Produces: add-topic POST + pin/unpin POST. Consumes:
   /chat/sidebar/stream (user-arrived, topic-added). All DOM upserts are
   idempotent on data-uid / data-sid. */
window.ChatLeftSidebar = (function(){
  'use strict';

  var CONV; /* PRODUCT_DECISION: supplied by chat.js at init time. */

  function insertSorted(ul, li){
    var sid=li.getAttribute('data-sid'), items=ul.querySelectorAll('.chat-session-item');
    for(var i=0;i<items.length;i++){ if(items[i].getAttribute('data-sid')>sid){ ul.insertBefore(li, items[i]); return; } }
    ul.appendChild(li);
  }
  function syncPinHint(){
    var ul=document.querySelector('[data-section="pinned"]'); if(!ul) return;
    var has=ul.querySelector('.chat-session-item'), hint=ul.querySelector('.chat-pin-hint');
    if(has && hint) hint.remove();
    else if(!has && !hint){ var li=document.createElement('li'); li.className='muted chat-pin-hint'; li.textContent='Drag a session here to pin it'; ul.appendChild(li); }
  }

  // lint:called-once init-section
  function wireAddTopic(){
    var addTopicForm=document.getElementById('chat-add-topic');
    if(!addTopicForm) return;
    var topicInput=document.getElementById('chat-topic-name');
    var topicErr=document.getElementById('chat-topic-err');
    var TOPIC_RE=/^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$/;
    addTopicForm.addEventListener('submit',function(e){
      e.preventDefault();
      var name=topicInput.value.trim();
      if(!TOPIC_RE.test(name)){ topicErr.textContent='Letters, digits, and hyphens only.'; return; }
      topicErr.textContent='';
      var btn=addTopicForm.querySelector('button'); btn.disabled=true;
      fetch('/chat/c/'+encodeURIComponent(CONV)+'/new',{ method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'topic='+encodeURIComponent(name)
      }).then(function(r){
        if(r.ok) return r.json();
        return r.text().then(function(t){ throw (t&&t.trim())||('error '+r.status); });
      }).then(function(j){
        location.href='/chat/c/'+encodeURIComponent(j.conv)+'/'+encodeURIComponent(j.sid);
      }).catch(function(msg){
        topicErr.textContent=(typeof msg==='string'?msg:'Could not add topic.');
        btn.disabled=false;
      });
    });
  }

  /* PRODUCT_DECISION: a 5px move threshold gates drag-start so a plain tap
     still navigates the link. Pointer is captured AT drag-start, not at
     pointerdown — capturing earlier steals the click. */
  var DRAG_THRESHOLD=5, drag=null;
  function sectionAt(x,y){ var el=document.elementFromPoint(x,y); return el?el.closest('[data-section]'):null; }
  function clearActive(){ var a=document.querySelectorAll('.chat-session-drop.drop-active'); for(var i=0;i<a.length;i++) a[i].classList.remove('drop-active'); }
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
  /* PRODUCT_DECISION: dual-use — called at page load AND by upsertSession for
     items the SSE stream brings in. */
  function attachDragHandlers(item){
    item.addEventListener('pointerdown', onDown);
    item.addEventListener('pointermove', onMove);
    item.addEventListener('pointerup', onUp);
    item.addEventListener('pointercancel', onUp);
    item.addEventListener('click', onClick);
  }
  // lint:called-once init-section
  function wireDragToPin(){
    var items=document.querySelectorAll('.chat-session-item');
    for(var i=0;i<items.length;i++) attachDragHandlers(items[i]);
  }

  /* PRODUCT_DECISION: server pre-resolves evt.conv to the canonical pair-key
     from THIS recipient's perspective, so we just build the link. Idempotent
     on data-uid. */
  // lint:called-once sse-event-handler
  function upsertPartner(evt){
    if(!evt.user_id || !evt.conv) return;
    var ul=document.querySelector('[data-section="conversations"]'); if(!ul) return;
    if(ul.querySelector('li[data-uid="'+evt.user_id+'"]')) return;
    var li=document.createElement('li'); li.setAttribute('data-uid', evt.user_id);
    var a=document.createElement('a');
    a.href='/chat/c/'+encodeURIComponent(evt.conv);
    a.textContent=evt.user_name||evt.user_id;
    li.appendChild(a); ul.appendChild(li);
  }

  /* PRODUCT_DECISION: only act on events matching our CONV; idempotent on
     data-sid (covers both drag-to-pin's existing item AND a duplicate event). */
  // lint:called-once sse-event-handler
  function upsertSession(evt){
    if(!evt.conv || !evt.sid || evt.conv!==CONV) return;
    if(document.querySelector('.chat-session-item[data-sid="'+evt.sid+'"]')) return;
    var ul=document.querySelector('[data-section="sessions"]'); if(!ul) return;
    var placeholder=ul.querySelector('li.muted:not(.chat-pin-hint)');
    if(placeholder) placeholder.remove();
    var li=document.createElement('li'); li.className='chat-session-item'; li.setAttribute('data-sid', evt.sid);
    var a=document.createElement('a');
    a.href='/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(evt.sid);
    a.setAttribute('draggable','false');
    a.textContent=evt.sid;
    li.appendChild(a);
    insertSorted(ul, li);
    attachDragHandlers(li);
  }

  // lint:called-once init-section
  function wireSidebarStream(){
    var es=new EventSource('/chat/sidebar/stream');
    es.onmessage=function(e){
      var evt; try{ evt=JSON.parse(e.data); }catch(err){ console.error('sidebar: malformed JSON from /chat/sidebar/stream', e.data, err); return; }
      if(!evt||!evt.kind) return;
      if(evt.kind==='user-arrived') upsertPartner(evt);
      else if(evt.kind==='topic-added') upsertSession(evt);
    };
  }

  function init(deps){
    CONV=deps.conv;
    wireAddTopic();
    wireDragToPin();
    wireSidebarStream();
  }
  return { init:init };
})();
