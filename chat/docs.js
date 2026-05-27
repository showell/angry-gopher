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

  /* Posts go as application/x-www-form-urlencoded (matching chat.js).
     FormData would send multipart, which Go's ParseForm doesn't touch —
     FormValue then tries ParseMultipartForm, but our MaxBytesReader wrap
     makes that fail silently, so the server would see empty fields. */
  var FORM_HDR={'Content-Type':'application/x-www-form-urlencoded'};
  function encodeForm(pairs){
    var parts=[];
    for(var k in pairs) parts.push(encodeURIComponent(k)+'='+encodeURIComponent(pairs[k]));
    return parts.join('&');
  }

  function doRender(){
    fetch('/chat/docs/render', {method:'POST', headers:FORM_HDR,
                                body:encodeForm({body:ta.value})})
      .then(function(r){ return r.ok?r.text():Promise.reject(r.status); })
      .then(function(html){ preview.innerHTML=html; })
      .catch(function(){ /* render failures are silent — keep the last preview */ });
  }

  function doSave(){
    pendingSave=false;
    setStatus('saving', 'Saving…');
    fetch('/chat/docs/save', {method:'POST', headers:FORM_HDR,
                              body:encodeForm({slug:slug, body:ta.value})})
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
     a queued POST the browser ships during teardown. Wrap the body in a
     Blob with form-urlencoded content-type to match the regular save. */
  window.addEventListener('beforeunload', function(){
    if(!pendingSave) return;
    var blob=new Blob([encodeForm({slug:slug, body:ta.value})],
                      {type:'application/x-www-form-urlencoded'});
    try { navigator.sendBeacon('/chat/docs/save', blob); } catch(e){}
  });

  /* "Post to chat" — send the doc body as a chat message to the default
     partner (server picks based on identity, returns the partner id as the
     response body), confirm via modal, then navigate to the chat on OK.
     Flush any pending autosave first so disk + chat carry the same bytes. */
  var postBtn=document.getElementById('docs-post-btn');
  var dlg=document.getElementById('docs-posted-dialog');
  var dlgOk=document.getElementById('docs-posted-ok');
  if(postBtn && dlg && dlgOk){
    var partnerAfter=null;
    function flushPendingSave(){
      if(!pendingSave) return Promise.resolve();
      if(saveTimer){ clearTimeout(saveTimer); saveTimer=null; }
      pendingSave=false;
      return fetch('/chat/docs/save', {method:'POST', headers:FORM_HDR,
                                       body:encodeForm({slug:slug, body:ta.value})});
    }
    postBtn.addEventListener('click', function(){
      postBtn.disabled=true;
      setStatus('saving', 'Posting…');
      flushPendingSave()
        .then(function(){ return fetch('/chat/docs/post', {method:'POST', headers:FORM_HDR,
                                                           body:encodeForm({slug:slug})}); })
        .then(function(r){ return r.ok?r.text():Promise.reject(r.status); })
        .then(function(partner){
          partnerAfter=partner;
          setStatus('saved', 'Posted ✓');
          dlg.showModal();
          dlgOk.focus(); /* Enter dismisses; click also works */
        })
        .catch(function(s){
          setStatus('error', 'Post failed'+(s?' ('+s+')':''));
          postBtn.disabled=false;
        });
    });
    dlgOk.addEventListener('click', function(){
      dlg.close();
      if(partnerAfter) location.href='/chat?with='+encodeURIComponent(partnerAfter);
    });
  }
})();
