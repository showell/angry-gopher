/* Message — exploratory abstraction (NOT wired into chat.js).

   A Message instance owns one chat bubble: its DOM, its click routing,
   and the in-place mutations a later "Edit of MSG_<id>" causes. The
   image-zoom and code-monospace popups live at the module level
   because they have no per-instance state — exposed on the public
   surface so other rendering surfaces (search results) can reuse them.

   Click routing summary:
     image / pre inside body  → internal (showImagePopup / showCodePopup)
     msg-ref link inside body → deps.onMsgRef(linkEl)   (domain navigation)
     quote-reply button       → deps.onQuote(msg)        (affects compose)
     refer button             → deps.onRefer(msg)        (affects compose)
     edit button              → deps.onEdit(msg)         (affects compose)
     external <a> / plain     → no-op (browser default + bubble up)

   Clicks never stopPropagation, so an outer container listener
   (MessageView) still sees the click and can update selection.

   Usage sketch:

     var msg = Message.create(m, {
       onQuote:  function(msg){ if(!ChatCompose.isPending()) doQuote(msg); },
       onRefer:  function(msg){ if(!ChatCompose.isPending()) doRefer(msg); },
       onEdit:   function(msg){ if(!ChatCompose.isPending()) doEdit(msg); },
       onMsgRef: function(link){ navigateRef(link); },
     });
     container.appendChild(msg.render());

     // Later, when a new "Edit of MSG_<id>" message arrives:
     original.markEdited(newMsg.getId());

     // From elsewhere (e.g. search results):
     Message.showImagePopup(someImgSrc);
*/

