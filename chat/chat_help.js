/* PRODUCT_DECISION: keymap drives both keyboard dispatch AND the rendered
   keyhelp panel — one source of truth, no drift. Letter shortcuts are sorted
   alphabetically (no functional grouping); '/' lives at the end as the only
   non-letter. Each shortcut's "button" in the panel is a real <button> that
   triggers the same action as the key — they look pressable AND they are.
   ChatHelp owns the keyhelp CSS — the panel itself, the kbd-look key
   buttons, and their hover/active feedback. */
window.ChatHelp = (function(){
  'use strict';

  /* PRODUCT_DECISION: widget owns its CSS. Movement keys (arrows, Home/End,
     paging, Esc) aren't styled here — they aren't in the panel either,
     they're discoverable. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-keyhelp { margin-top:18px; font-size:13px; color:var(--cc-body-muted-fg); }'
      + '.chat-keyhelp-title { font-weight:bold; color:var(--cc-meta-fg); margin-bottom:7px; }'
      + '.chat-key { margin:5px 0; }'
      + '.chat-keyhelp-key { display:inline-block; min-width:1.1em; text-align:center;'
      +                   ' padding:1px 6px; font-family:ui-monospace,Menlo,Consolas,monospace;'
      +                   ' font-size:12px; color:var(--cc-meta-fg); background:var(--cc-bg);'
      +                   ' border:1px solid var(--cc-border);'
      +                   ' border-bottom-width:2px; border-radius:4px; margin-right:7px;'
      +                   ' cursor:pointer; }'
      + '.chat-keyhelp-key:hover { background:var(--cc-quote-bg); border-color:var(--cc-quote-border); }'
      + '.chat-keyhelp-key:active { background:var(--cc-mine-bg); border-bottom-width:1px;'
      +                          ' transform:translateY(1px); }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  // lint:called-once keymap-source-of-truth
  function shortcuts(deps){
    return [
      { key: 'b', label: 'back',                                requiresSelection: false, action: function(){ deps.back(); } },
      { key: 'c', label: 'compose',                             requiresSelection: false, action: function(){ deps.openCompose(); } },
      { key: 'd', label: 'download transcript + images (.tar.gz)', requiresSelection: false, action: function(){ deps.downloadBundle(); } },
      { key: 'e', label: 'edit selected message',               requiresSelection: true,  action: function(s){ deps.editMessage(s); } },
      { key: 'f', label: 'forward',                             requiresSelection: false, action: function(){ deps.forward(); } },
      { key: 'q', label: 'quote-reply to selected message',     requiresSelection: true,  action: function(s){ deps.quoteReply(s); } },
      { key: 'r', label: 'refer (drop a "See MSG_…" link)',     requiresSelection: true,  action: function(s){ deps.referReply(s); } },
      { key: 's', label: 'save selected message to your reading list', requiresSelection: true, action: function(s){ deps.save(s); } },
      { key: 't', label: 'open the raw transcript in a new tab', requiresSelection: false, action: function(){ deps.viewRaw(); } },
      { key: '/', label: 'search messages',                     requiresSelection: false, action: function(){ ChatSearch.open(); } },
    ];
  }

  /* PRODUCT_DECISION: requiresSelection=true entries silently no-op when no
     bubble is selected (matching the prior behavior — bare key press without
     a selection passes through to the browser, no preventDefault). */
  function dispatch(entry, deps){
    if(entry.requiresSelection){
      var s = deps.getSelectedMessage();
      if(!s) return false;
      entry.action(s);
    } else {
      entry.action();
    }
    return true;
  }

  // lint:called-once panel-renderer
  function renderKeyhelp(entries, deps){
    var box = document.createElement('div');
    box.className = 'chat-keyhelp';
    var title = document.createElement('div');
    title.className = 'chat-keyhelp-title';
    title.textContent = 'Keyboard';
    box.appendChild(title);
    entries.forEach(function(entry){
      var row = document.createElement('div'); row.className = 'chat-key';
      var btn = document.createElement('button');
      btn.type = 'button'; btn.className = 'chat-keyhelp-key';
      btn.textContent = entry.key; btn.title = entry.label;
      btn.addEventListener('click', function(){ dispatch(entry, deps); });
      row.appendChild(btn);
      row.appendChild(document.createTextNode(' ' + entry.label));
      box.appendChild(row);
    });
    return box;
  }

  function init(deps){
    ensureStyles();
    var entries = shortcuts(deps);
    var byKey = Object.create(null);
    entries.forEach(function(entry){ byKey[entry.key] = entry; });

    var panel = document.getElementById('chat-closed-panel');
    if(panel) panel.appendChild(renderKeyhelp(entries, deps));

    document.addEventListener('keydown', function(e){
      var ae = document.activeElement;
      if(ae && (ae.tagName==='TEXTAREA' || ae.tagName==='INPUT' || ae.isContentEditable)) return;
      if(e.ctrlKey || e.metaKey || e.altKey) return;
      var entry = byKey[e.key];
      if(entry && dispatch(entry, deps)) e.preventDefault();
      /* PRODUCT_DECISION: cursor-nav keys (Arrow/Home/End/PgUp/PgDn) are NOT
         handled here — MessageView owns them. ChatHelp dispatches the letter
         shortcuts (panel-visible) only. */
    });
  }
  return { init:init };
})();
