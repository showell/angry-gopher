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
//   puzzle_hint (puzzle Hint button):
//     request:  { request_id, op: "puzzle_hint", board }
//               where board = [[{value, suit, origin_deck}, ...], ...]
//     response: { request_id, op: "puzzle_hint", ok, lines: string[] }
//             — sent on `puzzleHintResponse`. Every puzzle card is
//             already on the board, so there's no hand: the engine
//             solves the board directly and returns the plan lines.
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
//
// The glue is shared: it attaches to both the full-game app
// (game_hint / agent_step) and the puzzle app (puzzle_hint). Each
// app only ever sends its own ops, and each op's response goes to the
// port that app declares — see `responsePortFor`.

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
      var port = responsePortFor(app, op);
      try {
        if (op === 'game_hint') {
          port.send({
            request_id: requestId,
            op: op,
            ok: true,
            lines: gameHint(req.hand, req.board),
          });
        } else if (op === 'puzzle_hint') {
          port.send({
            request_id: requestId,
            op: op,
            ok: true,
            lines: puzzleHint(req.board),
          });
        } else if (op === 'agent_step') {
          port.send({
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
        port.send({ request_id: requestId, op: op, ok: false, error: msg });
      }
    });
  }

  // Which inbound port carries this op's reply. Each op is sent by
  // exactly one app, so the named port is guaranteed to exist there;
  // referencing it is safe because we only reach this per-op.
  function responsePortFor(app, op) {
    if (op === 'agent_step') return app.ports.agentStepResponse;
    if (op === 'puzzle_hint') return app.ports.puzzleHintResponse;
    return app.ports.gameHintResponse; // game_hint (+ unknown-op errors)
  }

  function gameHint(hand, board) {
    var handCards = hand.map(cardObjectToRecord);
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToRecord);
    });
    return LynRummyEngine.elmGameHint(handCards, stacks);
  }

  function puzzleHint(board) {
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToRecord);
    });
    return LynRummyEngine.elmPuzzleHint(stacks);
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
