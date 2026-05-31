/* PRODUCT_DECISION: autosave + live-render at the same 1200ms debounce — no
   benefit to a "live" preview costing a request per word; one natural pause
   flushes both. Sync sendBeacon flush on unload so closing mid-keystroke
   doesn't lose the last edit. */
(function(){
  var ta=document.getElementById('docs-body');
  if(!ta) return; /* PRODUCT_DECISION: the no-doc-selected page omits the textarea. */
  var slug=ta.getAttribute('data-slug');
  var preview=document.getElementById('docs-preview');
  var status=document.getElementById('docs-status');

  var renderTimer=null, saveTimer=null;
  var pendingSave=false; /* PRODUCT_DECISION: read by the unload flush. */

  function setStatus(cls, text){
    if(!status) return;
    status.className='docs-status '+(cls||'');
    status.textContent=text||'';
  }

  /* BROWSER_WORKAROUND: x-www-form-urlencoded only. FormData sends multipart,
     which Go's ParseForm doesn't touch — FormValue's ParseMultipartForm fails
     silently under our MaxBytesReader wrap, so the server sees empty fields. */
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
      .catch(function(){ /* PRODUCT_DECISION: silent on render failure — keep the last preview. */ });
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
    renderTimer=setTimeout(doRender, 1200);
    if(saveTimer) clearTimeout(saveTimer);
    saveTimer=setTimeout(doSave, 1200);
  });

  /* BROWSER_WORKAROUND: sendBeacon ships a queued POST during teardown — its
     exact contract. Blob with form-urlencoded type to match the regular save. */
  window.addEventListener('beforeunload', function(){
    if(!pendingSave) return;
    var blob=new Blob([encodeForm({slug:slug, body:ta.value})],
                      {type:'application/x-www-form-urlencoded'});
    try { navigator.sendBeacon('/chat/docs/save', blob); } catch(err){ console.error('docs: sendBeacon failed at unload (size limit, quota, or rate)', err); }
  });

  /* PRODUCT_DECISION: "Post to chat" flushes pending autosave first so disk
     and chat carry the same bytes, then posts via the default-partner
     endpoint (server picks the partner from identity). */
  var postBtn=document.getElementById('docs-post-btn');
  var dlg=document.getElementById('docs-posted-dialog');
  var dlgOk=document.getElementById('docs-posted-ok');
  if(postBtn && dlg && dlgOk){
    var convAfter=null, sessionAfter=null, idAfter=null;
    // lint:called-once named-flow
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
        .then(function(r){ return r.ok?r.json():Promise.reject(r.status); })
        .then(function(j){
          convAfter=j.conv; sessionAfter=j.session; idAfter=j.id;
          setStatus('saved', 'Posted ✓');
          dlg.showModal();
          dlgOk.focus(); /* PRODUCT_DECISION: Enter dismisses; click also works. */
        })
        .catch(function(s){
          setStatus('error', 'Post failed'+(s?' ('+s+')':''));
          postBtn.disabled=false;
        });
    });
    dlgOk.addEventListener('click', function(){
      dlg.close();
      if(convAfter && sessionAfter){
        /* PRODUCT_DECISION: #msg-<id> matches MSG_<session>_<n>; chat.js's
           wantFocus path scrolls + selects + pushes to back/forward. */
        var url='/chat/c/'+encodeURIComponent(convAfter)+'/'+encodeURIComponent(sessionAfter);
        if(idAfter) url += '#msg-'+idAfter;
        location.href=url;
      }
    });
  }
})();
