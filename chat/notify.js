/* Shared across the chat + docs pages: a per-user SSE feed that pings on a
   new message in ANY of your sessions, drives the #chat-notify status line,
   and flips the browser-tab favicon violet so a backgrounded tab still shows
   there's something to read. Clicking the status link resets the favicon
   (the click also navigates, so the new page starts clean either way).
   No-op on pages without #chat-notify (Lyn Rummy etc.). */
(function(){
  'use strict';
  var notifyEl=document.getElementById('chat-notify');
  if(!notifyEl) return;

  /* Browsers don't expose the tab's background color to a page, so we paint
     the favicon instead — it's the one tab element we control. A 32px
     canvas: violet on alert, transparent on reset. We replace the whole
     <link> element each time because some browsers cache by node identity
     and won't repaint on a bare href swap. */
  function paintFavicon(color){
    var c=document.createElement('canvas'); c.width=c.height=32;
    if(color){ var ctx=c.getContext('2d'); ctx.fillStyle=color; ctx.fillRect(0,0,32,32); }
    var old=document.getElementById('favicon'); if(old) old.remove();
    var l=document.createElement('link'); l.id='favicon'; l.rel='icon';
    l.type='image/png'; l.href=c.toDataURL('image/png');
    document.head.appendChild(l);
  }
  function alertTab(){ paintFavicon('#8a2be2'); } /* violet */
  function clearTab(){ paintFavicon(null); }       /* transparent */

  /* Suppress the ping for the session you're already viewing. Only the chat
     conversation page exposes #chat-root with data-conv/data-session; on
     docs (and anywhere else with a #chat-notify) every ping is relevant. */
  var root=document.getElementById('chat-root');
  var CONV=root?root.dataset.conv:null, SESSION=root?root.dataset.session:null;

  var nes=new EventSource('/chat/notifications');
  nes.onmessage=function(e){
    var n; try{ n=JSON.parse(e.data); }catch(_){ return; }
    if(!n||!n.session) return;
    if(n.conv===CONV && n.session===SESSION) return; /* already in the open feed */
    notifyEl.textContent='';
    var a=document.createElement('a'); /* textContent only — from/session are untrusted */
    a.href='/chat/c/'+encodeURIComponent(n.conv)+'/'+encodeURIComponent(n.session);
    a.textContent=n.from+' sent you a message on '+n.session;
    a.addEventListener('click', clearTab);
    notifyEl.appendChild(a);
    alertTab();
  };
})();