window.Message = (function(){
  'use strict';

  /* ===== module-level body-click classifier =====
     PRODUCT_DECISION: shared classifier so every surface that renders a
     chat body (the feed via Message, the search-results modal) has ONE
     notion of "what did you click" and only has to decide the few behaviors
     that genuinely differ between them. */
  function classifyBodyClick(t){
    if(t.tagName === 'IMG') return {kind:'image', src:t.src};
    var pre = t.closest && t.closest('pre');
    if(pre) return {kind:'pre', text:pre.textContent};
    var ref = t.closest && t.closest('a.msg-ref');
    if(ref) return {kind:'msgref', el:ref};
    if(t.closest && t.closest('a')) return {kind:'link'};
    return {kind:'plain'};
  }

  /* ===== module-level popups ===== */

  /* PRODUCT_DECISION: image popup — slider scales height, scroll to pan.
     fitW/fitH = largest size that fits the fixed container; the slider
     multiplies. Overflowing into scroll when >1. */
  function showImagePopup(src){
    var dlg=document.createElement('dialog'); dlg.className='chat-img-dialog';
    var controls=document.createElement('div'); controls.className='chat-img-controls';
    var range=document.createElement('input'); range.type='range';
    range.min='1'; range.max='8'; range.step='0.05'; range.value='1';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click', function(){ dlg.close(); });
    controls.appendChild(range); controls.appendChild(close);
    var scroll=document.createElement('div'); scroll.className='chat-img-scroll';
    var img=document.createElement('img'); img.alt='';
    scroll.appendChild(img);
    dlg.appendChild(controls); dlg.appendChild(scroll);
    dlg.addEventListener('close', function(){ dlg.remove(); });
    document.body.appendChild(dlg);
    var fitW=0, fitH=0;
    function applyZoom(){
      if(!fitW) return;
      var z=parseFloat(range.value);
      img.style.width=(fitW*z)+'px'; img.style.height=(fitH*z)+'px';
    }
    function fit(){
      var cw=scroll.clientWidth, ch=scroll.clientHeight, nw=img.naturalWidth, nh=img.naturalHeight;
      if(!cw||!ch||!nw||!nh) return;
      var s=Math.min(cw/nw, ch/nh);
      fitW=nw*s; fitH=nh*s; applyZoom();
    }
    range.addEventListener('input', applyZoom);
    dlg.showModal();
    img.addEventListener('load', fit);
    img.src=src;
    if(img.complete) fit();
  }

  /* PRODUCT_DECISION: code popup — dialog is fit-content (CSS) capped at
     80vw/80vh; the <pre> scrolls when the code is larger. Backdrop click
     and Esc both close. */
  function showCodePopup(text){
    var dlg=document.createElement('dialog'); dlg.className='chat-code-dialog';
    var controls=document.createElement('div'); controls.className='chat-code-controls';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click', function(){ dlg.close(); });
    controls.appendChild(close);
    var pre=document.createElement('pre'); pre.className='chat-code-view'; pre.textContent=text;
    dlg.appendChild(controls); dlg.appendChild(pre);
    dlg.addEventListener('close', function(){ dlg.remove(); });
    dlg.addEventListener('click', function(e){ if(e.target===dlg) dlg.close(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  /* ===== instance factory ===== */

  function create(data, deps){
    deps = deps || {};
    var onQuote  = deps.onQuote  || function(){};
    var onRefer  = deps.onRefer  || function(){};
    var onEdit   = deps.onEdit   || function(){};
    var onMsgRef = deps.onMsgRef || function(){};

    var bubble = null;

    function buildMeta(){
      var meta=document.createElement('div'); meta.className='chat-meta';
      meta.appendChild(document.createTextNode('#'+(data.index+1)+' '+data.from+' · '+data.time+' '));
      var quote=document.createElement('button'); quote.type='button'; quote.className='msg-quote';
      quote.title='Quote this message in a reply (q)'; quote.textContent='quote-reply';
      meta.appendChild(quote);
      meta.appendChild(document.createTextNode(' '));
      var refer=document.createElement('button'); refer.type='button'; refer.className='msg-refer';
      refer.title='Drop a "See MSG_…" reference into the compose box without quoting (r)'; refer.textContent='refer';
      meta.appendChild(refer);
      meta.appendChild(document.createTextNode(' '));
      var edit=document.createElement('button'); edit.type='button'; edit.className='msg-edit';
      edit.title='Load this message back into compose with an "Edit of MSG_…" backlink (e)'; edit.textContent='edit';
      meta.appendChild(edit);
      return meta;
    }
    function buildBody(){
      var body=document.createElement('div'); body.className='chat-body';
      body.innerHTML=data.html; /* PRODUCT_DECISION: data.html is sanitized server-side. */
      return body;
    }

    /* PRODUCT_DECISION: one listener per bubble. The walk-up classification
       happens inside the handler; never stops propagation, so a container
       listener (e.g. MessageView) still sees the click for its own purposes
       (selection update). */
    function handleClick(e){
      var t = e.target;
      if(t.closest && t.closest('.msg-quote')){ onQuote(api); return; }
      if(t.closest && t.closest('.msg-refer')){ onRefer(api); return; }
      if(t.closest && t.closest('.msg-edit')){  onEdit(api);  return; }
      if(!t.closest || !t.closest('.chat-body')) return;
      var hit = classifyBodyClick(t);
      if(hit.kind === 'image'){ showImagePopup(hit.src); return; }
      if(hit.kind === 'pre'){   showCodePopup(hit.text); return; }
      if(hit.kind === 'msgref'){ e.preventDefault(); onMsgRef(hit.el); return; }
      /* PRODUCT_DECISION: external link uses server-baked target=_blank; plain hit does nothing. */
    }

    function render(){
      bubble=document.createElement('div');
      bubble.className='chat-msg '+(data.mine?'mine':'theirs');
      bubble.id='msg-'+data.id;
      bubble.setAttribute('data-i',  data.index);
      bubble.setAttribute('data-id', data.id);
      bubble.appendChild(buildMeta());
      bubble.appendChild(buildBody());
      bubble.addEventListener('click', handleClick);
      return bubble;
    }

    /* PRODUCT_DECISION: in-place supersession when a later "Edit of MSG_<id>"
       arrives — render an "Edited in MSG_<editID>" link, demote the original
       body into a spoiler. Append-only: the on-disk record + transcript view
       still show both byte-for-byte. */
    function markEdited(editID){
      if(!bubble) return;
      var bodyEl=bubble.querySelector('.chat-body'); if(!bodyEl) return;
      bodyEl.textContent='';
      var note=document.createElement('div'); note.className='chat-edited-note';
      note.appendChild(document.createTextNode('Edited in '));
      var link=document.createElement('a'); link.className='msg-ref'; link.href='#msg-'+editID;
      link.textContent='MSG_'+editID; note.appendChild(link);
      var spoiler=document.createElement('details'); spoiler.className='chat-edited-spoiler';
      var summary=document.createElement('summary'); summary.textContent='original'; spoiler.appendChild(summary);
      var orig=document.createElement('div'); orig.className='chat-edited-orig';
      orig.textContent=data.body;
      spoiler.appendChild(orig);
      bodyEl.appendChild(note); bodyEl.appendChild(spoiler);
    }

    var api = {
      render:      render,
      markEdited:  markEdited,
      getElement:  function(){ return bubble; },
      getId:       function(){ return data.id; },
      getIndex:    function(){ return data.index; },
      getBody:     function(){ return data.body; },
      isMine:      function(){ return data.mine; },
    };
    return api;
  }

  return {
    create:             create,
    classifyBodyClick:  classifyBodyClick,
    showImagePopup:     showImagePopup,
    showCodePopup:      showCodePopup,
  };
})();
