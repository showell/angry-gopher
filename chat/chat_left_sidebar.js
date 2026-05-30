/* Chat left sidebar — the column on the conversation page that lists
   Conversations (other partners), Pinned Sessions, Sessions, and the
   Add-Topic form.

   The sidebar markup is server-rendered (server/chat/chat.go
   renderChatSidebar); this script only attaches behavior to it. Two
   producers + one trivial consumer + one SSE consumer:

     PAGE-LOAD CONSUMER
       - reads the rendered <li.chat-session-item> set + the
         #chat-add-topic form, attaches pointer/submit handlers.
       - depends on CONV (the current conv key, e.g. "1_2") for POST
         URLs. That's the ONLY thing it needs from chat.js — passed
         via init({conv}).

     PRODUCERS (server-mutating actions the sidebar can initiate)
       - add-topic:       POST /chat/c/<conv>/new  body=topic=<name>
                          server creates the session, seeds a "hi"
                          message (which AppendChatMessage publishes
                          to chat-message + notify + recent + sidebar
                          SSE for both participants), returns {conv,
                          sid}. Client navigates to the new topic.
       - pin / unpin:     POST /chat/c/<conv>/<sid>/{pin,unpin}
                          per-user state in chat_state.go (no SSE
                          fan-out — pin state is private to the user).

     SSE CONSUMER (chat_sidebar.go's /chat/sidebar/stream)
       Two event kinds, both upsert the right <li> with no fan-out
       beyond the DOM:
       - user-arrived: a new authorized principal exists. Server
         pre-resolves Conv (so the link is buildable without knowing
         our own uid). Append to the Conversations <ul>.
       - topic-added: a new session appeared in some conv. If it's
         OUR conv (evt.conv === CONV), insert sorted into the Sessions
         <ul> reusing the same insertSorted helper drag-to-pin uses.
         Otherwise ignore.
       Both upserts are idempotent (skip when a row with the matching
       data attribute already exists), so a redundant event is a no-op.

   Loaded as a sibling of chat.js (BEFORE chat.js — chat.js's IIFE
   calls ChatLeftSidebar.init at the bottom). */
