# Lyn Rummy — the game

**Welcome to Lyn Rummy!** Open [lynrummy.com/game](https://lynrummy.com/game),
hit **Deal**, and play a round of two-deck rummy against an agent that actually
knows the rules. You build runs and sets on a **shared board**, press **Hint**
when you're stuck, let **Agent** take the opponent's turn, and **Complete turn**
when the board looks right. There's a **Replay** that re-tells the whole game
move by move, and a **Resume** so you can wander off and come back. Named for
**Lyn** — Steve's aunt, who taught the family to play.

This directory (`Game/`) is the Elm entry point for that full game. It's the best
place to start reading the code, so this README does the heavy lifting for the
whole subsystem; the puzzle variant next door ([`../Puzzle/`](../Puzzle/)) is a
smaller cousin that points back here.

## The shape: a three-actor hybrid

The interesting thing about Lyn Rummy is that no single language or process owns
the game. Three actors split the work, each doing only what it's best at:

- **Elm is the client, and it's almost the whole app.** `Game.elm` and its
  `Game.*` modules render the board, run their own referee, animate drags, and
  replay the action log — all in the browser. After bootstrap, the UI is largely
  self-contained.
- **TypeScript is the agent's brain.** The hard combinatorial work — the BFS
  solver behind **Hint** and the computer opponent — lives in
  [`../../../ts/`](../../../ts/), bundled into the page and called over Elm ports.
  Elm doesn't reason about *good* plays; it asks TS and animates the answer.
- **The zig server is deliberately dumb.** It's a URL-keyed file store for session
  state (`meta`, `actions.dsl`) and nothing more — it never referees, never
  reasons. ([`Wire.elm`](Wire.elm) is the thin HTTP surface that talks to it.)

The split isn't incidental — it's the design. The full rationale (the
single-shared-board axiom, "each actor owns its own view", the Elm
retrospective) lives one level up in [`../../../ARCHITECTURE.md`](../../../ARCHITECTURE.md);
this is the orientation.

## The DSL, spoken everywhere

The idea worth stealing from this codebase is a single **text DSL** — cards as
Unicode glyphs, coordinates as `(left, top)` — that carries *every* long-lived
artifact:

- **The wire format** — what Elm POSTs and what the agent emits.
- **The saved game** — the on-disk `actions.dsl` and resume state.
- **The conformance corpus** — tests parse real `.dsl` scenarios at run time, so
  the fixtures are a literal contract for the live system, not a parallel model
  that can drift.
- **Steve-and-Claude shorthand** — a game, a hint, a stuck board is all
  human-readable text you can paste into a conversation and reason about together.
  That was the single biggest force-multiplier for debugging the game.

The examples *are* the spec — read [`../../../conformance/scenarios/`](../../../conformance/scenarios/)
(start with `undo_walkthrough.dsl`) rather than hunting for a syntax reference.
It's a niche win, earned because everything here is cards-and-coordinates.

## The `Game/` modules

- [`Model.elm`](Model.elm) — the model and `applyEvent` (how a game event mutates state).
- [`Msg.elm`](Msg.elm) — the typed message set; the spine of the update loop.
- [`View.elm`](View.elm) — composes status bar, sidebar, board, and popups into the 1100×700 frame.
- [`Wire.elm`](Wire.elm) — the HTTP surface to the dumb server (new session, fetch log, post action).
- [`Util.elm`](Util.elm) — a leaf of pure helpers; imports nothing else in the subtree.

Most of the real machinery (referee, dealer, drag, animation, the DSL parsers) is
shared and lives in [`../Lib/`](../Lib/), used by both the game and the puzzle.

## Building & running

`ops/start` from the repo root rebuilds everything and serves `/game` on `:9001`.
The front-end is built (`ops/build_elm`, `ops/build_engine_js`) and `@embedFile`'d
into the binary. While working here, gate with **`ops/check_lynrummy`** (~30s:
zig build + doc-link check + Elm and TS suites); `ops/check` is the full
pre-commit gate. Deploy is the occasional, deliberate `ops/deploy` (Steve's
sign-off only). Run `ops/list` for the script index.

## Status: mature and parked

Lyn Rummy is the oldest of the site's subsystems and is no longer under active
development — it works, it ships, attention has moved elsewhere. **The code is the
authority** for how anything works; this file and its siblings orient a human, and
you (or an agent you're working with) are welcome to build on top of what Steve and
Claude wrote — start here, then [`../../../ARCHITECTURE.md`](../../../ARCHITECTURE.md),
then the engine docs in [`../../../ts/`](../../../ts/).
