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

  var MONTHS = ['January','February','March','April','May','June',
                'July','August','September','October','November','December'];
  // lint:called-once date-formatter
  function formatWhen(iso){
    /* PRODUCT_DECISION: matches the server-side renderer ("January 2, 2006 15:04",
       UTC) — initial render + SSE upserts share one format so the page reads
       consistently when both old + new entries are visible. */
    var d = new Date(iso);
    var hh = d.getUTCHours(), mm = d.getUTCMinutes();
    return MONTHS[d.getUTCMonth()] + ' ' + d.getUTCDate() + ', ' + d.getUTCFullYear() + ' ' +
           (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
  }

  function buildEntry(evt){
    var li = document.createElement('li');
    li.className = 'images-entry';
    li.setAttribute('data-source-id', evt.source_id);

    var meta = document.createElement('div');
    meta.className = 'images-entry-meta';

    var line1 = document.createElement('div'); line1.className = 'images-entry-meta-line';
    var from = document.createElement('span'); from.className = 'images-entry-meta-from';
    from.textContent = 'Sent by ' + evt.from;
    line1.appendChild(from);
    meta.appendChild(line1);

    var line2 = document.createElement('div'); line2.className = 'images-entry-meta-line';
    line2.textContent = formatWhen(evt.at);
    meta.appendChild(line2);

    var line3 = document.createElement('div'); line3.className = 'images-entry-meta-line';
    line3.appendChild(document.createTextNode('From '));
    var a = document.createElement('a');
    /* PRODUCT_DECISION: split source_id into <sid>_<n> on the LAST underscore
       (sids may contain hyphens but no underscores by construction). */
    var cut = evt.source_id.lastIndexOf('_');
    var sid = cut > 0 ? evt.source_id.substring(0, cut) : '';
    a.href = '/chat/c/' + encodeURIComponent(evt.conv) +
             (sid ? '/' + encodeURIComponent(sid) + '#msg-' + evt.source_id : '');
    a.textContent = 'MSG_' + evt.source_id;
    line3.appendChild(a);
    meta.appendChild(line3);

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
