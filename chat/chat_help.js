/* PRODUCT_DECISION: keymap drives both keyboard dispatch AND the rendered
   keyhelp panel — one source of truth, no drift. Letter shortcuts are sorted
   alphabetically (no functional grouping); '/' lives at the end as the only
   non-letter. Each shortcut's "button" in the panel is a real <button> that
   triggers the same action as the key — they look pressable AND they are. */
window.ChatHelp = (function(){
  'use strict';

  function shortcuts(deps){
    return [
      { key: 'b', label: 'back',                                requiresSelection: false, action: function(){ deps.backBtn.click(); } },
      { key: 'c', label: 'compose',                             requiresSelection: false, action: function(){ deps.openCompose(); } },
      { key: 'e', label: 'edit selected message',               requiresSelection: true,  action: function(s){ deps.editMessage(s); } },
      { key: 'f', label: 'forward',                             requiresSelection: false, action: function(){ deps.fwdBtn.click(); } },
      { key: 'q', label: 'quote-reply to selected message',     requiresSelection: true,  action: function(s){ deps.quoteReply(s); } },
      { key: 'r', label: 'refer (drop a "See MSG_…" link)',     requiresSelection: true,  action: function(s){ deps.referReply(s); } },
      { key: 't', label: 'toggle rendered / transcript',        requiresSelection: false, action: function(){ deps.toggleView(); } },
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
