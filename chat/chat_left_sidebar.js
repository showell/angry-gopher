/* Chat left sidebar — the column on the conversation page that lists
   Conversations (other partners), Pinned Sessions, Sessions, and the
   Add-Topic form.

   The sidebar markup is server-rendered (server/chat/chat.go
   renderChatSidebar); this script only attaches behavior to it. Two
   producers + one trivial consumer make up the whole boundary:

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
                          to chat-message + notify + recent SSE for
                          both participants), returns {conv, sid}.
                          Client navigates to the new topic.
       - pin / unpin:     POST /chat/c/<conv>/<sid>/{pin,unpin}
                          per-user state in chat_state.go (no SSE
                          fan-out — pin state is private to the user).

     SSE-CONSUMER SEAMS (currently empty — noted for future work)
       The Conversations and Sessions lists are static after page
       load. Two real gaps:
       - "new authorized user arrived" → no SSE event today; a fresh
         signup is invisible until reload. Adding one would let this
         module upsert a Conversations row.
       - "remote add-topic by the other participant" → AppendChatMessage
         already publishes a chat-message SSE for the seeded "hi", but
         this module doesn't subscribe to it; the new <li.chat-session-item>
         would need an upsertSession({sid, pinned:false}) method to plug
         in. The drag-insert logic (insertSorted + syncPinHint) is
         already shaped to do it.

   Loaded as a sibling of chat.js (BEFORE chat.js — chat.js's IIFE
   calls ChatLeftSidebar.init at the bottom). */
window.ChatLeftSidebar = (function(){
  'use strict';

  var CONV; /* current conv key, supplied by chat.js at init time */

  /* --- add a topic: a session with a custom name in THIS conversation.
     Validate the name (letters/digits/hyphens, matching the server), POST it,
     then optimistically switch to the new topic — it renders just like any
     other session, with the server-seeded "hi" already in it. --- */
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

  /* --- Pinned/Sessions drag-and-drop (pointer API).
     Drag a session item between the two <ul data-section> groups to pin/unpin
     it. pointerdown captures the pointer on the item; a >5px move starts the
     drag (so a plain tap still navigates the link); pointerup picks the drop
     section via elementFromPoint, POSTs .../<sid>/pin or /unpin (path-style,
     like send/stream), and optimistically moves the item (kept A-Z). --- */
  function wireDragToPin(){
    var DRAG_THRESHOLD=5, drag=null;
    function sectionAt(x,y){ var el=document.elementFromPoint(x,y); return el?el.closest('[data-section]'):null; }
    function clearActive(){ var a=document.querySelectorAll('.chat-session-drop.drop-active'); for(var i=0;i<a.length;i++) a[i].classList.remove('drop-active'); }
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
    var items=document.querySelectorAll('.chat-session-item');
    for(var i=0;i<items.length;i++){
      var it=items[i];
      it.addEventListener('pointerdown', onDown);
      it.addEventListener('pointermove', onMove);
      it.addEventListener('pointerup', onUp);
      it.addEventListener('pointercancel', onUp);
      it.addEventListener('click', onClick);
    }
  }

  function init(deps){
    CONV=deps.conv;
    wireAddTopic();
    wireDragToPin();
  }
  return { init:init };
})();
