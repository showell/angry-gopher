/* /chat/images client — thin renderer for the per-user image transcript.

   Server ships the initial entries as inline JSON (#images-data) next to
   the mount slot (#images-mount). This script builds the list via
   ChatStyles helpers, holds an EventSource on /chat/images/stream and
   appends one <li> per pushed event at the BOTTOM. Click any rendered
   <img> → ChatImagePopup.show(src). Read-only feed (no selection, nav
   stack, or keyboard shortcuts). */
(function(){
  'use strict';

  var mount  = document.getElementById('images-mount');
  var dataEl = document.getElementById('images-data');
  if(!mount || !dataEl) return;

  var entries;
  try { entries = JSON.parse(dataEl.textContent); }
  catch(err){ console.error('images: malformed JSON payload', err); return; }
  if(!Array.isArray(entries)) entries = [];

  var listEl = ChatStyles.createTranscriptList();
  mount.appendChild(listEl);

  var emptyEl = document.createElement('p');
  Object.assign(emptyEl.style, { color: ChatColors.mutedFg, textAlign:'center', margin:'24px 0' });
  emptyEl.textContent = 'No images yet.';

  /* PRODUCT_DECISION: per-page image style — natural aspect ratio, capped
     at the entry width and at 320px tall, with a zoom-in cursor matching
     the popup affordance. Set on each <img> as we inject; the server-
     supplied tags carry sanitized src/alt only. */
  var IMG_STYLE = {
    maxWidth:'100%', maxHeight:'320px', width:'auto', height:'auto',
    display:'block', margin:'6px 0', borderRadius:'6px', cursor:'zoom-in',
  };

  /* Lazy image loading, hand-rolled via IntersectionObserver rather than
     the <img loading="lazy"> attribute. "lazy" is viewport-based too, but
     its preload margin is generous and not ours to control (the browser
     fetches images several screens away). This page can hold many large
     images, and we measured that concurrent fetches make aggregate
     throughput WORSE on a slow link — so we want strict control over how
     many load at once. Each <img> is kept src-less (its URL parked in
     data-src) until it comes within LOAD_MARGIN of the viewport; only then
     do we set src and let it fetch. Decode stays off the main thread. */
  var LOAD_MARGIN = '400px 0px';

  function loadNow(img){
    var src = img.getAttribute('data-src');
    if(src){ img.src = src; img.removeAttribute('data-src'); }
  }

  function onIntersect(items){
    for(var i = 0; i < items.length; i++){
      if(items[i].isIntersecting){
        loadNow(items[i].target);
        observer.unobserve(items[i].target);
      }
    }
  }

  /* Older browsers without IntersectionObserver fall back to eager load
     (see buildEntry) so the page never shows blank images. */
  var observer = (typeof IntersectionObserver === 'function')
    ? new IntersectionObserver(onIntersect, { rootMargin: LOAD_MARGIN })
    : null;

  function buildEntry(evt){
    var li = ChatStyles.createTranscriptEntry({
      sourceID: evt.source_id,
      from: evt.from,
      when: ChatStyles.formatTranscriptTime(evt.at),
      sourceURL: evt.source_url,
    });
    var imgs = document.createElement('div');
    /* Parse the server-supplied <img> tags inside an inert <template> so
       they don't fetch on injection (an <img> begins loading the moment it
       has a src, even detached). Rewrite each src -> data-src and style it
       while inert, then move the still-src-less nodes into the live
       container; the observer sets src when each nears the viewport. */
    var tpl = document.createElement('template');
    tpl.innerHTML = evt.images.join('');
    var parsed = tpl.content.querySelectorAll('img');
    for(var i = 0; i < parsed.length; i++){
      Object.assign(parsed[i].style, IMG_STYLE);
      parsed[i].decoding = 'async';
      var src = parsed[i].getAttribute('src');
      if(src){ parsed[i].setAttribute('data-src', src); parsed[i].removeAttribute('src'); }
    }
    imgs.appendChild(tpl.content);
    var ready = imgs.querySelectorAll('img');
    for(var j = 0; j < ready.length; j++){
      if(observer){ observer.observe(ready[j]); }
      else { loadNow(ready[j]); }
    }
    li.appendChild(imgs);
    return li;
  }

  for(var i = 0; i < entries.length; i++) listEl.appendChild(buildEntry(entries[i]));
  if(entries.length === 0) mount.appendChild(emptyEl);

  /* PRODUCT_DECISION: clicking any rendered <img> opens the shared popup.
     Single delegated listener; no per-image binding (cheaper as the list grows). */
  listEl.addEventListener('click', function(e){
    if(e.target.tagName === 'IMG') ChatImagePopup.show(e.target.src);
  });

  var es = new EventSource('/chat/images/stream');
  es.onmessage = function(e){
    var evt;
    try { evt = JSON.parse(e.data); }
    catch(err){ console.error('images: malformed JSON from /chat/images/stream', e.data, err); return; }
    if(!evt || !evt.source_id) return;
    /* PRODUCT_DECISION: idempotent — a duplicate event (e.g. reconnect
       overlap with live append) replaces in place rather than doubling. */
    var existing = listEl.querySelector('li[data-source-id="' + evt.source_id + '"]');
    if(existing){ existing.replaceWith(buildEntry(evt)); return; }
    listEl.appendChild(buildEntry(evt));
    if(emptyEl && emptyEl.parentNode){ emptyEl.remove(); }
  };
})();
