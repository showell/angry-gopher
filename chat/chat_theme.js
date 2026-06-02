/* ChatTheme — wires the 🌙/☀️ toggle button in the chat-subsystem top bar.

   PRODUCT_DECISION: chrome.go emits a placeholder <button id="chat-theme-toggle">
   with no icon; this module sets the right glyph on load and on click.
   Synchronous, no flash — ChatColors.install() runs first and sets
   data-theme; we just read it and pick the icon. */
(function(){
  'use strict';
  var btn = document.getElementById('chat-theme-toggle');
  if(!btn) return;

  function glyphFor(theme){  // lint:called-once named to pair with labelFor
    /* showing the destination: 🌙 = "click to go dark", ☀️ = "click to go light". */
    return theme === 'dark' ? '☀️' : '🌙';
  }
  function labelFor(theme){
    return theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
  }

  function paint(){
    var t = ChatColors.currentTheme();
    btn.textContent = glyphFor(t);
    btn.title = labelFor(t);
    btn.setAttribute('aria-label', labelFor(t));
  }

  btn.addEventListener('click', function(){
    ChatColors.toggle();
    paint();
  });
  paint();
})();
