/* Time popup — opened by clicking a message's timestamp. Shows the one
   instant rendered across a fixed set of zones (plus the viewer's own
   detected zone, highlighted at the top), so an NYC reader and an India
   reader can agree on when a message was sent.

   Exposed as `window.ChatTimePopup.show(isoString)` where isoString is
   the message's RFC3339 UTC instant (the `at` wire field). Self-
   contained: owns ALL its styling (Object.assign on .style plus one
   lazy ::backdrop <style> tag). No CSS from the server — drop the
   script into any page and it works.

   No instance state; each call builds a fresh <dialog>, stacks natively
   over other modals, and self-removes on close. */
window.ChatTimePopup = (function(){
  'use strict';

  /* PRODUCT_DECISION: NYC + India are the two real user zones; London /
     SF / Sydney round out the world clock. The viewer's detected zone is
     added at the top at render time (deduped if it's already listed). */
  var ZONES = [
    { label: 'New York',      tz: 'America/New_York' },
    { label: 'India',         tz: 'Asia/Kolkata' },
    { label: 'London',        tz: 'Europe/London' },
    { label: 'San Francisco', tz: 'America/Los_Angeles' },
    { label: 'Sydney',        tz: 'Australia/Sydney' }
  ];

  /* PRODUCT_DECISION: ::backdrop is the one rule that can't go on
     element.style (it's a pseudo-element). Injected once per page load,
     class-scoped so the rule only matches this popup's dialogs. */
  var backdropStyleInjected = false;
  // lint:called-once init-once-guard
  function ensureBackdropStyle(){
    if(backdropStyleInjected) return;
    var s = document.createElement('style');
    s.textContent = 'dialog.chat-time-dialog::backdrop { background:var(--cc-backdrop); }';
    document.head.appendChild(s);
    backdropStyleInjected = true;
  }

  function fmt(date, tz){
    return new Intl.DateTimeFormat(undefined, {
      timeZone: tz, weekday: 'short', month: 'short', day: 'numeric',
      hour: 'numeric', minute: '2-digit', timeZoneName: 'short'
    }).format(date);
  }

  function buildRow(label, value, highlight){
    var row = document.createElement('div');
    Object.assign(row.style, {
      display: 'flex', justifyContent: 'space-between', gap: '24px',
      padding: '8px 16px', borderBottom: '1px solid '+ChatColors.softBorder
    });
    if(highlight) row.style.background = ChatColors.accentSoftBg;
    var name = document.createElement('span');
    name.textContent = label;
    Object.assign(name.style, { color: ChatColors.mutedFg, whiteSpace: 'nowrap' });
    var when = document.createElement('span');
    when.textContent = value;
    Object.assign(when.style, { color: ChatColors.metaFg, fontWeight: '600', whiteSpace: 'nowrap' });
    row.appendChild(name); row.appendChild(when);
    return row;
  }

  function show(iso){
    var date = new Date(iso);
    if(isNaN(date.getTime())) return;
    ensureBackdropStyle();

    var dlg = document.createElement('dialog');
    /* PRODUCT_DECISION: the class is kept ONLY so the ::backdrop rule has
       something to attach to; nothing else selects on it. */
    dlg.className = 'chat-time-dialog';
    Object.assign(dlg.style, {
      maxWidth: '90vw', padding: '0',
      border: '1px solid '+ChatColors.dialogBorder, borderRadius: '8px',
      background: ChatColors.bg, color: ChatColors.fg,
    });

    var strap = document.createElement('div');
    Object.assign(strap.style, {
      display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      gap: '16px', padding: '8px 12px 8px 16px',
      borderBottom: '1px solid '+ChatColors.softBorder, background: ChatColors.codeStrapBg,
    });
    var title = document.createElement('span');
    title.textContent = 'Sent at';
    Object.assign(title.style, { fontSize: '13px', color: ChatColors.mutedFg });
    var close = document.createElement('button');
    close.type = 'button'; close.textContent = 'Close';
    close.addEventListener('click', function(){ dlg.close(); });
    strap.appendChild(title); strap.appendChild(close);
    dlg.appendChild(strap);

    /* Viewer's own detected zone, pinned to the top and highlighted. */
    var localTz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    dlg.appendChild(buildRow('Your time', fmt(date, localTz), true));

    for(var i = 0; i < ZONES.length; i++){
      /* Skip a fixed zone that's identical to the viewer's — no point
         showing "India" twice for an India reader. */
      if(ZONES[i].tz === localTz) continue;
      dlg.appendChild(buildRow(ZONES[i].label, fmt(date, ZONES[i].tz), false));
    }

    dlg.addEventListener('close', function(){ dlg.remove(); });
    dlg.addEventListener('click', function(e){ if(e.target === dlg) dlg.close(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  return { show: show };
})();
