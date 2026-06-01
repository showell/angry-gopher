/* NavStack — the back/forward state machine the chat conversation uses.

   A cursor-into-history that tracks recent selection landings (one
   "entry" per settle) and lets the user retrace. Three callers feed it
   in the chat page: MessageView's setSelectedBubble (pushes), the
   back/forward buttons (back/forward), and the b/f hotkeys (via the
   same button.click). Nothing about this module knows about chat
   bubbles or MessageView — entries are opaque integers ("view-index")
   the caller chose, and the walk callback decides what to DO with one.

   Drift: the live selection (currentSelection()) may differ from the
   entry the stack's cursor points at — e.g. the user clicked an entry
   then scrolled, so the auto-selection moved off it. In that state
   `drifted()` is true, and the first back() does NOT pop the stack;
   it returns to the stack's current entry ("recover to where I was").
   Subsequent backs pop normally. This is why back is enabled even at
   pos === 0 if the selection has drifted.

   API:
     NavStack.create({
       walk:              function(entry, opts){...}  // perform the jump
                                                      // opts.silent = true → don't re-push
       onChange:          function(canBack, canFwd){...} // enable/disable
       currentSelection:  function(){ return liveSelection; } // for drift check
     })
       → { push, back, forward }

   Three verbs out, three callbacks in. Drift, curEntry, and the button
   refresh are internal — the module decides when to recompute them
   (every push/back/forward + once on create). The walk's `silent:true`
   hint tells the consumer (e.g. MessageView's focusBubble) to skip
   whatever side effect would re-push onto the stack. Without it,
   back/forward would each push the destination on arrival and the
   stack would never shrink. */
window.NavStack = (function(){
  'use strict';

  function create(opts){
    var walk             = opts.walk;
    var onChange         = opts.onChange         || function(){};
    var currentSelection = opts.currentSelection || function(){ return 0; };

    var entries = [];
    var pos = -1;

    function curEntry(){ return pos >= 0 ? entries[pos] : 0; }
    function drifted(){
      var sel = currentSelection();
      /* PRODUCT_DECISION: sel===0 means "no selection" — that's not drift,
         it's absence. lint:null-undefined-check legit-absence-sentinel */
      return sel > 0 && sel !== curEntry();
    }
    function update(){
      onChange(pos > 0 || drifted(), pos < entries.length - 1);
    }
    function goToEntry(){
      if(pos < 0) return;
      walk(entries[pos], { silent: true });
      update();
    }
    function push(idx){
      /* PRODUCT_DECISION: pushing the entry already at the cursor is a
         no-op; this happens when a back/forward walk lands somewhere
         that re-fires the producer's "settled" event. */
      if(idx === curEntry()) return;
      /* Drop the forward tail when a new push happens off a back walk. */
      entries.length = pos + 1;
      entries.push(idx);
      pos = entries.length - 1;
      update();
    }
    function back(){
      /* PRODUCT_DECISION: drift recovery — first back returns to
         entries[pos] without popping; subsequent backs pop normally. */
      if(drifted()){ goToEntry(); return; }
      if(pos > 0){ pos--; goToEntry(); }
    }
    function forward(){
      if(pos < entries.length - 1){ pos++; goToEntry(); }
    }

    update(); /* PRODUCT_DECISION: fire onChange once at the start with
                 the empty-stack state, so the caller's buttons
                 initialize disabled — no init call to remember. */

    return { push: push, back: back, forward: forward };
  }

  return { create: create };
})();
