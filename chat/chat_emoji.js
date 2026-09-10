/* ChatEmoji — the emoji whitelist and the compose-box autocomplete.

   PRODUCT_DECISION: emoji are a CLIENT feature. The list below is the ONE
   authority; the server never sees a shortcode. Typing `:na` in the compose
   box opens a menu of matching names; accepting an entry (Enter / Tab /
   click) or typing the closing colon on an exact name (`:tada:`) replaces
   the shortcode with the unicode glyph IN THE TEXTAREA — so the message
   body that reaches the server already holds the glyph, and markdown
   passes it through like any other text. Names are lowercase [a-z0-9]+
   only. Every glyph is one codepoint (plus a variation selector where the
   base character is text-presentation by default), no ZWJ sequences, no
   skin tones, no flags.

   The trigger is `:` at the start of the text or after whitespace, so
   `12:30`, `http://` and `a:b` never open the menu.

   Self-contained: owns its DOM (one fixed-position menu, anchored to the
   textarea it is attached to) and injects its own CSS once. Attach with
   `ChatEmoji.attach(textarea)`. */
window.ChatEmoji = (function(){
  'use strict';

  /* PRODUCT_DECISION: menu order = this order. Reactions land next and reuse
     the same names, so the list leads with the reaction-flavored set. */
  var EMOJI = [
    { name: 'smile',      glyph: '😄' },
    { name: 'joy',        glyph: '😂' },
    { name: 'sob',        glyph: '😭' },
    { name: 'wink',       glyph: '😉' },
    { name: 'thinking',   glyph: '🤔' },
    { name: 'thumbsup',   glyph: '👍' },
    { name: 'thumbsdown', glyph: '👎' },
    { name: 'heart',      glyph: '❤️' }, /* red heart is text-presentation without VS16 */
    { name: 'tada',       glyph: '🎉' },
    { name: 'rocket',     glyph: '🚀' },
    { name: 'fire',       glyph: '🔥' },
    { name: 'eyes',       glyph: '👀' },
    { name: '100',        glyph: '💯' },
    { name: 'check',      glyph: '✅' },
    { name: 'wave',       glyph: '👋' },
    /* fitness */
    { name: 'muscle',     glyph: '💪' },
    { name: 'run',        glyph: '🏃' },
    { name: 'bike',       glyph: '🚴' },
    { name: 'swim',       glyph: '🏊' },
    /* money */
    { name: 'moneybag',   glyph: '💰' },
    { name: 'dollar',     glyph: '💵' },
    { name: 'chartup',    glyph: '📈' },
    { name: 'chartdown',  glyph: '📉' },
    /* robots */
    { name: 'robot',      glyph: '🤖' },
    { name: 'invader',    glyph: '👾' },
    { name: 'brain',      glyph: '🧠' }
  ];
  var MAX_ROWS = 8;

  /* PRODUCT_DECISION: widget owns its CSS. Tokens only — no hex here. */
  var stylesInjected = false;
  // lint:called-once init-once-guard
  function ensureStyles(){
    if(stylesInjected) return;
    var s = document.createElement('style');
    s.textContent = ''
      + '.chat-emoji-menu { position:fixed; z-index:20; box-sizing:border-box;'
      +                  ' background:var(--cc-card-bg); color:var(--cc-fg);'
      +                  ' border:1px solid var(--cc-dialog-border); border-radius:6px;'
      +                  ' padding:4px 0; font-size:14px; box-shadow:0 4px 14px var(--cc-backdrop); }'
      + '.chat-emoji-row { display:flex; align-items:center; gap:10px; padding:4px 12px; cursor:pointer; }'
      + '.chat-emoji-row.chat-emoji-sel { background:var(--cc-search-sel-bg); }'
      + '.chat-emoji-glyph { width:1.4em; text-align:center; }'
      + '.chat-emoji-name { color:var(--cc-muted-fg); font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; }';
    document.head.appendChild(s);
    stylesInjected = true;
  }

  /* The shortcode under the caret: {start, query} where `start` indexes the
     opening colon, or null when the caret is not inside a `:name` run. */
  function shortcodeAtCaret(textarea){
    var s = textarea.selectionStart;
    if(s !== textarea.selectionEnd) return null;
    var m = /(^|\s):([a-z0-9]*)$/.exec(textarea.value.slice(0, s));
    if(!m) return null;
    return { start: m.index + m[1].length, query: m[2] };
  }

  // lint:called-once whitelist-lookup
  function matches(query){
    var out = [];
    for(var i = 0; i < EMOJI.length && out.length < MAX_ROWS; i++){
      if(EMOJI[i].name.indexOf(query) === 0) out.push(EMOJI[i]);
    }
    return out;
  }

  // lint:called-once whitelist-lookup
  function exactMatch(query){
    for(var i = 0; i < EMOJI.length; i++) if(EMOJI[i].name === query) return EMOJI[i];
    return null;
  }

  function attach(textarea){
    ensureStyles();
    var menu = null;      /* the open <div>, or null */
    var rows = [];        /* the current match list, parallel to the menu's children */
    var sel = 0;          /* highlighted row */
    var hit = null;       /* the shortcode the menu was opened for */

    function close(){
      if(menu) menu.remove();
      menu = null; rows = []; sel = 0; hit = null;
    }

    /* Replace the `:query` run with the glyph (+ `tail`), caret after it. */
    function accept(entry, tail){
      textarea.setRangeText(entry.glyph + tail, hit.start, textarea.selectionStart, 'end');
      close();
      textarea.focus();
    }

    function paint(){
      for(var i = 0; i < menu.children.length; i++){
        menu.children[i].classList.toggle('chat-emoji-sel', i === sel);
      }
    }

    /* PRODUCT_DECISION: anchored to the textarea's bottom-left as a fixed
       overlay, so it works wherever the textarea sits (the chat rail, the
       /learn demo) without the host reserving layout for it. */
    // lint:called-once menu-renderer
    function render(){
      if(!menu){
        menu = document.createElement('div');
        menu.className = 'chat-emoji-menu';
        document.body.appendChild(menu);
      }
      menu.textContent = '';
      rows.forEach(function(entry, i){
        var row = document.createElement('div');
        row.className = 'chat-emoji-row';
        var g = document.createElement('span'); g.className = 'chat-emoji-glyph'; g.textContent = entry.glyph;
        var n = document.createElement('span'); n.className = 'chat-emoji-name'; n.textContent = ':' + entry.name + ':';
        row.appendChild(g); row.appendChild(n);
        /* mousedown, not click: click would first blur the textarea and close us. */
        row.addEventListener('mousedown', function(e){ e.preventDefault(); accept(entry, ' '); });
        row.addEventListener('mousemove', function(){ if(sel !== i){ sel = i; paint(); } });
        menu.appendChild(row);
      });
      paint();
      var r = textarea.getBoundingClientRect();
      menu.style.left = (r.left + 6) + 'px';
      menu.style.width = Math.max(120, r.width - 12) + 'px';
      menu.style.top = '';
      menu.style.bottom = (window.innerHeight - r.bottom + 6) + 'px';
    }

    /* Re-read the caret after every edit: open, narrow, or close the menu. */
    function refresh(){
      var h = shortcodeAtCaret(textarea);
      var list = (h && h.query.length > 0) ? matches(h.query) : [];
      if(list.length === 0){ close(); return; }
      if(!hit || hit.start !== h.start) sel = 0;
      hit = h; rows = list;
      if(sel >= rows.length) sel = 0;
      render();
    }

    textarea.addEventListener('input', refresh);
    textarea.addEventListener('click', refresh);
    textarea.addEventListener('blur', close);
    textarea.addEventListener('keydown', function(e){
      if(e.ctrlKey || e.metaKey || e.altKey){ close(); return; } /* Ctrl/⌘-Enter sends; never sit over a sent box. */
      if(e.key === ':'){
        /* Closing colon on an exact name completes it in place — no menu needed. */
        var h = shortcodeAtCaret(textarea);
        var exact = h && exactMatch(h.query);
        if(exact){ e.preventDefault(); hit = h; accept(exact, ''); }
        return;
      }
      if(!menu) return;
      if(e.key === 'ArrowDown'){ e.preventDefault(); sel = (sel + 1) % rows.length; paint(); }
      else if(e.key === 'ArrowUp'){ e.preventDefault(); sel = (sel + rows.length - 1) % rows.length; paint(); }
      else if(e.key === 'Enter' || e.key === 'Tab'){ e.preventDefault(); accept(rows[sel], ' '); }
      else if(e.key === 'Escape'){ e.preventDefault(); close(); }
    });
  }

  return { attach: attach };
})();
