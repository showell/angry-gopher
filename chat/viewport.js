/* Viewport — the single source of truth for "are we on a narrow screen?".

   One breakpoint, declared once here, for the whole app. Both consumers of
   it read from this one matchMedia, so they cannot drift:

     - CSS reads it as a class on <html> (vp-narrow). Responsive rules are
       written `html.vp-narrow .foo { ... }` instead of each stylesheet
       re-declaring its own @media (max-width:…). The breakpoint number
       appears in CSS nowhere.
     - JS reads it via Viewport.onChange(cb): cb(narrow) fires once now and
       again on every crossing — for the imperative bits CSS can't express
       (relocating a node, closing a drawer, re-pinning a scroll).

   Loaded SYNC in <head> (like colors.js): the class lands on <html> before
   first paint — no flash of the wrong arrangement — and Viewport is defined
   before any consumer runs (chat.js's body script, the deferred widgets). */
window.Viewport = (function(){
  'use strict';

  /* The one breakpoint for the whole app. Change it here and CSS (via the
     vp-narrow class) and JS (via onChange) move together. */
  var mql = window.matchMedia('(max-width:768px)');
  var callbacks = [];

  function isNarrow(){ return mql.matches; }

  function reflect(){
    document.documentElement.classList.toggle('vp-narrow', mql.matches);
  }

  function onChange(cb){
    callbacks.push(cb);
    cb(mql.matches); /* fire immediately with the current state */
  }

  reflect();
  mql.addEventListener('change', function(){
    reflect();
    for(var i = 0; i < callbacks.length; i++) callbacks[i](mql.matches);
  });

  return { isNarrow:isNarrow, onChange:onChange };
})();
