/* ChatFirstTopic — the bootstrap screen for a conversation that is
   addressable (a DM pair you can reach, or a channel you're in) but has no
   topics on disk yet. Renders a short intro + the ChatAddTopic widget
   pre-filled with "general"; on creation it navigates to the new topic.

   Loaded ONLY on the server's thin bootstrap shell, which provides the
   single mount #chat-first-topic[data-conv-base]. Runs directly (the mount
   is guaranteed present on that page). Owns its own DOM + CSS — the server
   ships no markup or styling for this beyond the empty mount. */
(function(){
  'use strict';
  var el = document.getElementById('chat-first-topic');
  var base = el.getAttribute('data-conv-base');

  /* PRODUCT_DECISION: the widget owns its CSS (same posture as
     ChatAddTopic). These selectors only ever match this screen. */
  var style = document.createElement('style');
  style.textContent = ''
    + '.chat-first-topic { max-width:32rem; margin:2rem auto; padding:0 1.25rem; }'
    + '.chat-first-topic h1 { font-size:1.25rem; color:var(--cc-accent,#000080); margin:0 0 .25rem; }'
    + '.chat-first-topic p { color:var(--cc-muted-fg,#888); font-size:14px; margin:.25rem 0 1rem; }';
  document.head.appendChild(style);

  var wrap = document.createElement('div');
  wrap.className = 'chat-first-topic';
  var h = document.createElement('h1');
  h.textContent = 'No topics yet';
  var p = document.createElement('p');
  p.textContent = 'Start the first topic to begin this conversation. '
    + 'Name it anything — letters, digits, and hyphens.';
  wrap.appendChild(h);
  wrap.appendChild(p);

  wrap.appendChild(ChatAddTopic.create({
    convBase: base,
    initialValue: 'general',
    onCreated: function(j){ location.href = base + '/' + j.sid; },
  }));

  el.appendChild(wrap);
})();
