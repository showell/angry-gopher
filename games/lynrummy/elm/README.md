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
- **Integration.** `src/Game/Referee.elm` (Elm's own
  referee — does NOT rely on the Go referee).
- **Execution.** `src/Main/Apply.elm` (applyAction),
  `src/Game/Reducer.elm` (the pure action-log
  reducer), `src/Game/Game.elm` (turn transitions).
- **Render.** `src/Main/View.elm` (top-level composition
  + pinned layout), `src/Game/View.elm` (rendering
  primitives), `src/Game/HandLayout.elm` and
  `src/Game/BoardGeometry.elm` (frame constants).

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
The full five-class volatility taxonomy is laid out in
`../python/README.md` § "Class-1/2 segregation".)

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
Test count was 675 → 727 after the test-lock pass on
2026-04-28.

**Why this matters as a layering principle.** See the
volatility-class memory at
`~/.claude/projects/-home-steve-showell-repos-angry-gopher/memory/feedback_segregate_by_volatility_class.md`.
Rules layer at the bottom; physics, UX cadence, and
layout sit above it with progressively lighter test rigor.

**Python parallel.** `../python/README.md` has a parallel
section describing where the Python rule code currently
lives (in `cards.py` + `buckets.py` etc., ungrouped) and
the goal of mirroring Elm's `Game/Rules/` shape on the
Python side. Cross-language sub-agents working on the
parallel migration should read both READMEs.

## User-flow enumeration

[`USER_FLOWS.md`](./USER_FLOWS.md) — enumerated user-facing
flows (start a new game, play a card, complete a turn,
replay). Atomic step granularity with ✅/🟡/❌ status. Read
this when planning a UX change; write here FIRST when adding
a new flow.

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

## Port history

[`PORTING_NOTES.md`](./PORTING_NOTES.md) and
[`TS_TO_ELM.md`](./TS_TO_ELM.md) are historical records of
the TS → Elm port. Process reflections, mapping references.
Not current-work references.

## Agent-library port (in progress, with drift)

The Python four-bucket BFS planner
(`../python/bfs.py` and friends) was ported to Elm
under `src/Game/Agent/` — see Steve's MAJOR_GOAL kickoff
2026-04-25. Modules landed:
`Buckets`, `Cards`, `Move`, `Enumerator`, `Bfs`, `Verbs`,
`GeometryPlan`. 47 agent-specific tests + 6 conformance
scenarios live on both sides.

**Drift since the port (Python-side OPTIMIZE_PYTHON work,
2026-04-25 / 26).** Python evolved further while the Elm
agent stayed at the phase-5 snapshot. Status as of
2026-04-26:

**Already ported (2026-04-26):**

- **`SplitOut` extract verb** — fifth verb, fills the
  interior-of-length-3-run gap so every helper card is
  reachable for absorption. Test:
  `tests/Game/Agent/EnumeratorTest.elm`.
- **Doomed-third filter** (merge-time) — `admissiblePartial`
  in `Enumerator.elm` rejects length-2 merges whose
  completion candidates are absent from the board's
  inventory.
- **State-level doomed-growing filter** — `enumerateMoves`
  short-circuits to `[]` when any growing 2-partial has
  no completion candidate left.
- **Focus rule + lineage tracking** — `FocusedState =
  { buckets, lineage }`; the BFS engine wraps every state
  with a lineage queue (initialized as `trouble ++
  growing`) and only yields moves that grow or consume
  `lineage[0]`. Helpers `moveTouchesFocus`,
  `updateLineage`, `enumerateFocused`, `initialLineage`
  in `Enumerator.elm`. Bfs sig encodes lineage in queue
  order. Public `solve : Buckets -> Maybe Plan` API
  unchanged — the focused state is built internally.
- **Loop inversion via `extractableIndex`** — built once
  per state from the helper bucket; absorb path iterates
  the absorber's neighbor shapes and looks up matching
  helper positions in `O(1)` per shape rather than
  scanning every (helper × ci) and filtering. Shift's
  donor lookup also reads the index (filtered to peels)
  instead of building a separate peelable index. Mirrors
  Python's 2026-04-26 consolidation; ~75 lines of
  `peelableCards` + `runEnds` retired.

**Not yet ported:**
- **Budget cap drop** — `_PROJECTION_MAX_STATES` 200000
  → 5000 in Python after the filters made the cap headroom
  unnecessary.
- **`narrate(desc)` / `hint(desc)`** — Python-side renderers
  for Steve-facing evocative output and player-facing
  vague nudges. Elm conformance stubs `Expect.pass` for
  scenarios asserting on these.
- **`solve_state_with_descs(... on_cap_exhausted=...)`** —
  Python-side diagnostics callback (cap, expansions, seen,
  hit_max_states, trouble-count histogram, sample states).
- **`agent_prelude.find_play(stats=...)` + `_with_budget`** —
  Python instrumentation for per-projection timing +
  cap-exhaustion records.
- **`agent_game.py --offline`** — Python's BFS-only
  self-play mode. No Elm equivalent (and may not need one
  given Elm's natural single-process loop).

The Python side also has a host of OPTIMIZE_PYTHON
diagnostic tools (`perf_harness.py`, `mine_doomed_growing.py`,
`diagnose_loop.py`, `runaway_puzzles.py`, etc.) that don't
need direct Elm equivalents — they're profiling tools, not
gameplay code. Their LESSONS (e.g., the doomed-third filter)
do need to port.

**Conformance bridge holds**: `planner.dsl` scenarios have
6 cases live on both sides, plus several `expect:
narrate_contains` / `hint_contains` stubbed on the Elm
side until the renderers port. Python passes 37/37; Elm
passes the subset relevant to its current state.

When the Elm port resumes, the port discipline is: take
the current Python source, port the new feature, run the
shared regression methodology
(see `../python/README.md` § Validation methodology), then
verify Elm conformance stubs flip to live where applicable.

## TODO (stub-level)

- Port `narrate` / `hint` renderers; flip the Elm
  conformance stubs to live assertions.
- Document the replay state machine (`PreRolling` / `Animating`
  / `Beating`) in terms of the capture-vs-synthesis
  distinction.
- Document the pinned-viewport discipline explicitly once
  the layout pivot lands.
