/* ChatColors — palette + theme toggle, shared by every /chat page.

   PRODUCT_DECISION: the palette lives in ONE place (this file) as CSS
   custom properties (`--cc-...`). Per-widget inline styles reference
   the variables (`el.style.color = ChatColors.mutedFg` evaluates to
   `var(--cc-muted-fg)`). To flip the theme, set
   `data-theme="dark"` on <html> — the cascade does the rest, no
   re-render needed.

   Public surface:
     ChatColors.install()  → call once at the top of <body>.
                             Reads localStorage, sets data-theme on
                             <html>, injects the palette <style>.
     ChatColors.toggle()   → flip data-theme, save, return new value.
     ChatColors.<token>    → string usable in inline styles,
                             e.g. ChatColors.mutedFg = 'var(--cc-muted-fg)'.

   New colors go through this file — if you find yourself typing a
   hex outside of here, the token list probably needs another entry. */
window.ChatColors = (function(){
  'use strict';

  var STYLE_ID = 'chat-colors-style';
  var STORAGE  = 'chat-theme';

  /* PRODUCT_DECISION: palette assembled as a JS object so the SAME shape
     drives both the <style> block (string-join below) and any future
     JS that needs to read a raw hex (e.g. canvas colors). One source. */
  var LIGHT = {
    fg:            '#111',
    mutedFg:       '#888',
    softMutedFg:   '#999',
    bodyMutedFg:   '#444',
    metaFg:        '#333',
    accent:        '#000080',
    accentHover:   '#0000a0',
    accentSoftBg:  '#eaeaff',
    accentSoftHov: '#d8d8ff',
    bg:            '#fff',
    cardBg:        '#fafafa',
    mineBg:        '#e7e7ff',
    theirsBg:      '#f0f0e6',
    quoteBg:       '#f6f6fb',
    quoteBorder:   '#b9b9e0',
    codeBg:        '#f4f4ec',
    codeStrapBg:   '#faf9f5',
    codeFg:        '#222',
    border:        '#ddd',
    softBorder:    '#e0e0e0',
    dialogBorder:  '#bbb',
    inputBorder:   '#e3e3ef',
    searchSelBg:   '#eef0ff',
    searchTokFg:   '#23235a',
    searchMarkBg:  '#ffe680',
    error:         '#b00020',
    savedFg:       '#1a7a3a',
    backdrop:      'rgba(0,0,0,0.4)',
    notifyFg:      '#1a5fb4',
    topBarBg:      '#f0ede4',
    topBarBorder:  '#c9bfa7',
    /* Presence dots — dedicated tokens so the indicator vocabulary
       doesn't ride on accent/error. Idle = hollow circle outlined in
       blue; online = solid green fill. */
    presenceIdle:   '#3b82f6',
    presenceOnline: '#22c55e',
  };

  /* GitHub-ish dark with bubble colors picked to keep mine-vs-theirs
     readable (a desaturated blue vs a desaturated warm gray). */
  var DARK = {
    fg:            '#e6edf3',
    mutedFg:       '#8b949e',
    softMutedFg:   '#7d8590',
    bodyMutedFg:   '#9aa4ae',
    metaFg:        '#b8c0c8',
    accent:        '#58a6ff',
    accentHover:   '#79b8ff',
    accentSoftBg:  '#1f2d4a',
    accentSoftHov: '#28395e',
    bg:            '#0d1117',
    cardBg:        '#161b22',
    mineBg:        '#1c2433',
    theirsBg:      '#22221c',
    quoteBg:       '#161b22',
    quoteBorder:   '#3a3a5c',
    codeBg:        '#1a1f26',
    codeStrapBg:   '#13171d',
    codeFg:        '#e6edf3',
    border:        '#30363d',
    softBorder:    '#272c33',
    dialogBorder:  '#3a3f47',
    inputBorder:   '#30363d',
    searchSelBg:   '#1f2d4a',
    searchTokFg:   '#a8b1c5',
    searchMarkBg:  '#6b5210',
    error:         '#ff7b72',
    savedFg:       '#56d364',
    backdrop:      'rgba(0,0,0,0.6)',
    notifyFg:      '#79b8ff',
    topBarBg:      '#161b22',
    topBarBorder:  '#30363d',
    presenceIdle:   '#58a6ff',
    presenceOnline: '#3fb950',
  };

  /* token name → CSS-var name. Built once from the LIGHT key list
     (DARK uses the same keys), avoids any drift between the var
     declarations and the token strings exported below. */
  function toVarName(camel){
    return '--cc-' + camel.replace(/[A-Z]/g, function(c){ return '-' + c.toLowerCase(); });
  }

  function paletteBlock(selector, palette){
    var lines = [selector + ' {'];
    Object.keys(palette).forEach(function(k){
      lines.push('  ' + toVarName(k) + ': ' + palette[k] + ';');
    });
    lines.push('}');
    return lines.join('\n');
  }

  // lint:called-once init-once-guard
  function install(){
    if(document.getElementById(STYLE_ID)) return;
    var saved = (function(){
      try { return localStorage.getItem(STORAGE); } catch(e){ return null; }  // lint:silent-catch localStorage-may-throw-in-private-mode
    })() || 'dark';
    document.documentElement.setAttribute('data-theme', saved);
    var s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent =
      paletteBlock(':root', LIGHT) + '\n' +
      paletteBlock('html[data-theme="dark"]', DARK) + '\n' +
      /* baseline: body bg + fg pulled from vars so the page surface
         flips automatically. Everything else attaches to vars by
         being referenced in inline styles or sibling <style> blocks. */
      'body { background: var(--cc-bg); color: var(--cc-fg); }\n';
    document.head.appendChild(s);
  }

  function toggle(){
    var cur = document.documentElement.getAttribute('data-theme') || 'light';
    var next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem(STORAGE, next); } catch(e){ /* private mode etc */ }  // lint:silent-catch localStorage-may-throw-in-private-mode
    return next;
  }

  function currentTheme(){
    return document.documentElement.getAttribute('data-theme') || 'light';
  }

  /* Build the public token map from the LIGHT key list — each token's
     value is the var() reference, identical regardless of theme. */
  var tokens = {};
  Object.keys(LIGHT).forEach(function(k){
    tokens[k] = 'var(' + toVarName(k) + ')';
  });

  return Object.assign({
    install: install,
    toggle: toggle,
    currentTheme: currentTheme,
  }, tokens);
})();
