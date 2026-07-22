// engine_glue.js — bridges the Elm clients to the TS engine
// bundle (engine.js → global `LynRummyEngine`) and, for puzzle
// hints, to the zig board-bridge solver (solver.wasm).
//
// Wire shape (snake_case at the boundary):
//
//   game_hint (full-game Hint button):
//     request:  { request_id, op: "game_hint", hand, board, loner? }
//       loner (optional bool): the last non-cosmetic move laid a hand
//       card onto an empty spot — finish the board first, don't project.
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
//             already on the board, so there's no hand. This op is
//             answered by the ZIG BOARD-BRIDGE solver (solver.wasm,
//             fetched lazily on the first click): the board lowers to
//             an arrangement line ("3H>4S>5H KH=KC=KS QD"), the wasm
//             finds a cover that keeps the most of the player's own
//             stacks, and the reply is the distilled move plan —
//             peel / steal / push / split / merge lines. The status
//             bar shows the first line; the full plan logs to the
//             console. No TS fallback: if the wasm can't load or the
//             board can't be lowered, the hint fails loud.
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
            lines: logHint(op, gameHint(req.hand, req.board, req.loner === true)),
          });
        } else if (op === 'puzzle_hint') {
          // Async: the solver wasm loads on the first click. Elm
          // matches replies by request_id, so latency is safe.
          puzzleHint(req.board).then(function (lines) {
            port.send({
              request_id: requestId,
              op: op,
              ok: true,
              lines: logHint(op, lines),
            });
          }, function (err) {
            var msg = String(err && err.message ? err.message : err);
            port.send({ request_id: requestId, op: op, ok: false, error: msg });
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

  // The status bar shows only the hint's FIRST line; the full plan goes
  // to the developer console here, for both apps, so it stays inspectable.
  function logHint(op, lines) {
    console.log('[' + op + ']\n'
      + (lines.length ? lines.join('\n') : '(no hint)'));
    return lines;
  }

  function gameHint(hand, board, loner) {
    var handCards = hand.map(cardObjectToRecord);
    var stacks = board.map(function (stack) {
      return stack.map(cardObjectToRecord);
    });
    return LynRummyEngine.elmGameHint(handCards, stacks, loner === true);
  }

  // --- puzzle_hint: the zig board-bridge solver ---------------------

  var solverWasmPromise = null; // lazy singleton; a failed load retries

  function loadSolverWasm() {
    if (solverWasmPromise === null) {
      solverWasmPromise = fetch('/puzzles/solver.wasm')
        .then(function (resp) {
          if (!resp.ok) throw new Error('solver.wasm fetch failed: ' + resp.status);
          return resp.arrayBuffer();
        })
        .then(function (bytes) { return WebAssembly.instantiate(bytes); })
        .then(function (result) { return result.instance.exports; })
        .catch(function (err) {
          solverWasmPromise = null; // next click retries the load
          throw err;
        });
    }
    return solverWasmPromise;
  }

  function puzzleHint(board) {
    var line = boardToArrangementLine(board);
    return loadSolverWasm().then(function (wasm) {
      var bytes = new TextEncoder().encode(line);
      if (bytes.length > wasm.ioCap()) throw new Error('board too large for the solver');
      new Uint8Array(wasm.memory.buffer, wasm.ioPtr(), bytes.length).set(bytes);
      var rc = wasm.puzzleHint(bytes.length);
      if (rc === 0) return ['Board is already clean — nothing to move.'];
      if (rc > 0) {
        var text = new TextDecoder().decode(
          new Uint8Array(wasm.memory.buffer, wasm.ioPtr(), rc));
        return text.split('\n');
      }
      if (rc === -2) throw new Error('no clean layout exists for these cards');
      if (rc === -3) throw new Error('the solver gave up on this board');
      throw new Error('the solver rejected the board (code ' + rc + ')');
    });
  }

  // Lower the Elm board to the solver's arrangement notation: each
  // stack one glued token, run links '>' and set links '=' (same
  // value = set), stacks space-separated. "3H>4S>5H KH=KC=KS QD".
  var RANK_CHARS = 'A23456789TJQK'; // index = value - 1
  var SUIT_CHARS = 'CDSH'; // wire suit ints 0-3

  function boardToArrangementLine(board) {
    return board.map(function (stack) {
      var out = '';
      for (var i = 0; i < stack.length; i++) {
        var c = stack[i];
        if (i > 0) out += stack[i - 1].value === c.value ? '=' : '>';
        out += RANK_CHARS[c.value - 1] + SUIT_CHARS[c.suit]
          + (c.origin_deck === 1 ? "'" : '');
      }
      return out;
    }).join(' ');
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
