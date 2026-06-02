/* ChatLeftSidebar — the conversation/sessions rail.

   Wire shape: Go ships an inline JSON payload (in a sibling
   <script type="application/json"> next to the mount slot) of three
   ordered arrays: conversations, pinned_sessions, sessions. Each item
   is {id, label, url, active} — labels and links, no rendered HTML.

   Responsibilities:
     - Build the three sections from the payload.
     - Mount the Add Topic form (ChatAddTopic.create — sibling widget).
     - Make each session row draggable (ChatDragToPin.attach — sibling
       widget). When the drag widget reports a drop, we place the item
       and sync the "drag a session here" hint.
     - Subscribe to /chat/sidebar/stream and upsert new partners /
       new topics through the SAME constructors used at first paint.

   Empty-state strings live here (widget-owned UI copy, not data). */
window.ChatLeftSidebar = (function(){
  'use strict';

  var CONV;
  var mount, convList, pinnedList, sessionList;

  /* PRODUCT_DECISION: widget owns its CSS — the rail shell, the three
     sections, the list rows, and the empty-state ".muted / .chat-pin-hint"
     styling. Drag affordance and the Add-Topic form CSS live with their
     respective sibling widgets. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-sidebar { width:180px; flex-shrink:0; overflow-y:auto;'
      +                ' border-right:1px solid #ddd; padding-right:14px;'
      +                ' font-size:13px; }'
      + '.chat-sidebar-section { margin-bottom:18px; }'
      + '.chat-sidebar-title { font-size:11px; text-transform:uppercase;'
      +                      ' letter-spacing:0.05em; color:#888;'
      +                      ' margin-bottom:6px; font-weight:bold; }'
      + '.chat-sidebar-list { list-style:none; padding:0; margin:0; }'
      + '.chat-sidebar-list li { margin:0; }'
      + '.chat-sidebar-list li a { display:block; padding:4px 8px;'
      +                          ' border-radius:3px; color:#000080;'
      +                          ' text-decoration:none; }'
      + '.chat-sidebar-list li a:hover { background:#f0f0ff; }'
      + '.chat-sidebar-list li a.active { background:#000080; color:white;'
      +                                 ' font-weight:bold; }'
      + '.chat-sidebar-list li.muted { color:#888; padding:4px 8px;'
      +                              ' font-style:italic; }'
      + '.chat-pin-hint { font-size:11px; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* ===== row builders =====
     One factory per section; SSE upserts route through the same
     factories so newly-arrived rows look identical to first-paint rows. */

  function makeConvItem(rec){
    var li=document.createElement('li');
    li.setAttribute('data-uid', rec.id);
    var a=document.createElement('a');
    a.href=rec.url; a.textContent=rec.label;
    if(rec.active) a.className='active';
    li.appendChild(a);
    return li;
  }
  function makeSessionItem(rec){
    var li=document.createElement('li');
    li.setAttribute('data-sid', rec.id);
    var a=document.createElement('a');
    a.href=rec.url; a.textContent=rec.label;
    a.setAttribute('draggable','false');
    if(rec.active) a.className='active';
    li.appendChild(a);
    ChatDragToPin.attach(li);
    return li;
  }
  // lint:called-once section-builder
  function buildSection(title, listClass, dataSection, items, emptyHint, itemFn){
    var box=document.createElement('div'); box.className='chat-sidebar-section';
    var t=document.createElement('div'); t.className='chat-sidebar-title';
    t.textContent=title; box.appendChild(t);
    var ul=document.createElement('ul');
    ul.className='chat-sidebar-list'+(listClass?' '+listClass:'');
    ul.setAttribute('data-section', dataSection);
    if(items && items.length){
      for(var i=0;i<items.length;i++) ul.appendChild(itemFn(items[i]));
    } else if(emptyHint){
      var li=document.createElement('li');
      li.className=emptyHint.className||'muted';
      li.textContent=emptyHint.text;
      ul.appendChild(li);
    }
    box.appendChild(ul);
    return { box:box, ul:ul };
  }

  /* PRODUCT_DECISION: keep alphabetical-by-data-sid ordering. Used by
     SSE upserts AND by the drag-drop callback when the gesture lands
     an item in a new section. The selector matches just session rows
     (the muted / pin-hint placeholders carry no data-sid). */
  function insertSorted(ul, li){
    var sid=li.getAttribute('data-sid');
    var items=ul.querySelectorAll('li[data-sid]');
    for(var i=0;i<items.length;i++){
      if(items[i].getAttribute('data-sid')>sid){ ul.insertBefore(li, items[i]); return; }
    }
    ul.appendChild(li);
  }
  /* PRODUCT_DECISION: the "Drag a session here to pin it" hint appears
     when the Pinned list is empty and disappears as soon as something
     lands. The sidebar owns the hint text + class because it's UI
     copy, not gesture state. */
  // lint:called-once drop-callback-hook — runs on optimistic move AND revert
  function syncPinHint(){
    var has=pinnedList.querySelector('li[data-sid]');
    var hint=pinnedList.querySelector('.chat-pin-hint');
    if(has && hint) hint.remove();
    else if(!has && !hint){
      var li=document.createElement('li');
      li.className='muted chat-pin-hint';
      li.textContent='Drag a session here to pin it';
      pinnedList.appendChild(li);
    }
  }

  /* ===== SSE stream — user-arrived, topic-added =====
     PRODUCT_DECISION: server pre-resolves evt.conv to the canonical
     pair-key from THIS recipient's perspective, so we just build the
     link. Idempotent on data-uid / data-sid. */

  // lint:called-once sse-event-handler
  function upsertPartner(evt){
    if(!evt.user_id || !evt.conv) return;
    if(convList.querySelector('li[data-uid="'+evt.user_id+'"]')) return;
    convList.appendChild(makeConvItem({
      id: evt.user_id,
      label: evt.user_name || evt.user_id,
      url: '/chat/c/' + encodeURIComponent(evt.conv),
      active: false,
    }));
  }
  // lint:called-once sse-event-handler
  function upsertSession(evt){
    if(!evt.conv || !evt.sid || evt.conv!==CONV) return;
    if(sessionList.querySelector('li[data-sid="'+evt.sid+'"]')) return;
    var placeholder=sessionList.querySelector('li.muted:not(.chat-pin-hint)');
    if(placeholder) placeholder.remove();
    insertSorted(sessionList, makeSessionItem({
      id: evt.sid,
      label: evt.sid,
      url: '/chat/c/' + encodeURIComponent(CONV) + '/' + encodeURIComponent(evt.sid),
      active: false,
    }));
  }
  // lint:called-once init-section
  function wireSidebarStream(){
    var es=new EventSource('/chat/sidebar/stream');
    es.onmessage=function(e){
      var evt; try{ evt=JSON.parse(e.data); }catch(err){
        console.error('sidebar: malformed JSON from /chat/sidebar/stream', e.data, err); return;
      }
      if(!evt||!evt.kind) return;
      if(evt.kind==='user-arrived') upsertPartner(evt);
      else if(evt.kind==='topic-added') upsertSession(evt);
    };
  }

  function init(deps){
    ensureStyles();
    CONV = deps.conv;
    mount = deps.mount;
    mount.className = 'chat-sidebar';

    /* The drag widget calls back with {item, toUl} on the optimistic
       move AND on the revert if the POST fails. Sidebar owns DOM
       placement (insertSorted) and the empty-pinned hint. */
    ChatDragToPin.init({
      conv: CONV,
      onDrop: function(evt){
        insertSorted(evt.toUl, evt.item);
        syncPinHint();
      },
    });

    var data = deps.data || {};
    var conv = buildSection('Conversations', '', 'conversations',
      data.conversations, null, makeConvItem);
    var pin  = buildSection('Pinned Sessions', 'chat-session-drop', 'pinned',
      data.pinned_sessions,
      { className: 'muted chat-pin-hint', text: 'Drag a session here to pin it' },
      makeSessionItem);
    var ses  = buildSection('Sessions', 'chat-session-drop', 'sessions',
      data.sessions,
      { className: 'muted', text: 'No sessions yet' },
      makeSessionItem);

    convList    = conv.ul;
    pinnedList  = pin.ul;
    sessionList = ses.ul;

    mount.appendChild(conv.box);
    mount.appendChild(pin.box);
    mount.appendChild(ses.box);
    mount.appendChild(ChatAddTopic.create({ conv: CONV }));

    wireSidebarStream();
  }
  return { init:init };
})();
