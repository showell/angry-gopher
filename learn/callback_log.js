/* LearnCallbackLog — a tiny drop-in widget the /learn demos use to
   narrate what a widget reports to its caller.

   Not part of the real chat system — this is demo code. But it's
   built exactly the way the real widgets are: one factory, owned
   DOM, owned styling (inline), a small public API. The lessons that
   follow drop it into their layouts the same way the chat page
   drops in Message, ChatRightSidebar, ChatAddTopic, etc.

   API:
     var clog = LearnCallbackLog.create({caption, height, width});
       caption: heading text shown above the log body
                (default 'Callback log:')
       height:  fixed CSS height for the scrolling body
                (default '220px' — fixed, NOT flex:1, so the body
                scrolls INTERNALLY when entries overflow instead of
                growing the page)
       width:   fixed CSS width for the column (default '260px')
     clog.element   the DOM column ready to append; caption on top,
                    scrollable body below
     clog.log(line) append one entry; auto-scrolls so the latest
                    entry stays visible
     clog.clear()   wipe all entries (rarely used; here for tests
                    and reset-button demos)

   Entries are prefixed with '→ ' so the log reads as a sequence of
   events: → onQuote(MSG_123), → POST received, → ackIfPending(…). */
window.LearnCallbackLog = (function(){
  'use strict';

  function create(opts){
    opts = opts || {};
    var captionText = opts.caption || 'Callback log:';
    var height      = opts.height  || '220px';
    var width       = opts.width   || '260px';

    var column = document.createElement('div');
    Object.assign(column.style, {
      width: width, flexShrink: '0',
      display: 'flex', flexDirection: 'column',
    });

    var caption = document.createElement('div');
    Object.assign(caption.style, {
      marginBottom: '4px', fontSize: '13px', color: '#777',
    });
    caption.textContent = captionText;

    /* PRODUCT_DECISION: fixed `height` (not flex:1) is the whole point.
       A flex:1 minHeight:0 log relies on the parent to constrain its
       size, and when the parent stretches with the page (as it does
       in a short-form demo like Lesson 8), the log grows the page
       instead of scrolling internally. Auto-scroll-to-bottom then
       moves the PAGE, not the log. Fixed height + overflowY:auto
       guarantees the log is a self-contained scroll region. */
    var body = document.createElement('div');
    Object.assign(body.style, {
      fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: '12px',
      background: '#fff', border: '1px solid #ccc', borderRadius: '4px',
      padding: '8px', height: height, overflowY: 'auto', boxSizing: 'border-box',
    });

    column.appendChild(caption);
    column.appendChild(body);

    function log(line){
      var entry = document.createElement('div');
      entry.textContent = '→ ' + line;
      body.appendChild(entry);
      body.scrollTop = body.scrollHeight;
    }
    function clear(){ body.textContent = ''; }

    return { element: column, log: log, clear: clear };
  }

  return { create: create };
})();
