/* ChatMiddlePane — the bubble feed + its back/forward history.

   Wraps three substrate pieces together:
     - MessageView (the scrollable rectangle-list, selection + keyboard nav)
     - NavStack    (back/forward state machine over message indices)
     - the navbar's <button>Back</button> / <button>Forward</button>
       (DOM emitted by the server; this module wires them).

   chat.js drives the pane via the API below and supplies one
   renderBubble callback (so the bubble-building logic stays where the
   Message + onQuote/onRefer/onEdit/onMsgRef callbacks live). The
   pane has no knowledge of SSE, supersession, sibling sidebars,
   compose, or search — those stay in chat.js. */
window.ChatMiddlePane = (function(){
  'use strict';

  function init(opts){
    var history      = opts.history;
    var bubbles      = opts.bubbles;
    var backBtn      = opts.backBtn;
    var fwdBtn       = opts.fwdBtn;
    var renderBubble = opts.renderBubble;
    var onSelect     = opts.onSelect || function(){};

    var nav;

    var view = MessageView.create({
      container:    history,
      list:         bubbles,
      renderBubble: renderBubble,
      setSelectedBubble: function(idx){
        if(idx<=0) return;
        onSelect(idx);
        nav.push(idx);
      },
    });

    nav = NavStack.create({
      gotoMessage:      function(idx){ view.focusBubble(idx, {silent:true}); },
      onChange:         function(canBack, canFwd){ backBtn.disabled=!canBack; fwdBtn.disabled=!canFwd; },
      currentSelection: view.getSelected,
    });
    backBtn.addEventListener('click', nav.back);
    fwdBtn.addEventListener('click', nav.forward);

    function caughtUp(){
      var els = bubbles.querySelectorAll('[data-i]');
      if(els.length === 0) return true;
      return els[els.length-1].getBoundingClientRect().bottom
        <= history.getBoundingClientRect().bottom + 1;
    }

    return {
      append:          view.append,
      focusBubble:     view.focusBubble,
      getSelected:     view.getSelected,
      cursorToExtreme: view.cursorToExtreme,
      startBacklog:    view.startBacklog,
      endBacklog:      view.endBacklog,
      caughtUp:        caughtUp,
    };
  }

  return { init: init };
})();
