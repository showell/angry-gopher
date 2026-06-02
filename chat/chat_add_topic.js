/* ChatAddTopic — the "Add Topic" form at the bottom of the left rail.

   ChatAddTopic.create({conv, onCreated}) returns a <form> ready to
   drop into a parent. Owns its DOM, its CSS, its TOPIC_RE validation,
   the POST to /chat/c/<conv>/new, and the inline error display on
   failure. Does NOT decide what happens on success — the caller
   passes onCreated({conv, sid}) and decides whether to navigate, log,
   pop a toast, etc. The widget is a presentational form with a
   domain event; the next action is policy. */
window.ChatAddTopic = (function(){
  'use strict';

  /* PRODUCT_DECISION: widget owns its CSS. The .chat-add-topic family
     is small enough that scoping under one class is overkill — these
     selectors only ever match this widget's elements. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-add-topic { display:flex; flex-wrap:wrap; gap:4px; margin-top:8px; }'
      + '.chat-add-topic input { flex:1; min-width:0; padding:3px 6px;'
      +                       ' font-size:12px; border:1px solid #ccc;'
      +                       ' border-radius:3px; font-family:inherit; }'
      + '.chat-add-topic button { padding:3px 8px; font-size:12px; flex:none; }'
      + '.chat-add-topic-err { flex-basis:100%; color:#b00020; font-size:11px; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* PRODUCT_DECISION: same TOPIC_RE the server validates against.
     Catching invalid input client-side keeps the round-trip honest
     for the server-side check. */
  var TOPIC_RE = /^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$/;

  function create(deps){
    ensureStyles();
    var conv      = deps.conv;
    var onCreated = deps.onCreated || function(){};

    var form = document.createElement('form');
    form.className = 'chat-add-topic';
    var input = document.createElement('input');
    input.type = 'text'; input.placeholder = 'new-topic';
    input.autocomplete = 'off'; input.maxLength = 80;
    input.spellcheck = false;
    var btn = document.createElement('button');
    btn.type = 'submit'; btn.textContent = 'Add Topic';
    var err = document.createElement('div');
    err.className = 'chat-add-topic-err';
    form.appendChild(input); form.appendChild(btn); form.appendChild(err);

    form.addEventListener('submit', function(e){
      e.preventDefault();
      var name = input.value.trim();
      if(!TOPIC_RE.test(name)){ err.textContent='Letters, digits, and hyphens only.'; return; }
      err.textContent='';
      /* BROWSER_WORKAROUND: move focus off the button BEFORE we disable
         it. If the button is the active element when it gets
         `disabled=true`, the browser relocates focus to the next
         focusable element (Firefox is especially eager about this),
         which can scrollIntoView and jump the page. Parking focus on
         the input keeps the active element stable through the round-trip. */
      input.focus();
      btn.disabled=true;
      fetch('/chat/c/'+encodeURIComponent(conv)+'/new',{
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'topic='+encodeURIComponent(name),
      }).then(function(r){
        if(r.ok) return r.json();
        return r.text().then(function(t){ throw (t&&t.trim())||('error '+r.status); });
      }).then(function(j){
        /* PRODUCT_DECISION: clear the input + re-enable BEFORE firing
           onCreated. In prod, onCreated navigates the whole page away
           so the cleanup is invisible; in non-navigating callers (the
           /learn demo, future surfaces) the form is left ready for
           another topic. */
        input.value = '';
        btn.disabled = false;
        onCreated(j);
      }).catch(function(msg){
        err.textContent = (typeof msg==='string' ? msg : 'Could not add topic.');
        btn.disabled=false;
      });
    });

    return form;
  }

  return { create:create };
})();
