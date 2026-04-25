# LynRummy — Elm UI subsystem

**Status:** `STILL_EVOLVING` (stub). Expect this to grow.

This subtree is the Elm LynRummy client — a complete player
with a browser-based presentation layer. It captures live
gestures, runs its own referee, keeps its own action log,
renders the board + hand, and replays stored logs.

## First-time setup

```
npm install   # pins elm + elm-test locally; see package.json
```

That materializes `./node_modules/.bin/elm` and
`./node_modules/.bin/elm-test`, which `./check.sh` and
`ops/start` invoke directly (no `npx` bootstrap tax). The
`node_modules/` dir is gitignored.

## Before reading the Elm code

Start with
[`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the
system-wide LynRummy architecture document. In particular,
the sections on **events drive the system**, **each actor
owns its own view**, and **Elm is layered around source-aware
events** are the context that makes the layered module
structure here make sense.

## Then — read sidecars

Every `.elm` file under `src/` has a sibling `.claude`
sidecar. The sidecars describe each module's role within
Elm's layering (capture / integration / execution / render).

Starting points, organized by layer:

- **Capture.** `src/Main/Gesture.claude` (pointer events),
  `src/Main/Wire.claude` (wire deliveries + the
  action-log-entry decoder), and `src/Main/Msg.claude` (the
  unified Msg type).
- **Integration.** `src/Game/Referee.claude` (Elm's own
  referee — does NOT rely on the Go referee).
- **Execution.** `src/Main/Apply.claude` (applyAction),
  `src/Game/Reducer.claude` (the pure action-log
  reducer), `src/Game/Game.claude` (turn transitions).
- **Render.** `src/Main/View.claude` (top-level composition
  + pinned layout), `src/Game/View.claude` (rendering
  primitives), `src/Game/HandLayout.claude` and
  `src/Game/BoardGeometry.claude` (frame constants).

## Domain modules

`src/Game/` also holds the Elm port of the game's domain
types: `Card.claude`, `CardStack.claude`, `Hand.claude`,
`Dealer.claude`, `StackType.claude`, etc. These mirror the
Go package; each sidecar states where it stands relative to
its Go counterpart.

## User-flow enumeration

[`USER_FLOWS.md`](./USER_FLOWS.md) — enumerated user-facing
flows (start a new game, play a card, complete a turn,
replay). Atomic step granularity with ✅/🟡/❌ status. Read
this when planning a UX change; write here FIRST when adding
a new flow.

## Embeddable-component design goal

The app is structured so `Main.Play` can be embedded into
hosts other than `Main.elm` (for example BOARD_LAB's
`games/lynrummy/board-lab/elm/src/Lab.elm`, where each
puzzle panel embeds its own `Play.Model`). The split:

- **`Main.Play`** — the embeddable component. Exposes
  `Config` (NewSession / ResumeSession / PuzzleSession),
  `Model`, `Msg`, `Output`, plus `init / update / view /
  subscriptions`.
- **`Main.elm`** — thin harness (~70 lines): owns the
  URL-pinning port, `Browser.element` boot, and the
  viewport-filling outer shell. Routes Play's Output
  into port calls.
- **`Main.State.Model.gameId`** — per-instance id used by
  `State.boardDomIdFor` so multiple Play instances can
  coexist on one page without DOM collisions.

When adding a new surface that might embed Play (tutorial
host, side-by-side agent-vs-human viewer, etc.), import
`Main.Play` directly and follow the Lab.elm pattern.
Game.Replay follows the same shape (extracted earlier via
REFACTOR_ELM_REPLAY).

## Port history

[`PORTING_NOTES.md`](./PORTING_NOTES.md) and
[`TS_TO_ELM.md`](./TS_TO_ELM.md) are historical records of
the TS → Elm port. Process reflections, mapping references.
Not current-work references.

## Upcoming: agent-library port

The Python four-bucket BFS planner
(`../python/bfs_solver.py` and friends) is queued for an
Elm port — see Steve's MAJOR_GOAL kickoff 2026-04-25. Once
landed, the Elm UI gains agent-level hints and geometry
planning natively. The
`enumerate_moves` conformance scenarios in
`../conformance/scenarios/planner.dsl` already emit Elm
test stubs (`Expect.pass`); those become live assertions
when the planner module lands.

## TODO (stub-level)

- Document the replay state machine (`PreRoll` / `Animating`
  / `Beating`) in terms of the capture-vs-synthesis
  distinction.
- Document the pinned-viewport discipline explicitly once the
  layout pivot lands.
- Land the BFS-planner port (see § Upcoming above).
