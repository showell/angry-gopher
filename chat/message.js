/* Message — chat-bubble widget.

   A Message instance owns one chat bubble: its DOM, its click routing,
   and the in-place mutations a later "Edit of MSG_<id>" causes. The
   image-zoom and code-monospace popups live at the module level
   because they have no per-instance state — exposed on the public
   surface so other rendering surfaces (search results) can reuse them.

   Styling: Message owns ALL styling for the bubble AND for the HTML
   inside the body. data.html is sanitized server-side and uses a small
   stable vocabulary of classes (chat-body, a.msg-ref, pre.chat-quote,
   etc.); the widget supplies the stylesheet for those classes via a
   one-shot <style> tag injected lazily on first create(). The chat
   conversation page emits no CSS for message DOM — the widget is the
   source of truth.

   Click routing summary:
     image / pre inside body  → ChatImagePopup.show / ChatCodePopup.show
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

  /* ===== styling: one stylesheet, injected once =====
     PRODUCT_DECISION: Message owns every CSS rule that targets the bubble
     it builds AND the server-baked HTML inside .chat-body. Two reasons
     this lives in JS instead of CSS on the page:
       1. :hover and ::-webkit-details-marker / ::before pseudo-elements
          can't go on element.style; an injected <style> tag is the only
          way to keep all the rules in one file.
       2. Dropping this script onto any page makes its messages look
          right, no CSS coordination. The chat page, the search modal
          (it clones .chat-body), and the /learn demo all benefit.
     The IIFE injects on first create() so a page that never instantiates
     a Message pays nothing. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      /* Bubble container + sender/receiver variants. The selection ring
         (toggled by MessageView's mv-selected class) lives in
         chat/message_view.js — it's MessageView's visual concern, not the
         bubble's. */
      + '.chat-msg { margin:0 0 12px; padding:8px 10px; border-radius:8px; max-width:88%; }'
      + '.chat-msg.mine { background:#e7e7ff; margin-left:auto; }'
      + '.chat-msg.theirs { background:#f0f0e6; margin-right:auto; }'
      /* Meta line + action buttons. */
      + '.chat-meta { font-size:11px; color:#888; margin-bottom:3px; }'
      + '.chat-meta .msg-quote, .chat-meta .msg-refer, .chat-meta .msg-edit {'
      +   ' font-size:10px; color:#888; background:none; border:none;'
      +   ' padding:0 2px; cursor:pointer; text-decoration:underline; }'
      + '.chat-meta .msg-quote:hover, .chat-meta .msg-refer:hover, .chat-meta .msg-edit:hover {'
      +   ' color:#000080; }'
      /* Bubble body wrap + classes goldmark + chat post-processing emit. */
      + '.chat-body { overflow-wrap:anywhere; }'
      + '.chat-body p:first-child { margin-top:0; }'
      + '.chat-body p:last-child { margin-bottom:0; }'
      + '.chat-body a.msg-ref {'
      +   ' font-family:ui-monospace,Menlo,Consolas,monospace; font-size:0.9em;'
      +   ' background:#eaeaff; color:#000080; padding:0 4px; border-radius:3px;'
      +   ' text-decoration:none; }'
      + '.chat-body a.msg-ref:hover { background:#d8d8ff; }'
      + '.chat-body pre {'
      +   ' background:#f4f4ec; padding:8px; border-radius:4px;'
      +   ' overflow-x:auto; cursor:pointer; }'
      + '.chat-body pre.chat-quote {'
      +   ' font-family:inherit; white-space:pre-wrap; overflow-wrap:anywhere;'
      +   ' background:#f6f6fb; border-left:3px solid #b9b9e0;'
      +   ' border-radius:0 4px 4px 0; margin:6px 0; padding:6px 10px;'
      +   ' color:#444; overflow-x:visible; }'
      /* PRODUCT_DECISION: width/height:auto so the HTML width/height attrs
         (set by the upload handler) only seed the aspect-ratio hint — the
         max-* still controls actual size. The HTML attrs are there to reserve
         correctly-proportioned space before the image decodes, so the feed
         doesn't reflow upward and yank "scroll-to-bottom" off-target. */
      + '.chat-body img {'
      +   ' max-width:100%; max-height:320px; width:auto; height:auto;'
      +   ' display:block; margin:6px 0; border-radius:6px; cursor:zoom-in; }'
      /* Supersession spoiler (Edit of MSG_<id>). */
      + '.chat-edited-note { font-size:12px; color:#888; margin-bottom:4px; }'
      + '.chat-edited-spoiler > summary {'
      +   ' font-size:11px; color:#888; cursor:pointer; list-style:none; }'
      + '.chat-edited-spoiler > summary::-webkit-details-marker { display:none; }'
      + '.chat-edited-spoiler > summary::before { content:"▸ "; }'
      + '.chat-edited-spoiler[open] > summary::before { content:"▾ "; }'
      + '.chat-edited-orig {'
      +   ' font-size:11px; color:#999; white-space:pre-wrap; overflow-wrap:anywhere;'
      +   ' border-left:3px solid #ddd; padding:2px 0 2px 8px; margin-top:4px; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

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

  /* Image popup lives in chat_image_popup.js; code popup lives in
     chat_code_popup.js. Both are shared with their respective transcript
     views. Use ChatImagePopup.show(src) / ChatCodePopup.show(text) directly. */

  /* ===== instance factory ===== */

  function create(data, deps){
    ensureStyles();
    deps = deps || {};
    var onQuote  = deps.onQuote  || function(){};
    var onRefer  = deps.onRefer  || function(){};
    var onEdit   = deps.onEdit   || function(){};
    var onMsgRef = deps.onMsgRef || function(){};

    var bubble = null;

    // lint:called-once dom-builder-abstraction
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
      if(hit.kind === 'image'){ ChatImagePopup.show(hit.src); return; }
      if(hit.kind === 'pre'){   ChatCodePopup.show(hit.text); return; }
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
      var body=document.createElement('div'); body.className='chat-body';
      body.innerHTML=data.html; /* PRODUCT_DECISION: data.html is sanitized server-side. */
      bubble.appendChild(body);
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
  };
})();
