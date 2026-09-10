/* ChatReactions — emoji reactions on messages, the client half.

   PRODUCT_DECISION: the server never folds. It ships the topic's reaction
   sidecar (`<sid>/reactions`, one JSON event per line, append-only) and one
   live `event: reaction` per new line on the topic stream; THIS module folds
   the events (last event wins per message × uid × emoji) and hands each
   bubble its chips. A toggle POSTs the desired state to `<sid>/react` and
   waits for the echo — never optimistic, like sends.

   The fold keys on the message NUMBER (the N of MSG_<sid>_N, 1-based); the
   widget for a number comes from the page via deps.widgetByMsg, so a line
   that lands before its bubble is rendered just waits in `state` until the
   page calls paint(n) after appending. */
window.ChatReactions = (function(){
  'use strict';

  var state = new Map(); /* msg number → Map(emoji → Map(uid → name)); insertion order = first-seen, so chips are stable */
  var sessionBase, me, widgetByMsg;

  // lint:called-once fold-to-chips projection
  function chips(msg){
    var per = state.get(msg), out = [];
    if(!per) return out;
    per.forEach(function(who, emoji){
      var names = [];
      who.forEach(function(name){ names.push(name); });
      out.push({ emoji: emoji, count: who.size, names: names, mine: who.has(me) });
    });
    return out;
  }

  function paint(msg){
    var w = widgetByMsg(msg);
    if(w) w.setReactions(chips(msg));
  }

  /* apply folds one sidecar line (from the file or the live event). */
  function apply(line){
    var ev;
    try { ev = JSON.parse(line); }
    catch(err){ console.error('reactions: malformed line', line, err); return; }
    var per = state.get(ev.msg);
    if(!per){ per = new Map(); state.set(ev.msg, per); }
    var who = per.get(ev.emoji);
    if(!who){ who = new Map(); per.set(ev.emoji, who); }
    if(ev.on) who.set(ev.uid, ev.from); else who.delete(ev.uid);
    if(who.size === 0) per.delete(ev.emoji);
    paint(ev.msg);
  }

  // lint:called-once viewer-predicate
  function isMine(msg, emoji){
    var per = state.get(msg), who = per && per.get(emoji);
    return !!(who && who.has(me));
  }

  /* toggle: add my reaction if I haven't, retract it if I have. */
  function toggle(msg, emoji){
    var params = new URLSearchParams();
    params.set('msg', msg); params.set('emoji', emoji); params.set('on', isMine(msg, emoji) ? '0' : '1');
    fetch(sessionBase + '/react', { method: 'POST',
      headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: params.toString() })
      .then(function(r){ if(!r.ok) ChatNotify.show('Reaction failed'); /* the SSE echo repaints */ })
      .catch(function(){ ChatNotify.show('Reaction failed'); });
  }

  // lint:called-once load-once-on-init
  function load(){
    fetch(sessionBase + '/reactions').then(function(r){ return r.ok ? r.text() : ''; })
      .then(function(text){ text.split('\n').forEach(function(line){ if(line.trim()) apply(line); }); })
      .catch(function(err){ console.error('reactions: load failed', err); });
  }

  function init(deps){
    sessionBase = deps.sessionBase; me = deps.me; widgetByMsg = deps.widgetByMsg;
    load();
  }

  return { init: init, apply: apply, paint: paint, toggle: toggle };
})();
