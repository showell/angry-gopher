/* ChatAddTopic — the "Add Topic" form at the bottom of the left rail.

   One factory: ChatAddTopic.create({conv}) returns a <form> ready to
   drop into a parent. Owns its DOM, its CSS, its validation regex
   (TOPIC_RE — letters/digits/hyphens, no leading or trailing hyphen),
   the POST to /chat/c/<conv>/new, and the redirect on success.

   The form decides nothing about layout — the caller chooses where to
   put it. On success it navigates the whole page to the new session;
   on failure the error line displays under the input. */
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
    var conv = deps.conv;

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
      err.textContent=''; btn.disabled=true;
      fetch('/chat/c/'+encodeURIComponent(conv)+'/new',{
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'topic='+encodeURIComponent(name),
      }).then(function(r){
        if(r.ok) return r.json();
        return r.text().then(function(t){ throw (t&&t.trim())||('error '+r.status); });
      }).then(function(j){
        location.href='/chat/c/'+encodeURIComponent(j.conv)+'/'+encodeURIComponent(j.sid);
      }).catch(function(msg){
        err.textContent = (typeof msg==='string' ? msg : 'Could not add topic.');
        btn.disabled=false;
      });
    });

    return form;
  }

  return { create:create };
})();
