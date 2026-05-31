/* /chat/code client — thin renderer for the per-user code transcript.
   Server emits the list forward-chronologically at page load; this script
   holds an EventSource on /chat/code/stream and appends one <li> per
   pushed event at the BOTTOM. Click any rendered <pre> → ChatCodePopup.show(text).
   Read-only feed (no selection, nav stack, or keyboard shortcuts). */
(function(){
  'use strict';

  var listEl  = document.getElementById('code-list');
  var emptyEl = document.getElementById('code-empty');
  if(!listEl) return;

  var MONTHS = ['January','February','March','April','May','June',
                'July','August','September','October','November','December'];
  // lint:called-once date-formatter
  function formatWhen(iso){
    /* PRODUCT_DECISION: matches the server-side renderer ("January 2, 2006 15:04",
       UTC) so initial render + SSE upserts format consistently. */
    var d = new Date(iso);
    var hh = d.getUTCHours(), mm = d.getUTCMinutes();
    return MONTHS[d.getUTCMonth()] + ' ' + d.getUTCDate() + ', ' + d.getUTCFullYear() + ' ' +
           (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
  }

  function buildEntry(evt){
    var li = document.createElement('li');
    li.className = 'code-entry';
    li.setAttribute('data-source-id', evt.source_id);

    var meta = document.createElement('div');
    meta.className = 'code-entry-meta';

    var line1 = document.createElement('div'); line1.className = 'code-entry-meta-line';
    var from = document.createElement('span'); from.className = 'code-entry-meta-from';
    from.textContent = 'Sent by ' + evt.from;
    line1.appendChild(from);
    meta.appendChild(line1);

    var line2 = document.createElement('div'); line2.className = 'code-entry-meta-line';
    line2.textContent = formatWhen(evt.at);
    meta.appendChild(line2);

    var line3 = document.createElement('div'); line3.className = 'code-entry-meta-line';
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

    for(var i = 0; i < evt.blocks.length; i++){
      var blk = evt.blocks[i];
      var wrap = document.createElement('div'); wrap.className = 'code-block';
      if(blk.lang){
        var lang = document.createElement('div'); lang.className = 'code-block-lang';
        lang.textContent = blk.lang;
        wrap.appendChild(lang);
      }
      var pre = document.createElement('pre');
      pre.textContent = blk.body;
      wrap.appendChild(pre);
      li.appendChild(wrap);
    }
    return li;
  }

  /* PRODUCT_DECISION: clicking any rendered <pre> opens the shared popup.
     Single delegated listener; the <pre> is the only thing in the entry
     that we hand to ChatCodePopup.show. */
  listEl.addEventListener('click', function(e){
    var pre = e.target.closest && e.target.closest('pre');
    if(pre) ChatCodePopup.show(pre.textContent);
  });

  var es = new EventSource('/chat/code/stream');
  es.onmessage = function(e){
    var evt;
    try { evt = JSON.parse(e.data); }
    catch(err){ console.error('code: malformed JSON from /chat/code/stream', e.data, err); return; }
    if(!evt || !evt.source_id) return;
    /* PRODUCT_DECISION: idempotent on reconnect — duplicate event replaces in place. */
    var existing = listEl.querySelector('li[data-source-id="' + evt.source_id + '"]');
    if(existing){ existing.replaceWith(buildEntry(evt)); return; }
    listEl.appendChild(buildEntry(evt));
    if(emptyEl){ emptyEl.remove(); emptyEl = null; listEl.hidden = false; }
  };
})();
