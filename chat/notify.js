/* ChatNotify — owns the #chat-notify status strip + the favicon dot.

   Two write paths land in the strip:
     1) Incoming-message pings from other conversations (this module's
        own SSE on /chat/notifications). Triggers a favicon alert
        because the user is, by definition, NOT looking at that thread.
     2) Self-confirm pings from chat.js when our own message round-trips
        the SSE echo (carries our cid). No favicon paint — we're in
        the tab. Doubles as a low-cost regression check: every send is
        a working live demo of the status bar wiring.

   No-op on pages without #chat-notify (the docs landing has the strip
   too via .docs-notify; everything else just doesn't get the element). */
window.ChatNotify = (function(){
  'use strict';
  var notifyEl = document.getElementById('chat-notify');
  if(!notifyEl) return { show: function(){} };
  /* Pre-refactor the strip sat inside a wrapper that provided this
     gap; the wrapper went away with the Rendered/Transcript toggle.
     Notify owns its own presentation now, including this margin. */
  notifyEl.style.marginBottom = '8px';

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
  // lint:called-once semantic-wrapper
  function alertTab(){ paintFavicon('#8a2be2'); }
  function clearTab(){ paintFavicon(null); }

  /* show(content) — replace the strip's body. `content` is a string
     (plain text) or an Element (e.g. the SSE-ping link). Favicon paint
     is the caller's job — the self-confirm path doesn't want it. */
  function show(content){
    notifyEl.textContent = '';
    if(typeof content === 'string') notifyEl.textContent = content;
    else notifyEl.appendChild(content);
  }

  /* PRODUCT_DECISION: suppress pings for the session you're already viewing.
     Only the chat conversation page exposes #chat-root with data-conv/data-session;
     on docs (and elsewhere with #chat-notify) every ping is relevant. */
  var root=document.getElementById('chat-root');
  var CONV=root?root.dataset.conv:null, SESSION=root?root.dataset.session:null;

  var nes=new EventSource('/chat/notifications');
  nes.onmessage=function(e){
    var n; try{ n=JSON.parse(e.data); }catch(err){ console.error('notify: malformed JSON from /chat/notifications', e.data, err); return; }
    if(!n||!n.text||!n.link_url) return;
    /* INVARIANT: every notify event ships pre-rendered text + link_url
       (a server-side invariant). One render path: wrap
       text in <a href=link_url>. The strip suppresses the update iff
       conv+session match the open feed (no point saying "new message"
       about the thread you're reading). */
    if(n.conv && n.conv===CONV && n.session===SESSION) return;
    var a=document.createElement('a'); /* PRODUCT_DECISION: textContent only — text is untrusted. */
    a.href=n.link_url; a.textContent=n.text;
    a.addEventListener('click', clearTab);
    show(a);
    alertTab();
  };

  return { show: show };
})();
