// engine_glue.js — bridges the Elm clients to the TS engine
// bundle (engine.js → global `LynRummyEngine`) and, for puzzle
// hints, to the zig board-bridge solver (solver.wasm).
//
// Wire shape (snake_case at the boundary):
//
//   game_hint (full-game Hint button):
//     request:  { request_id, op: "game_hint", hand, board, loner? }
//               where hand = [{value, suit, origin_deck}, ...]
//               and board = [[{value, suit, origin_deck}, ...], ...]
//     response: { request_id, op: "game_hint", ok, lines: string[] }
//             — sent on `gameHintResponse`. Answered by the ZIG
//             solver (same solver.wasm as puzzle_hint), with the
//             BEGINNER-FIRST objective: prefer placing ONE hand card
//             (then pairs, then triples) and lead the plan with the
//             `place` line; with nothing playable, a dirty board gets
//             its consolidation plan, a clean one says draw. The
//             legacy `loner` flag is ignored — the placed loner is
//             just a board singleton in the arrangement, and the
//             consolidation path handles it.
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
          gameHint(req.hand, req.board).then(function (lines) {
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

  // The standing objective: the hand card the last game hint was
  // building toward. Sent back to the solver so hints keep walking
  // one line instead of flapping between near-equal plays (the
  // session-8 ace loop); cleared whenever the hint isn't a play, and
  // — because deck copies are indistinguishable — cleared by COUNT
  // when a copy of it leaves the hand: playing one 3♣ retires the
  // objective even while its twin is still held (game 10's lesson:
  // the board gets cleaned before the twin becomes a new project).
  var gameObjective = '';
  var gameObjectiveCount = 0;
  // The last hint's hand, as bare (copy-blind) token counts. Diffing
  // against it detects ANY card leaving the hand — the player's own
  // placements included, not just the hint's objective (game 11's
  // lesson) — and it is undo-safe by construction: an undone
  // placement restores the count and the signal simply never arms.
  var lastHintHand = null;

  function bareCounts(hand) {
    var m = {};
    hand.forEach(function (c) {
      var t = cardToken(c).replace("'", '');
      m[t] = (m[t] || 0) + 1;
    });
    return m;
  }

  function objectiveCopies(hand) {
    var bare = gameObjective.replace("'", '');
    return hand.filter(function (c) {
      return cardToken(c).replace("'", '') === bare;
    }).length;
  }

  function gameHint(hand, board) {
    var played = false;
    if (lastHintHand !== null) {
      var now = bareCounts(hand);
      for (var t in lastHintHand) {
        if ((now[t] || 0) < lastHintHand[t]) played = true;
      }
    }
    lastHintHand = bareCounts(hand);
    if (gameObjective && objectiveCopies(hand) < gameObjectiveCount) {
      // The objective itself landed: it must not latch onto a held
      // twin (copies are indistinguishable) — retire it.
      gameObjective = '';
      gameObjectiveCount = 0;
    }
    var prefLine = gameObjective + (played ? (gameObjective ? ' ' : '') + '!played' : '');
    var input = boardToArrangementLine(board) + '\n'
      + hand.map(cardToken).join(' ') + '\n' + prefLine;
    return loadSolverWasm().then(function (wasm) {
      var bytes = new TextEncoder().encode(input);
      if (bytes.length > wasm.ioCap()) throw new Error('board too large for the solver');
      new Uint8Array(wasm.memory.buffer, wasm.ioPtr(), bytes.length).set(bytes);
      var rc = wasm.gameHint(bytes.length);
      if (rc === 0) {
        gameObjective = '';
        gameObjectiveCount = 0;
        return ['No play — draw a card.'];
      }
      if (rc > 0) {
        var text = new TextDecoder().decode(
          new Uint8Array(wasm.memory.buffer, wasm.ioPtr(), rc));
        // Futility certificates (sentinel-prefixed): why nothing
        // plays / why the board needs an Undo, in table English.
        if (text.indexOf('!noplay') === 0) {
          gameObjective = '';
          gameObjectiveCount = 0;
          var why = text.slice('!noplay: '.length);
          return [why
            ? glyphCards('No play — draw a card. (' + why + ')')
            : 'No play — draw a card.'];
        }
        if (text.indexOf('!futile') === 0) {
          gameObjective = '';
          gameObjectiveCount = 0;
          var bwhy = text.slice('!futile: '.length);
          throw new Error(glyphCards('this board cannot be made clean — try Undo'
            + (bwhy ? ' (' + bwhy + ')' : '')));
        }
        var lines = text.split('\n');
        var place = firstPlaceToken(lines);
        gameObjective = place || '';
        gameObjectiveCount = place ? objectiveCopies(hand) : 0;
        lines = lines.map(glyphCards);
        // The status bar shows only line 1: when that line isn't the
        // place itself, say which hand card the work is FOR — the
        // old engine's best habit.
        if (place && lines[0].indexOf('place ') !== 0) {
          lines[0] += ' — toward placing ' + glyphCards(place);
        }
        return lines;
      }
      gameObjective = '';
      gameObjectiveCount = 0;
      if (rc === -3) throw new Error('the solver gave up on this board');
      throw new Error('the solver rejected the board (code ' + rc + ')');
    });
  }

  function firstPlaceToken(lines) {
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^place ([A2-9TJQK][HDCS]'?)/);
      if (m) return m[1];
    }
    return null;
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
        return text.split('\n').map(glyphCards);
      }
      if (rc === -2) throw new Error('no clean layout exists for these cards');
      if (rc === -3) throw new Error('the solver gave up on this board');
      throw new Error('the solver rejected the board (code ' + rc + ')');
    });
  }

  // The solver speaks ASCII ("TC'"); the status bar colors cards
  // red/black only when they wear suit GLYPHS (Lib.Status.cardSegments
  // keys on ♥♦♣♠, and renders T as "10"). Presentation is the client's
  // job, so the swap happens here, not in the solver. Safe on plan
  // lines: the verbs are lowercase and no other uppercase pair in the
  // vocabulary matches rank-then-suit.
  var SUIT_GLYPHS = { H: '♥', D: '♦', C: '♣', S: '♠' };

  function glyphCards(line) {
    return line.replace(/([A2-9TJQK])([HDCS])/g, function (_, rank, suit) {
      return rank + SUIT_GLYPHS[suit];
    });
  }

  // Lower the Elm board to the solver's arrangement notation: each
  // stack one glued token, run links '>' and set links '=' (same
  // value = set), stacks space-separated. "3H>4S>5H KH=KC=KS QD".
  var RANK_CHARS = 'A23456789TJQK'; // index = value - 1
  var SUIT_CHARS = 'CDSH'; // wire suit ints 0-3

  function cardToken(c) {
    return RANK_CHARS[c.value - 1] + SUIT_CHARS[c.suit]
      + (c.origin_deck === 1 ? "'" : '');
  }

  function boardToArrangementLine(board) {
    return board.map(function (stack) {
      var out = '';
      for (var i = 0; i < stack.length; i++) {
        if (i > 0) out += stack[i - 1].value === stack[i].value ? '=' : '>';
        out += cardToken(stack[i]);
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
