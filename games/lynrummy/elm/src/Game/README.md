# Lyn Rummy: the game

Open [lynrummy.com/game](https://lynrummy.com/game), press **Deal**, and play
two-deck rummy against an agent that knows the rules. Build runs and sets on
a **shared board**, press **Hint** when stuck, let **Agent** take the
opponent's turn and press **Complete turn** when the board looks right.
**Replay** retells the game move by move, and **Resume** brings you back to
it later.

`Game/` holds the Elm modules of the full game, whose entry point is
`../Game.elm`. The puzzle ([`../Puzzle/`](../Puzzle/)) is its smaller
cousin.

## Three actors

Three actors split the game, each doing what it is best at:

- **Elm is the client and most of the app.** `Game.elm` and its `Game.*`
  modules render the board, run their own referee, animate drags and replay
  the action log, all in the browser.
- **The Zig solver, through the TS layer, is the agent's brain.** The solver
  (`games/lynrummy/zig/`, compiled to `solver.wasm`) picks the hints and the
  opponent's plays; the TS layer ([`../../../ts/`](../../../ts/)) turns them
  into gestures. Elm asks over ports (`engineRequest`) and animates the
  answer.
- **The zig server is plain storage**: a URL-keyed file store for session
  state (`meta`, `actions.dsl`). [`Wire.elm`](Wire.elm) is the HTTP surface
  that talks to it.

[`../../../ARCHITECTURE.md`](../../../ARCHITECTURE.md) has the full
rationale: the single shared board, "each actor owns its own view", the Elm
retrospective.

## One DSL everywhere

A single **text DSL**, with cards as Unicode glyphs and coordinates as
`(left, top)`, carries every long-lived artifact:

- **the wire format**, what Elm posts and what the agent emits;
- **the saved game**, the on-disk `actions.dsl` and resume state;
- **the conformance corpus**: tests parse real `.dsl` scenarios at run time,
  so the fixtures are a contract with the live system;
- **conversation**: a game, a hint or a stuck board is text you can paste
  into a chat and reason about, which made debugging fast.

The examples are the spec: read
[`../../../conformance/scenarios/`](../../../conformance/scenarios/),
starting with `undo_walkthrough.dsl`.

## The modules

`Model.elm` holds the model and `applyEvent`; `Msg.elm`, `View.elm`,
`Wire.elm` and `Util.elm` do what their names say. Most of the machinery
(referee, dealer, drag, animation, the DSL parsers) is in
[`../Lib/`](../Lib/), shared with the puzzle. Read the code.

## Building and running

`ops/start` from the repo root rebuilds everything and serves `/game` on
`:9001`. `ops/build_elm` and `ops/build_engine_js` build the front end,
which the binary embeds. Gate with **`ops/check_lynrummy`** while working
here; `ops/check` is the pre-commit gate.
