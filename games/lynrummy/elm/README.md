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
- **Integration.** `src/LynRummy/Referee.claude` (Elm's own
  referee — does NOT rely on the Go referee).
- **Execution.** `src/Main/Apply.claude` (applyAction),
  `src/LynRummy/Reducer.claude` (the pure action-log
  reducer), `src/LynRummy/Game.claude` (turn transitions).
- **Render.** `src/Main/View.claude` (top-level composition
  + pinned layout), `src/LynRummy/View.claude` (rendering
  primitives), `src/LynRummy/HandLayout.claude` and
  `src/LynRummy/BoardGeometry.claude` (frame constants).

## Domain modules

`src/LynRummy/` also holds the Elm port of the game's domain
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

## Port history

[`PORTING_NOTES.md`](./PORTING_NOTES.md) and
[`TS_TO_ELM.md`](./TS_TO_ELM.md) are historical records of
the TS → Elm port. Process reflections, mapping references.
Not current-work references.

## TODO (stub-level)

- Document the replay state machine (`PreRoll` / `Animating`
  / `Beating`) in terms of the capture-vs-synthesis
  distinction.
- Document the pinned-viewport discipline explicitly once the
  layout pivot lands.
