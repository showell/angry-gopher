// engine_glue.js — bridges the Elm puzzles client to the TS
// engine bundle (engine.js → global `LynRummyEngine`).
//
// Wire shape (snake_case at the boundary, per decision 4 of
// TS_ELM_INTEGRATION):
//
//   request:  { request_id, op, puzzle_name, board }
//             where board = [[{value, suit, origin_deck}, ...], ...]
//   response: { request_id, puzzle_name, ok, plan|error }
//             where plan = [{line, desc}, ...] | null
//
// The puzzle_name is opaque to the engine — we echo it on every
// response so the Elm Puzzles host can route the result to the
// right Play instance without keeping any port-side state.

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
      var puzzleName = req.puzzle_name;
      var op = req.op;
      try {
        var result;
        switch (op) {
          case 'solve_board':
            result = solveBoard(req.board);
            break;
          default:
            throw new Error('unknown op: ' + op);
        }
        app.ports.engineResponse.send({
          request_id: requestId,
          puzzle_name: puzzleName,
          ok: true,
          plan: result,
        });
      } catch (err) {
        app.ports.engineResponse.send({
          request_id: requestId,
          puzzle_name: puzzleName,
          ok: false,
          error: String(err && err.message ? err.message : err),
        });
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
    // but desc is cheap and useful if Phase 2 wants the structured
    // form (e.g. for rendering richer hints).
    return plan.map(function (p) {
      return { line: p.line, desc: p.desc };
    });
  }

  function cardObjectToTuple(c) {
    return [c.value, c.suit, c.origin_deck];
  }

  window.EngineGlue = { attach: attach };
})();
