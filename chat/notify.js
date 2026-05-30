/* PRODUCT_DECISION: per-user SSE notification feed, shared across chat + docs.
   Pings the #chat-notify status line and flips the favicon violet so a
   backgrounded tab still signals unread. No-op on pages without #chat-notify. */
(function(){
  'use strict';
  var notifyEl=document.getElementById('chat-notify');
  if(!notifyEl) return;

  /* BROWSER_WORKAROUND: tab background isn't exposed to JS, so we paint the
     favicon (a 32px canvas, violet on alert / transparent on reset). We
     replace the <link> element each time because some browsers cache by
     node identity and won't repaint on a bare href swap. */
  function paintFavicon(color){
    var c=document.createElement('canvas'); c.width=c.height=32;
    if(color){ var ctx=c.getContext('2d'); ctx.fillStyle=color; ctx.fillRect(0,0,32,32); }
    var old=document.getElementById('favicon'); if(old) old.remove();
    var l=document.createElement('link'); l.id='favicon'; l.rel='icon';
    l.type='image/png'; l.href=c.toDataURL('image/png');
    document.head.appendChild(l);
  }
  function alertTab(){ paintFavicon('#8a2be2'); }
  function clearTab(){ paintFavicon(null); }

  /* PRODUCT_DECISION: suppress pings for the session you're already viewing.
     Only the chat conversation page exposes #chat-root with data-conv/data-session;
     on docs (and elsewhere with #chat-notify) every ping is relevant. */
  var root=document.getElementById('chat-root');
  var CONV=root?root.dataset.conv:null, SESSION=root?root.dataset.session:null;

  var nes=new EventSource('/chat/notifications');
  nes.onmessage=function(e){
    var n; try{ n=JSON.parse(e.data); }catch(err){ console.error('notify: malformed JSON from /chat/notifications', e.data, err); return; }
    if(!n||!n.session) return;
    if(n.conv===CONV && n.session===SESSION) return; /* PRODUCT_DECISION: already in the open feed. */
    notifyEl.textContent='';
    var a=document.createElement('a'); /* PRODUCT_DECISION: textContent only — from/session are untrusted. */
    a.href='/chat/c/'+encodeURIComponent(n.conv)+'/'+encodeURIComponent(n.session);
    a.textContent=n.from+' sent you a message on '+n.session;
    a.addEventListener('click', clearTab);
    notifyEl.appendChild(a);
    alertTab();
  };
})();
