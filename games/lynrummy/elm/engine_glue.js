// engine_glue.js — bridges the Elm clients to the TS engine
// bundle (engine.js → global `LynRummyEngine`).
//
// Wire shape (snake_case at the boundary):
//
//   game_hint (full-game Hint button):
//     request:  { request_id, op: "game_hint", hand, board }
//               where hand = [{value, suit, origin_deck}, ...]
//               and board = [[{value, suit, origin_deck}, ...], ...]
//     response: { request_id, op: "game_hint", ok, lines: string[] }
//             — sent on `gameHintResponse`

(function () {
  'use strict';

  function attach(app) {
    if (!app || !app.ports) {
      console.error('engine_glue: Elm app missing .ports');
      return;
    }
    if (typeof LynRummyEngine === 'undefined') {
      console.error('engine_glue: LynRummyEngine global not loaded — '
        + 'is engine.js included BEFORE engine_glue.js?');
      return;
    }

    app.ports.engineRequest.subscribe(function (req) {
      var requestId = req.request_id;
      var op = req.op;
      try {
        if (op !== 'game_hint') {
          throw new Error('unknown op: ' + op);
        }
        app.ports.gameHintResponse.send({
          request_id: requestId,
          op: op,
          ok: true,
          lines: gameHint(req.hand, req.board),
        });
      } catch (err) {
        var msg = String(err && err.message ? err.message : err);
        app.ports.gameHintResponse.send({
          request_id: requestId, op: op, ok: false, error: msg,
        });
      }
    });
  }

  function gameHint(hand, board) {
    var handCards = hand.map(cardObjectToRecord);
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToRecord);
    });
    return LynRummyEngine.elmGameHint(handCards, stacks);
  }

  function cardObjectToRecord(c) {
    // Elm wire shape: { value, suit, origin_deck }.
    // TS Card shape:  { rank,  suit, deck         }.
    return { rank: c.value, suit: c.suit, deck: c.origin_deck };
  }

  window.EngineGlue = { attach: attach };
})();
