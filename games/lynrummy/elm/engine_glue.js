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
//
//   agent_step (real-time agent play):
//     request:  { request_id, op: "agent_step",
//                 board_dsl: string, hand_dsl: string }
//             where board_dsl is the canonical multi-line
//             "at (left,top): cards" form and hand_dsl is a
//             single space-separated card-token line.
//     response: { request_id, op: "agent_step", ok,
//                 primitives_dsl: string }
//             — sent on `agentStepResponse`. Empty
//             primitives_dsl means the agent is stuck (end of
//             turn). Non-empty = one play's primitive sequence,
//             newline-separated.

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
        if (op === 'game_hint') {
          app.ports.gameHintResponse.send({
            request_id: requestId,
            op: op,
            ok: true,
            lines: gameHint(req.hand, req.board),
          });
        } else if (op === 'agent_step') {
          app.ports.agentStepResponse.send({
            request_id: requestId,
            op: op,
            ok: true,
            primitives_dsl: agentStep(req.board_dsl, req.hand_dsl),
          });
        } else {
          throw new Error('unknown op: ' + op);
        }
      } catch (err) {
        var msg = String(err && err.message ? err.message : err);
        var port = (op === 'agent_step')
          ? app.ports.agentStepResponse
          : app.ports.gameHintResponse;
        port.send({ request_id: requestId, op: op, ok: false, error: msg });
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

  function agentStep(boardDsl, handDsl) {
    return LynRummyEngine.elmAgentStep(boardDsl, handDsl);
  }

  function cardObjectToRecord(c) {
    // Elm wire shape: { value, suit, origin_deck }.
    // TS Card shape:  { rank,  suit, deck         }.
    return { rank: c.value, suit: c.suit, deck: c.origin_deck };
  }

  window.EngineGlue = { attach: attach };
})();
