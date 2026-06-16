/* ChatStyles — shared transcript-card primitives used by /chat/code and
   /chat/images. Each page renders a list of "entry cards" with the same
   meta header (sender, when, link to source message); the BODY of each
   card differs (code blocks vs <img> tags) and is owned by the
   page-specific module.

   Public surface (window.ChatStyles):
     createTranscriptList() → <ul>, styled, ready to append entries to.
     createTranscriptEntry({sourceID, from, when, sourceURL}) → <li>
       with data-source-id + the meta header pre-built. sourceURL is
       server-supplied so DM and channel rows render the same shape
       without a conv-kind branch on the client.
     formatTranscriptTime(iso) → UTC "January 2, 2006 15:04" string.

   Self-contained: this module owns ALL transcript-shell styling. Element
   styles are inlined via Object.assign on .style; the one rule that can't
   be inlined (a:hover, a pseudo-class) is injected as a single <style>
   tag the first time a meta-link is built. No external CSS needed. */
window.ChatStyles = (function(){
  'use strict';

  var MONTHS = ['January','February','March','April','May','June',
                'July','August','September','October','November','December'];

  function formatTranscriptTime(iso){
    /* PRODUCT_DECISION: matches the original server-side renderer
       ("January 2, 2006 15:04", UTC) so the format stays stable as
       initial render + SSE upserts share one code path. */
    var d = new Date(iso);
    var hh = d.getUTCHours(), mm = d.getUTCMinutes();
    return MONTHS[d.getUTCMonth()] + ' ' + d.getUTCDate() + ', ' + d.getUTCFullYear() + ' ' +
           (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
  }

  function createTranscriptList(){
    var ul = document.createElement('ul');
    Object.assign(ul.style, {
      listStyle: 'none', padding: '0', margin: '0 auto', maxWidth: '600px',
    });
    return ul;
  }

  function createTranscriptEntry(opts){
    var li = document.createElement('li');
    li.setAttribute('data-source-id', opts.sourceID);
    Object.assign(li.style, {
      margin: '0 0 28px 0', padding: '14px 16px',
      border: '1px solid '+ChatColors.softBorder, borderRadius: '6px',
      background: ChatColors.cardBg,
    });

    var meta = document.createElement('div');
    Object.assign(meta.style, {
      fontSize: '15px', color: ChatColors.metaFg, marginBottom: '10px', lineHeight: '1.5',
    });

    var line1 = document.createElement('div');
    line1.style.margin = '1px 0';
    var from = document.createElement('span');
    from.style.fontWeight = '600';
    from.textContent = 'Sent by ' + opts.from;
    line1.appendChild(from);
    meta.appendChild(line1);

    var line2 = document.createElement('div');
    line2.style.margin = '1px 0';
    line2.textContent = opts.when;
    meta.appendChild(line2);

    var line3 = document.createElement('div');
    line3.style.margin = '1px 0';
    line3.appendChild(document.createTextNode('From '));
    var a = document.createElement('a');
    a.href = opts.sourceURL;
    a.textContent = 'MSG_' + opts.sourceID;
    line3.appendChild(a);
    meta.appendChild(line3);

    li.appendChild(meta);
    return li;
  }

  return {
    createTranscriptList: createTranscriptList,
    createTranscriptEntry: createTranscriptEntry,
    formatTranscriptTime: formatTranscriptTime,
  };
})();
