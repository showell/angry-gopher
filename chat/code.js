/* /chat/code client — thin renderer for the per-user code transcript.

   Server ships the initial entries as inline JSON (#code-data) next to
   the mount slot (#code-mount). This script builds the list via
   ChatStyles helpers, holds an EventSource on /chat/code/stream and
   appends one <li> per pushed event at the BOTTOM. Click any rendered
   <pre> → ChatCodePopup.show(text). Read-only feed (no selection, nav
   stack, or keyboard shortcuts). */
(function(){
  'use strict';

  var mount  = document.getElementById('code-mount');
  var dataEl = document.getElementById('code-data');
  if(!mount || !dataEl) return;

  var entries;
  try { entries = JSON.parse(dataEl.textContent); }
  catch(err){ console.error('code: malformed JSON payload', err); return; }
  if(!Array.isArray(entries)) entries = [];

  var listEl = ChatStyles.createTranscriptList();
  mount.appendChild(listEl);

  var emptyEl = document.createElement('p');
  Object.assign(emptyEl.style, { color: ChatColors.mutedFg, textAlign:'center', margin:'24px 0' });
  emptyEl.textContent = 'No code blocks yet.';

  /* PRODUCT_DECISION: the code-block styling lives inline in buildEntry —
     this page is the only consumer, and inlining keeps the per-block
     visual contract (wrapper / lang strap / <pre>) in one read. */
  function buildEntry(evt){
    var li = ChatStyles.createTranscriptEntry({
      sourceID: evt.source_id,
      from: evt.from,
      when: ChatStyles.formatTranscriptTime(evt.at),
      sourceURL: evt.source_url,
    });
    for(var i = 0; i < evt.blocks.length; i++){
      var blk = evt.blocks[i];
      var wrap = document.createElement('div');
      Object.assign(wrap.style, {
        margin:'8px 0', border:'1px solid '+ChatColors.border, borderRadius:'6px',
        overflow:'hidden', background: ChatColors.bg,
      });
      if(blk.lang){
        var lang = document.createElement('div');
        Object.assign(lang.style, {
          fontSize:'11px', textTransform:'uppercase', letterSpacing:'0.05em',
          color: ChatColors.mutedFg, padding:'4px 12px', background: ChatColors.codeStrapBg,
          borderBottom:'1px solid '+ChatColors.softBorder,
        });
        lang.textContent = blk.lang;
        wrap.appendChild(lang);
      }
      var pre = document.createElement('pre');
      Object.assign(pre.style, {
        margin:'0', padding:'10px 14px', maxHeight:'360px', overflow:'auto',
        fontFamily:'ui-monospace, Menlo, Consolas, monospace',
        fontSize:'13px', lineHeight:'1.45', color: ChatColors.codeFg, cursor:'zoom-in',
      });
      pre.textContent = blk.body;
      wrap.appendChild(pre);
      li.appendChild(wrap);
    }
    return li;
  }

  for(var i = 0; i < entries.length; i++) listEl.appendChild(buildEntry(entries[i]));
  if(entries.length === 0) mount.appendChild(emptyEl);

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
    if(emptyEl && emptyEl.parentNode){ emptyEl.remove(); }
  };
})();
