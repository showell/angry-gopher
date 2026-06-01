/* NavStack — a back/forward stack with drift recovery.

   Push every settled location; back walks the cursor backward; forward
   walks it forward. Caller wires push() to a "selection settled"
   producer (chat.js uses MessageView's setSelectedBubble) and back /
   forward to its Back / Forward buttons + b/f hotkeys.

   Drift recovery: if the live selection has wandered off the stack's
   cursor since the last push, the first back() returns to the cursor's
   entry WITHOUT popping; the next back() pops as normal. Back means
   "get me back to where I was" first and "pop the stack" second.

   API:
     NavStack.create({
       gotoMessage:      function(entry)            // navigate to entry
       onChange:         function(canBack, canFwd)  // enable/disable buttons
       currentSelection: function() returns entry   // live, for drift check
     }) → { push, back, forward }
*/
window.NavStack = (function(){
  'use strict';

  function create(opts){
    var gotoMessage      = opts.gotoMessage;
    var onChange         = opts.onChange         || function(){};
    var currentSelection = opts.currentSelection || function(){ return 0; };

    var entries = [];
    var pos = -1;

    function pinnedEntry(){ return pos >= 0 ? entries[pos] : 0; }
    function drifted(){
      var sel = currentSelection();
      return sel > 0 && sel !== pinnedEntry();
    }
    function notifyChange(){
      onChange(pos > 0 || drifted(), pos < entries.length - 1);
    }
    function goToPinned(){
      if(pos < 0) return;
      gotoMessage(entries[pos]);
      notifyChange();
    }
    function push(entry){
      if(entry === pinnedEntry()) return;
      entries.length = pos + 1;
      entries.push(entry);
      pos = entries.length - 1;
      notifyChange();
    }
    function back(){
      if(drifted()){ goToPinned(); return; }
      if(pos > 0){ pos--; goToPinned(); }
    }
    function forward(){
      if(pos < entries.length - 1){ pos++; goToPinned(); }
    }

    notifyChange();

    return { push: push, back: back, forward: forward };
  }

  return { create: create };
})();
