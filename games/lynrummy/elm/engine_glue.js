// engine_glue.js — bridges the Elm clients to the TS engine
// bundle (engine.js → global `LynRummyEngine`).
//
// Wire shape (snake_case at the boundary):
//
//   solve_board (Puzzles hint button):
//     request:  { request_id, op: "solve_board", puzzle_name, board }
//               where board = [[{value, suit, origin_deck}, ...], ...]
//     response: { request_id, puzzle_name, op: "solve_board",
//                 ok, plan: [{line, desc}, ...] | null }
//             — sent on `engineResponse`
//
//   agent_play (Puzzles Let-Agent-Play button):
//     request:  { request_id, op: "agent_play", puzzle_name, board }
//               where each board stack carries cards AND loc:
//               [{ cards: [{value, suit, origin_deck}, ...],
//                  loc: { top, left } }, ...]
//     response: { request_id, puzzle_name, op: "agent_play",
//                 ok, plan: [{line, wire_actions: [...]}, ...] | null }
//             — sent on `engineResponse`
//
//   game_hint (full-game Hint button):
//     request:  { request_id, op: "game_hint", hand, board }
//               where hand = [{value, suit, origin_deck}, ...]
//               and board = [[{value, suit, origin_deck}, ...], ...]
//     response: { request_id, op: "game_hint", ok, lines: string[] }
//             — sent on `gameHintResponse` (its own port; no
//             puzzle_name routing needed because there's only
//             one Play instance in the full-game host)
//
// puzzle_name is opaque to the engine — we echo it on solve_board
// and agent_play responses so the Puzzles host can route the
// result to the right Play instance.
//
// Each Elm host declares only the ports its surface needs:
//   - Puzzles.elm: engineRequest + engineResponse
//   - Main.elm:    engineRequest + gameHintResponse
// The glue picks the response port by op (see `responsePort`).

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
        switch (op) {
          case 'solve_board':
            app.ports.engineResponse.send({
              request_id: requestId,
              puzzle_name: req.puzzle_name,
              op: op,
              ok: true,
              plan: solveBoard(req.board),
            });
            break;
          case 'agent_play':
            app.ports.engineResponse.send({
              request_id: requestId,
              puzzle_name: req.puzzle_name,
              op: op,
              ok: true,
              plan: agentPlay(req.board),
            });
            break;
          case 'game_hint':
            app.ports.gameHintResponse.send({
              request_id: requestId,
              op: op,
              ok: true,
              lines: gameHint(req.hand, req.board),
            });
            break;
          default:
            throw new Error('unknown op: ' + op);
        }
      } catch (err) {
        // Pick the response port by op so the right Elm subscription
        // gets the error. Falls back to engineResponse when op is
        // unrecognized — the only host that ever sees it has that
        // port (Puzzles).
        var msg = String(err && err.message ? err.message : err);
        var port = (op === 'game_hint')
          ? app.ports.gameHintResponse
          : app.ports.engineResponse;
        if (op === 'game_hint') {
          port.send({ request_id: requestId, op: op, ok: false, error: msg });
        } else {
          port.send({
            request_id: requestId,
            puzzle_name: req.puzzle_name,
            op: op, ok: false, error: msg,
          });
        }
      }
    });
  }

  // The functions below call LynRummyEngine.elm* — the Elm-facing
  // wrappers in ts/src/engine_entry.ts. They're one-liners on the TS
  // side; this layer's job is just wire-shape conversion (Elm sends
  // {value, suit, origin_deck} objects; the TS Card record is
  // {rank, suit, deck}).

  function solveBoard(board) {
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToRecord);
    });
    return LynRummyEngine.elmSolveBoard(stacks);
    // Returns [{line: string}, ...] | null.
  }

  function gameHint(hand, board) {
    var handCards = hand.map(cardObjectToRecord);
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToRecord);
    });
    return LynRummyEngine.elmGameHint(handCards, stacks);
  }

  function agentPlay(board) {
    // board: [{ cards: [{value, suit, origin_deck}, ...], loc: {top, left} }, ...]
    var stacks = board.map(function (stack) {
      return {
        cards: stack.cards.map(cardObjectToRecord),
        loc: stack.loc,
      };
    });
    return LynRummyEngine.elmAgentPlay(stacks);
    // Returns [{line, wire_actions: [...]}, ...] | null. wire_actions
    // are already in Elm's Lib.WireAction JSON shape — pass through.
  }

  function cardObjectToRecord(c) {
    // Elm wire shape: { value, suit, origin_deck }.
    // TS Card shape:  { rank,  suit, deck         }.
    // Names diverge for historical reasons; the glue translates.
    return { rank: c.value, suit: c.suit, deck: c.origin_deck };
  }

  window.EngineGlue = { attach: attach };
})();
