/* docs.js — autosave + live-render for the /chat/docs editor.
 *
 * Two independently-debounced jobs share the textarea:
 *   - render (~250ms): POST body → /chat/docs/render → swap preview HTML.
 *     Short debounce so the right pane keeps pace with typing.
 *   - save   (~800ms): POST slug+body → /chat/docs/save → 204.
 *     Longer debounce because hitting disk on every keystroke is wasteful;
 *     800ms is barely perceptible and survives short pauses for word
 *     choice.
 *
 * On unload, we synchronously fire any pending save so closing the tab
 * mid-keystroke doesn't lose the last edit.
 */
(function(){
  var ta=document.getElementById('docs-body');
  if(!ta) return; /* the no-doc-selected page omits the textarea entirely */
  var slug=ta.getAttribute('data-slug');
  var preview=document.getElementById('docs-preview');
  var status=document.getElementById('docs-status');

  var renderTimer=null, saveTimer=null;
  var pendingSave=false; /* used by the unload flush */

  function setStatus(cls, text){
    if(!status) return;
    status.className='docs-status '+(cls||'');
    status.textContent=text||'';
  }

  function doRender(){
    var body=ta.value;
    var fd=new FormData(); fd.append('body', body);
    fetch('/chat/docs/render', {method:'POST', body:fd})
      .then(function(r){ return r.ok?r.text():Promise.reject(r.status); })
      .then(function(html){ preview.innerHTML=html; })
      .catch(function(){ /* render failures are silent — keep the last preview */ });
  }

  function doSave(){
    pendingSave=false;
    var body=ta.value;
    setStatus('saving', 'Saving…');
    var fd=new FormData(); fd.append('slug', slug); fd.append('body', body);
    fetch('/chat/docs/save', {method:'POST', body:fd})
      .then(function(r){
        if(r.status===204) setStatus('saved', 'Saved ✓');
        else setStatus('error', 'Save failed ('+r.status+')');
      })
      .catch(function(){ setStatus('error', 'Save failed (offline?)'); });
  }

  ta.addEventListener('input', function(){
    pendingSave=true;
    setStatus('saving', 'Editing…');
    if(renderTimer) clearTimeout(renderTimer);
    renderTimer=setTimeout(doRender, 250);
    if(saveTimer) clearTimeout(saveTimer);
    saveTimer=setTimeout(doSave, 800);
  });

  /* Synchronous flush on unload: a pending save would otherwise be lost
     if the tab closes mid-debounce. sendBeacon is exactly this contract —
     a queued POST the browser ships during teardown. */
  window.addEventListener('beforeunload', function(){
    if(!pendingSave) return;
    var fd=new FormData(); fd.append('slug', slug); fd.append('body', ta.value);
    try { navigator.sendBeacon('/chat/docs/save', fd); } catch(e){}
  });
})();
