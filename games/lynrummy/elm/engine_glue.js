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

  function solveBoard(board) {
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToTuple);
    });
    var plan = LynRummyEngine.solveBoard(stacks);
    if (plan === null) return null;
    // Echo the line + desc; Elm's decoder reads only `line` today,
    // but desc is cheap and useful if a future phase wants the
    // structured form (e.g. for rendering richer hints).
    return plan.map(function (p) {
      return { line: p.line, desc: p.desc };
    });
  }

  function gameHint(hand, board) {
    // hand: [{value, suit, origin_deck}, ...] — full game's active hand
    // board: [[{value, suit, origin_deck}, ...], ...]
    var handTuples = hand.map(cardObjectToTuple);
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToTuple);
    });
    return LynRummyEngine.gameHintLines(handTuples, stacks);
  }

  function agentPlay(board) {
    // board: [{ cards: [{value, suit, origin_deck}, ...], loc: {top, left} }, ...]
    // The TS bundle's agentPlay expects BoardStack[] = [{cards: Card[], loc}].
    // Translate cards from object-form to tuple-form here.
    var stacks = board.map(function (stack) {
      return {
        cards: stack.cards.map(cardObjectToTuple),
        loc: stack.loc,
      };
    });
    return LynRummyEngine.agentPlay(stacks);
    // Returns [{line, wire_actions: [...]}, ...] | null. wire_actions
    // are already in Elm's Game.WireAction JSON shape — pass through.
  }

  function cardObjectToTuple(c) {
    return [c.value, c.suit, c.origin_deck];
  }

  window.EngineGlue = { attach: attach };
})();
