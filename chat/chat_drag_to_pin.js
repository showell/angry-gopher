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
      /* touch-action:pan-y keeps vertical drawer scroll on the browser
         until a pin-drag actually starts (then we set touch-action:none
         on that row so the same finger can move between lists). */
      + '.chat-session-item { touch-action:pan-y; cursor:grab;'
      +                     ' user-select:none; -webkit-user-select:none; }'
      + '.chat-session-item.drag-armed { cursor:grabbing; }'
      + '.chat-session-item.dragging { opacity:0.5; cursor:grabbing; }'
      + '.chat-session-drop { min-height:14px; border-radius:4px; }'
      + '.chat-session-drop.drop-active { outline:2px dashed var(--cc-notify-fg);'
      +                                 ' outline-offset:-2px;'
      +                                 ' background:var(--cc-accent-soft-bg); }'
      /* Drag ghost is appended to document.body (not a sidebar) so a
         narrow sidebar doesn't clip it; position:fixed makes that fine.
         Larger type + scale + hard shadow keep the label readable when a
         finger covers the row under the contact point. */
      + '.chat-drag-ghost { position:fixed; z-index:1000; pointer-events:none;'
      +                   ' background:var(--cc-accent); color:var(--cc-bg);'
      +                   ' font-size:15px; font-weight:bold; line-height:1.2;'
      +                   ' padding:8px 14px; border-radius:8px;'
      +                   ' box-shadow:0 8px 22px rgba(0,0,0,0.45),'
      +                              ' 0 0 0 2px var(--cc-bg);'
      +                   ' opacity:1; white-space:nowrap; max-width:220px;'
      +                   ' overflow:hidden; text-overflow:ellipsis;'
      +                   ' transform:scale(1.15); transform-origin:left bottom; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* PRODUCT_DECISION: pin/unpin is a full-axis drag between stacked
     lists. Mouse starts after a 5px move so taps still navigate.
     Touch/pen: a horizontal-dominant swipe arms drag immediately so
     pin mode is reachable without a long-press; vertical-dominant
     movement before arm is scroll and abandons the pending drag.
     A short still-hold still arms for vertical pin moves. */
  var DRAG_THRESHOLD=5, TOUCH_HOLD_MS=280, drag=null;

  function sectionAt(x,y){
    var el=document.elementFromPoint(x,y);
    return el ? el.closest('[data-section]') : null;
  }
  function clearActive(){
    var a=document.querySelectorAll('.chat-session-drop.drop-active');
    for(var i=0;i<a.length;i++) a[i].classList.remove('drop-active');
  }
  function clearHoldTimer(d){
    if(d && d.holdTimer){ clearTimeout(d.holdTimer); d.holdTimer=null; }
  }
  function resetItemGesture(item){
    item.classList.remove('dragging','drag-armed');
    item.style.touchAction='';
  }
  function armDrag(d){
    if(!d || d.armed || d.started) return;
    d.armed=true;
    d.item.classList.add('drag-armed');
    /* Once armed, take over the finger so vertical pin moves are not
       consumed as overflow scroll on the drawer. */
    d.item.style.touchAction='none';
  }

  function onDown(e){
    if(e.button>0) return; /* PRODUCT_DECISION: primary button / touch / pen only. */
    var item=e.currentTarget;
    delete item.dataset.justDragged;
    if(drag){ clearHoldTimer(drag); resetItemGesture(drag.item); }
    drag={ item:item, sid:item.getAttribute('data-sid'),
           sourceUl:item.closest('[data-section]'),
           x0:e.clientX, y0:e.clientY, pointerId:e.pointerId,
           pointerType:e.pointerType||'mouse',
           started:false, armed:false, holdTimer:null };
    /* Mouse is armed immediately; touch/pen wait for TOUCH_HOLD_MS. */
    if(e.pointerType==='mouse' || e.pointerType===''){
      armDrag(drag);
    }else{
      drag.holdTimer=setTimeout(function(){
        if(!drag || drag.item!==item) return;
        armDrag(drag);
      }, TOUCH_HOLD_MS);
    }
  }
  function startDragging(d, e){
    d.started=true;
    d.item.classList.add('dragging');
    d.item.classList.remove('drag-armed');
    try{ d.item.setPointerCapture(d.pointerId); }catch(_){}
    /* BROWSER_WORKAROUND: pointer-events:none on the ghost so
       elementFromPoint's hit-test of the drop section isn't shadowed. */
    d.ghost=document.createElement('div');
    d.ghost.className='chat-drag-ghost';
    d.ghost.textContent=d.item.textContent.trim();
    document.body.appendChild(d.ghost);
    if(e && e.cancelable) e.preventDefault();
  }
  function onMove(e){
    if(!drag) return;
    var dx=e.clientX-drag.x0, dy=e.clientY-drag.y0;
    var dist=Math.hypot(dx, dy);
    if(!drag.started){
      if(!drag.armed){
        if(dist<DRAG_THRESHOLD) return;
        /* Horizontal-dominant finger motion enters pin-drag immediately.
           Vertical-dominant motion is scroll; cancel the pending drag. */
        if(Math.abs(dx)>Math.abs(dy)){
          clearHoldTimer(drag);
          armDrag(drag);
          startDragging(drag, e);
        }else{
          clearHoldTimer(drag);
          resetItemGesture(drag.item);
          drag=null;
          return;
        }
      }else if(dist<DRAG_THRESHOLD){
        return;
      }else{
        startDragging(drag, e);
      }
    }else if(e.cancelable){
      e.preventDefault();
    }
    /* Touch: park the ghost above the contact so the thumb does not cover
       the label. Mouse keeps a small offset to the lower-right of the cursor. */
    var offX=14, offY=12;
    if(drag.pointerType==='touch' || drag.pointerType==='pen'){
      offX=10; offY=-52;
    }
    drag.ghost.style.left=(e.clientX+offX)+'px';
    drag.ghost.style.top=(e.clientY+offY)+'px';
    clearActive();
    var sec=sectionAt(e.clientX, e.clientY);
    if(sec && sec!==drag.sourceUl) sec.classList.add('drop-active');
  }
  function onUp(e){
    if(!drag) return;
    var d=drag; drag=null;
    clearHoldTimer(d);
    if(d.started){ try{ d.item.releasePointerCapture(e.pointerId); }catch(_){} }
    resetItemGesture(d.item); clearActive();
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
