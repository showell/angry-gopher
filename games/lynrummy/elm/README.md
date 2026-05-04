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

For a current map of what entry points exist and how mature
each one is, see
[`../ENTRY_POINTS.md`](../ENTRY_POINTS.md). It covers both
Elm boots (`Main.elm`, `Puzzles.elm`), server handlers, CLI
tooling, and conformance test surfaces, with maturity notes.

## Then — read the load-bearing modules

Per-module roles live in each file's top-of-file comment.
The `.claude` sidecar system was retired 2026-04-28; commit
history is now the authoritative record of design decisions.

Starting points, organized by Elm's capture / integration /
execution / render layering:

- **Capture.** `src/Main/Gesture.elm` (pointer events),
  `src/Main/Wire.elm` (wire deliveries + the
  action-log-entry decoder), and `src/Main/Msg.elm` (the
  unified Msg type).
- **Integration.** `src/Game/Rules/Referee.elm` (Elm's own
  referee — does NOT rely on the Go referee).
- **Execution.** `src/Main/Apply.elm` (applyAction),
  `src/Game/Reducer.elm` (the pure action-log
  reducer), `src/Game/Game.elm` (turn transitions).
- **Render.** `src/Main/View.elm` (top-level composition
  + pinned layout), `src/Game/View.elm` (rendering
  primitives), `src/Game/HandLayout.elm` and
  `src/Game/Physics/BoardGeometry.elm` (frame constants).

## Domain modules

`src/Game/` also holds the Elm port of the game's domain
types: `CardStack.elm`, `Hand.elm`, `Dealer.elm`, etc.
These mirror the Go package; each top-of-file comment
states where it stands relative to its Go counterpart.

## Game/Rules/ — the locked-down rule layer

`src/Game/Rules/` is the **Class-1/2 truth layer**: pure
game rules and primitives that are battle-tested and not
expected to change. Locked-down by rigorous property
tests so any regression breaks loudly.

(Class-1 = game rules; Class-2 = locked domain primitives.
The full five-class volatility taxonomy lives in the
memory system at
`memory/feedback_segregate_by_volatility_class.md`.)

What lives here today (extracted 2026-04-28 in the
`game_rules_lockdown` plan):

- **`Game.Rules.Card`** — the atomic Card type, suit/value
  enums, parsers, encoders, double-deck construction.
  ~22 exports, all Class-2 primitives.
- **`Game.Rules.StackType`** — the 6-way classification
  oracle (`Incomplete | Bogus | Dup | Set | PureRun |
  RedBlackRun`), `successor`/`predecessor` on the
  13-cycle, `valueDistance`, plus the rule predicates
  `isLegalStack` / `isPartialOk` / `neighbors` (lifted
  from the now-removed `Game.Agent.Cards` module since
  they're rules, not agent strategy; the agent-side
  verb-eligibility predicates that used to share that
  module now live in `Game.Agent.Enumerator`).

What's NOT in `Game/Rules/` and the reasoning:

- **`Game.CardStack`** — has presentation state
  (`FreshlyPlayed`, `FreshlyPlayedByLastPlayer`); not
  pure Class-1/2.
- **`Game.Game`, `Game.Reducer`, `Game.Referee`** — these
  consume rules but are themselves bigger than just-rules.
  Could be revisited.
- **`Game.Agent.*`** — agent strategy is Class-3 physics +
  Class-4 search heuristics, not rules.

**Test discipline.** Tests live in
`tests/Game/CardTest.elm` and `tests/Game/StackTypeTest.elm`
(NOT under a `tests/Game/Rules/` subtree — keep test paths
flat and stable). Class-1/2 modules get
**property + boundary tests** that lock the laws (e.g.
"`getStackType` PureRun monotonic in length 3..13",
"`valueDistance` triangle inequality over 13³",
"`neighbors` cardinality is exactly 9, deck-invariant").

**Why this matters as a layering principle.** See the
volatility-class memory at
`~/.claude/projects/-home-steve-showell-repos-angry-gopher/memory/feedback_segregate_by_volatility_class.md`.
Rules layer at the bottom; physics, UX cadence, and
layout sit above it with progressively lighter test rigor.

**TS parallel.** The TS agent uses the same rule shapes;
see `../ts/src/rules/card.ts` and `../ts/src/classified_card_stack.ts`.

## Embeddable-component design goal

The app is structured so `Main.Play` can be embedded into
hosts other than `Main.elm` (for example the Puzzles
gallery's `games/lynrummy/elm/src/Puzzles.elm`, where each
puzzle panel embeds its own `Main.State.Model`). The split:

- **`Main.Play`** — the embeddable component. Exposes
  `Config` (NewSession / ResumeSession / PuzzleSession),
  `Output`, plus `init / update / view / subscriptions`
  (and `mouseMove`). The component's `Model` lives in
  `Main.State` and `Msg` in `Main.Msg`; hosts import them
  directly from there.
- **`Main.elm`** — thin harness (~70 lines): owns the
  URL-pinning port, `Browser.element` boot, and the
  viewport-filling outer shell. Routes Play's Output
  into port calls.
- **`Main.State.Model.gameId`** — per-instance id used by
  `State.boardDomIdFor` so multiple Play instances can
  coexist on one page without DOM collisions.

When adding a new surface that might embed Play (tutorial
host, side-by-side agent-vs-human viewer, etc.), import
`Main.Play` directly and follow the `Puzzles.elm` pattern.
Game.Replay follows the same shape (extracted earlier via
REFACTOR_ELM_REPLAY).

## Agent-library port — on life-support

`src/Game/Agent/` is the legacy Elm BFS port. It works in
production for the live-game hint button but is **not
actively maintained**. The canonical solver lives at
`../ts/` (`engine_v2.ts`). When `TS_ELM_INTEGRATION` lands —
routing the hint button through the TS engine via Elm
ports or a thin server endpoint — `Game.Agent.*` retires.

Until then, don't invest in catching up to TS-side solver
evolution here. Bug fixes for production behavior are in
scope; feature ports are not.

The DSL conformance bridge still runs; the Elm side passes
the subset of scenarios its frozen feature surface
supports.

Same applies to `src/Game/Strategy/` (the legacy trick
engine that drives the hint surface). It retires alongside
`Game.Agent.*`.

## TODO (stub-level)

- Port `narrate` / `hint` renderers; flip the Elm
  conformance stubs to live assertions.
- Document the replay state machine (`PreRolling` / `Animating`
  / `Beating`) in terms of the capture-vs-synthesis
  distinction.
- Document the pinned-viewport discipline explicitly once
  the layout pivot lands.
