/* ChatDragToPin — pointer-driven gesture for moving a session item
   between the Pinned and Sessions lists.

   API:
     ChatDragToPin.init({conv, onDrop})
       conv:   pair-key used to build the pin/unpin POST URL.
       onDrop: callback fired BOTH on the optimistic move AND on the
               revert if the server POST fails. Signature
               ({item, toUl}) — caller places `item` in `toUl`
               (typically insertSorted) and runs any layout
               housekeeping (the empty-pinned hint).

     ChatDragToPin.attach(item)
       Wires the pointer events on one session item. Adds the
       .chat-session-item class so the drag affordance applies.

   Contract:
     - `item` is an <li> with a data-sid attribute (the session id —
       used in the POST URL).
     - Parent <ul>s carry data-section attributes; "pinned" means
       pin-on-drop, anything else means unpin.

   The widget owns the gesture, the optimistic-update + revert
   orchestration, the floating drag-ghost, and the styling for
   chat-session-item, chat-session-drop, and chat-drag-ghost. */
window.ChatDragToPin = (function(){
  'use strict';

  var CONV_BASE, onDropCb;

  /* PRODUCT_DECISION: widget owns its CSS — the draggable affordance
     on items, the dragging-state opacity, the drop-target outlines,
     and the floating ghost. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-session-item { touch-action:none; cursor:grab;'
      +                     ' user-select:none; -webkit-user-select:none; }'
      + '.chat-session-item.dragging { opacity:0.5; cursor:grabbing; }'
      + '.chat-session-drop { min-height:14px; border-radius:4px; }'
      + '.chat-session-drop.drop-active { outline:2px dashed var(--cc-notify-fg);'
      +                                 ' outline-offset:-2px;'
      +                                 ' background:var(--cc-accent-soft-bg); }'
      /* Drag ghost is appended to document.body (not a sidebar) so a
         narrow sidebar doesn't clip it; position:fixed makes that fine. */
      + '.chat-drag-ghost { position:fixed; z-index:1000; pointer-events:none;'
      +                   ' background:var(--cc-accent); color:var(--cc-bg); font-size:12px;'
      +                   ' padding:3px 9px; border-radius:4px;'
      +                   ' box-shadow:0 2px 8px rgba(0,0,0,0.35);'
      +                   ' opacity:0.92; white-space:nowrap; max-width:170px;'
      +                   ' overflow:hidden; text-overflow:ellipsis; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* PRODUCT_DECISION: a 5px move threshold gates drag-start so a plain
     tap still navigates the link. Pointer is captured AT drag-start,
     not at pointerdown — capturing earlier steals the click. */
  var DRAG_THRESHOLD=5, drag=null;

  function sectionAt(x,y){
    var el=document.elementFromPoint(x,y);
    return el ? el.closest('[data-section]') : null;
  }
  function clearActive(){
    var a=document.querySelectorAll('.chat-session-drop.drop-active');
    for(var i=0;i<a.length;i++) a[i].classList.remove('drop-active');
  }

  function onDown(e){
    if(e.button>0) return; /* PRODUCT_DECISION: primary button / touch / pen only. */
    var item=e.currentTarget;
    delete item.dataset.justDragged;
    drag={ item:item, sid:item.getAttribute('data-sid'),
           sourceUl:item.closest('[data-section]'),
           x0:e.clientX, y0:e.clientY, pointerId:e.pointerId, started:false };
  }
  function onMove(e){
    if(!drag) return;
    if(!drag.started){
      if(Math.hypot(e.clientX-drag.x0, e.clientY-drag.y0) < DRAG_THRESHOLD) return;
      drag.started=true; drag.item.classList.add('dragging');
      try{ drag.item.setPointerCapture(drag.pointerId); }catch(_){}
      /* BROWSER_WORKAROUND: pointer-events:none on the ghost so
         elementFromPoint's hit-test of the drop section isn't shadowed. */
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
    /* PRODUCT_DECISION: optimistic — caller places the item NOW; we'll
       fire onDrop again with reversed source/target if the POST fails. */
    if(onDropCb) onDropCb({item:d.item, toUl:target});
    fetch(CONV_BASE+'/'+encodeURIComponent(d.sid)+'/'+(pin?'pin':'unpin'),
          {method:'POST'})
      .then(function(r){ if(!r.ok) throw 0; })
      .catch(function(){
        if(onDropCb) onDropCb({item:d.item, toUl:d.sourceUl}); /* revert */
      });
  }
  function onClick(e){
    var item=e.currentTarget;
    if(item.dataset.justDragged){
      delete item.dataset.justDragged;
      e.preventDefault(); e.stopPropagation();
    }
  }

  function init(deps){
    ensureStyles();
    CONV_BASE = deps.convBase;
    onDropCb = deps.onDrop;
  }
  // lint:called-once event-handler-bundle — invoked per session item
  function attach(item){
    item.classList.add('chat-session-item');
    item.addEventListener('pointerdown', onDown);
    item.addEventListener('pointermove', onMove);
    item.addEventListener('pointerup', onUp);
    item.addEventListener('pointercancel', onUp);
    item.addEventListener('click', onClick);
  }

  return { init:init, attach:attach };
})();