window.ChatLeftSidebar = (function(){
  'use strict';

  var CONV; /* current conv key, supplied by chat.js at init time */

  /* -------- shared helpers (used by both drag-to-pin and SSE upsert) -------- */

  /* Insert an .chat-session-item <li> into `ul` keeping alphabetical
     order by data-sid. Used by drag-drop on pin/unpin AND by SSE
     topic-added when a remote participant adds a new session. */
  function insertSorted(ul, li){
    var sid=li.getAttribute('data-sid'), items=ul.querySelectorAll('.chat-session-item');
    for(var i=0;i<items.length;i++){ if(items[i].getAttribute('data-sid')>sid){ ul.insertBefore(li, items[i]); return; } }
    ul.appendChild(li);
  }
  /* The Pinned group shows a hint <li> only while it has no items. */
  function syncPinHint(){
    var ul=document.querySelector('[data-section="pinned"]'); if(!ul) return;
    var has=ul.querySelector('.chat-session-item'), hint=ul.querySelector('.chat-pin-hint');
    if(has && hint) hint.remove();
    else if(!has && !hint){ var li=document.createElement('li'); li.className='muted chat-pin-hint'; li.textContent='Drag a session here to pin it'; ul.appendChild(li); }
  }

  /* -------- add-topic form -------- */

  /* Validate the name (letters/digits/hyphens, matching the server),
     POST it, then navigate to the new topic — it renders just like any
     other session, with the server-seeded "hi" already in it. */
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

  /* -------- Pinned/Sessions drag-and-drop (pointer API) --------
     Drag a session item between the two <ul data-section> groups to
     pin/unpin it. pointerdown captures the pointer on the item; a >5px
     move starts the drag (so a plain tap still navigates the link);
     pointerup picks the drop section via elementFromPoint, POSTs
     .../<sid>/pin or /unpin, and optimistically moves the item. */

  var DRAG_THRESHOLD=5, drag=null;
  function sectionAt(x,y){ var el=document.elementFromPoint(x,y); return el?el.closest('[data-section]'):null; }
  function clearActive(){ var a=document.querySelectorAll('.chat-session-drop.drop-active'); for(var i=0;i<a.length;i++) a[i].classList.remove('drop-active'); }
  function onDown(e){
    if(e.button>0) return; /* primary button / touch / pen only */
    var item=e.currentTarget;
    delete item.dataset.justDragged; /* clear any stale suppress flag */
    drag={ item:item, sid:item.getAttribute('data-sid'), sourceUl:item.closest('[data-section]'),
           x0:e.clientX, y0:e.clientY, pointerId:e.pointerId, started:false };
    /* Do NOT capture here — capturing on pointerdown steals the click from
       the <a>, so plain taps stop navigating. We capture once a drag starts. */
  }
  function onMove(e){
    if(!drag) return;
    if(!drag.started){
      if(Math.hypot(e.clientX-drag.x0, e.clientY-drag.y0) < DRAG_THRESHOLD) return;
      drag.started=true; drag.item.classList.add('dragging');
      /* Now that it's a real drag, capture the pointer so moves keep coming
         even as the cursor leaves the item (and releases at pointerup). */
      try{ drag.item.setPointerCapture(drag.pointerId); }catch(_){}
      /* a ghost chip that follows the cursor; pointer-events:none so it
         doesn't shadow elementFromPoint's hit-test of the drop section. */
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
    if(!d.started) return; /* a tap, not a drag — let the link navigate */
    d.item.dataset.justDragged='1'; /* suppress the click that follows the drag */
    var target=sectionAt(e.clientX, e.clientY);
    if(!target || target===d.sourceUl) return; /* dropped back / outside */
    var pin = target.getAttribute('data-section')==='pinned';
    insertSorted(target, d.item); syncPinHint(); /* optimistic */
    fetch('/chat/c/'+encodeURIComponent(CONV)+'/'+encodeURIComponent(d.sid)+'/'+(pin?'pin':'unpin'), {method:'POST'})
      .then(function(r){ if(!r.ok) throw 0; })
      .catch(function(){ insertSorted(d.sourceUl, d.item); syncPinHint(); }); /* revert on failure */
  }
  function onClick(e){
    var item=e.currentTarget;
    if(item.dataset.justDragged){ delete item.dataset.justDragged; e.preventDefault(); e.stopPropagation(); }
  }
  /* Attach drag/click handlers to ONE session item. Used at page-load
     for the server-rendered set and also by upsertSession for items the
     SSE stream brings in mid-page. */
  function attachDragHandlers(item){
    item.addEventListener('pointerdown', onDown);
    item.addEventListener('pointermove', onMove);
    item.addEventListener('pointerup', onUp);
    item.addEventListener('pointercancel', onUp);
    item.addEventListener('click', onClick);
  }
  function wireDragToPin(){
    var items=document.querySelectorAll('.chat-session-item');
    for(var i=0;i<items.length;i++) attachDragHandlers(items[i]);
  }

  /* -------- SSE consumer (/chat/sidebar/stream) -------- */

  /* Append a Conversations row for a newly-authorized principal. Server
     pre-resolves evt.conv to the canonical pair-key from THIS recipient's
     perspective, so we just build the link. Idempotent on data-uid. */
  function upsertPartner(evt){
    if(!evt.user_id || !evt.conv) return;
    var ul=document.querySelector('[data-section="conversations"]'); if(!ul) return;
    if(ul.querySelector('li[data-uid="'+evt.user_id+'"]')) return; /* already there */
    var li=document.createElement('li'); li.setAttribute('data-uid', evt.user_id);
    var a=document.createElement('a');
    a.href='/chat/c/'+encodeURIComponent(evt.conv);
    a.textContent=evt.user_name||evt.user_id;
    li.appendChild(a); ul.appendChild(li);
  }

  /* Insert a new Sessions row when a remote participant adds a topic in
     our current conv. Filter: only act on events matching CONV. Skip if
     a session item with the same data-sid already exists (covers both
     drag-to-pin's existing item AND a previous topic-added event). */
  function upsertSession(evt){
    if(!evt.conv || !evt.sid || evt.conv!==CONV) return;
    if(document.querySelector('.chat-session-item[data-sid="'+evt.sid+'"]')) return;
    var ul=document.querySelector('[data-section="sessions"]'); if(!ul) return;
    /* Drop the "No sessions yet" placeholder, if present. */
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

  function wireSidebarStream(){
    var es=new EventSource('/chat/sidebar/stream');
    es.onmessage=function(e){
      var evt; try{ evt=JSON.parse(e.data); }catch(_){ return; }
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
