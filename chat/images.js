/* /chat/images client — thin renderer for the per-user image transcript.
   Server emits the list in forward-chronological order at page load; this
   script holds an EventSource on /chat/images/stream and appends one <li>
   per pushed event at the BOTTOM (matches transcript order, like the chat
   feed). Click any rendered <img> → ChatImagePopup.show(src). No selection,
   no nav-stack, no keyboard — this is a read-only feed. */
(function(){
  'use strict';

  var listEl  = document.getElementById('images-list');
  var emptyEl = document.getElementById('images-empty');
  if(!listEl) return;

  function buildEntry(evt){
    var li = document.createElement('li');
    li.className = 'images-entry';
    li.setAttribute('data-source-id', evt.source_id);
    var meta = document.createElement('div');
    meta.className = 'images-entry-meta';
    meta.appendChild(document.createTextNode('From '));
    var a = document.createElement('a');
    /* PRODUCT_DECISION: split source_id into <sid>_<n> on the LAST underscore
       (sids may contain hyphens but no underscores by construction). */
    var cut = evt.source_id.lastIndexOf('_');
    var sid = cut > 0 ? evt.source_id.substring(0, cut) : '';
    a.href = '/chat/c/' + encodeURIComponent(evt.conv) +
             (sid ? '/' + encodeURIComponent(sid) + '#msg-' + evt.source_id : '');
    a.textContent = 'MSG_' + evt.source_id;
    meta.appendChild(a);
    meta.appendChild(document.createTextNode(' by ' + evt.from + ' in ' + evt.conv));
    li.appendChild(meta);
    var imgs = document.createElement('div');
    imgs.className = 'images-entry-imgs';
    /* PRODUCT_DECISION: server-supplied <img> tags include sanitized src/alt
       attributes; trust + inject as innerHTML. */
    imgs.innerHTML = evt.images.join('');
    li.appendChild(imgs);
    return li;
  }

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
    if(emptyEl){ emptyEl.remove(); emptyEl = null; listEl.hidden = false; }
  };
})();
