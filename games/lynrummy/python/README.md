# LynRummy — Python agent subsystem

> **Working on the BFS solver?** Stop and read
> [`SOLVER.md`](SOLVER.md) FIRST. The solver is the #1 active
> asset of the Python codebase — its data shapes, validation
> gates, and design principles are documented there. Sub-agents
> dispatched to do solver work must be told to read it. This
> README is the front door to the subtree as a whole;
> `SOLVER.md` is the workshop floor for solver work.

**Status:** `WORKHORSE` for the BFS planner; legacy trick
engine (`strategy.py`) kept as a comparable baseline pending
its own retirement. Currently the canonical home for
strategic-brain experimentation; will be the durable
iteration surface even after the Elm port lands.

This subtree is the Python LynRummy agent — a complete player
without a presentation layer. It chooses legal moves with its
own planning logic, validates them against its own referee
equivalent, keeps its own action log, and posts events to the
server for later witness.

The agent code follows a disciplined functional-Python style:
pure helpers, lists treated as immutable values, state
threaded explicitly. See the top-of-file docstrings in
`bfs.py`, `enumerator.py`, `move.py`, and `verbs.py` for
the conventions. The discipline is by convention, not by
`frozen=True` types — Elm-readable shape, Python-idiomatic
mechanics.

## Before reading the Python code

Start with [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. The sections on
**each actor owns its own view**, **constraints must be real
not artificial**, **two coordinate frames** (board frame vs.
viewport), and **agents plan then execute** are all directly
load-bearing for why this subtree is shaped the way it is.

## Public surface — entry points for using this subsystem

If you're CONSUMING the agent (not modifying its planner), these
are the externally-callable functions you almost certainly want.
Each lives in the module named — read the top-of-file docstring
for full details:

- **`dealer.deal(num_players=2, hand_size=15, rng=None)`** —
  produce a fresh, randomly shuffled `initial_state` dict
  (board + hands + deck + discard + active player). The shape
  the server accepts on `/new-session`.
- **`agent_prelude.find_play(hand, board)`** — hand-aware outer
  loop. Search order: (a) triple-in-hand (zero BFS, best outcome),
  (b) pair-via-BFS, (c) singleton-via-BFS. Returns the candidate
  with the shortest plan, or `None` if stuck.
- **`bfs.solve(board, ...)`** — pure planner entry. Takes a
  flat board, returns the shortest plan as a list of
  description strings (or `None`).
- **`client.*`** — thin HTTP wrapper around the Gopher server
  endpoints (`new_session`, `post_action`, etc).
- **`agent_game`** (CLI) — autonomous-play harness: deal, loop
  `find_play`, place + plan, complete turn. Run with
  `python3 agent_game.py --offline` for a smoke run.

For modifying the planner itself, skip to the orientation
checklist below — that's the editing path, not the consuming
path.

## Agent orientation — about-to-do-active-work checklist

If you're a sub-agent (or a fresh-session top-level Claude)
about to do active work in this subtree, run through this
checklist BEFORE editing anything. Most items take seconds
and prevent mid-task surprises.

**Step 1: Confirm baseline is green.** Run `./check.sh`
from this directory. Expect every `test_*.py` to pass and
the conformance suite to pass. If anything is red, **stop** —
pre-existing failures are not permission to merge. Park your
task and dispatch a fix-up first (see
`memory/feedback_tests_arent_load_bearing_without_enforcement.md`).

**Step 2: Check for in-flight plan state.** Look at
`/home/steve/showell_repos/angry-gopher/.claude/plan-state.json`
— it lists tasks across the active and recent plans. If a
plan is in flight that overlaps your work, coordinate
with the orchestrator before proceeding.

**Step 3: Read the layered-shape sections of THIS file.**
The "Class-1/2 segregation" section below tells you where
rule content lives (`rules/`) vs strategy
(`classified_card_stack.py` + the planner modules) vs UX
cadence (`move.py`'s `narrate` / `hint`). Don't put new code
in the wrong layer.

**Step 4: Know the corpus baseline.** The correctness
regression target is `corpus/baseline_post_focus.txt`
(canonical depth distribution
`[2,5,2,4,5,4,6,4,1,7,2,5,2,1,1,2,3,1,2,5,1]`). The corpus
is exercised via `ops/check-conformance` (not `./check.sh`,
which is Python-only). Correctness scenarios live in three DSL
files: `planner_corpus.dsl` (21 solvable puzzles, `corpus_sid_*`),
`planner_corpus_extras.dsl` (extras including `no_plan` cases
and hand-added SOLVER_SPEED benchmarks), and `baseline_board_81.dsl`
(the 81-card baseline suite — one trouble singleton per
remaining card on the Game 17 opening board). Any solver-touching
change must keep depths ≤ gold; longer plans are correctness
failures.

Performance benchmarks now live in TS at `../ts/bench/`. Run via
npm from `../ts/`:

```
npm run bench:check-baseline   # regression-check the 81-card suite
npm run bench:gen-baseline     # regenerate gold after solver change
npm run bench:outer-shell      # 60-hand outer-shell comparison
```

The paired DSL (`conformance/scenarios/baseline_board_81.dsl`)
remains language-neutral. Gold timings live next to the TS driver
(`ts/bench/baseline_board_81_gold.txt`).

**Step 5: Ergonomics defaults (when you're refactoring or
adding code).**

- **Prefer rewrite over shim** when moving code between
  modules. Update callers; don't leave a re-export shim
  unless explicitly asked. Shims rot; physical moves
  match the layering principle.
- **Verb-eligibility predicates live on `ClassifiedCardStack`**
  (`can_peel` / `can_pluck` / `can_yank` / `can_steal` /
  `can_split_out` in `classified_card_stack.py`). Pure rule
  predicates (`is_partial_ok`, `neighbors`, `successor`) live in
  `rules/`. If you're adding a predicate, ask: "is this a
  game-rule fact, or an agent-strategy judgment?" Rule = `rules/`.
  Judgment = `classified_card_stack.py` or the planner modules.
- **Imports use the `from rules import X, Y` form**, not
  `import rules` then `rules.X`. Matches the `from
  buckets import ...` and `from move import ...`
  conventions across the planner modules. (This works
  because every script and test runs from
  `games/lynrummy/python/` as the working directory —
  the directory is the implicit package root, not a
  pip-installable package. Flat imports are the
  convention here, not a style violation.)
- **No DB or HTTP in test paths.** Conformance tests
  read `conformance_fixtures.json` (committed); tools
  that need the DB (`tools/export_primitives_fixtures.py`,
  `tools/mine_puzzles.py`) fail loud when the DB is empty.

**Step 6: Validation methodology.** For any change touching the
BFS solver (planner modules + adjacent layers), open
[`SOLVER.md`](SOLVER.md) and run the five-gate validation it
documents. The solver is where regressions hurt most; the gates
are non-negotiable. For non-solver changes, `./check.sh` is the
gate.

If after this checklist the path forward isn't clear,
**punt** with `status: blocked` rather than guessing —
that's the signal that this orientation list needs
sharpening.

**Self-test.** If you want to verify you can find your way
around before editing anything real, see
[`QUIZ_AGENT_ORIENTATION.md`](QUIZ_AGENT_ORIENTATION.md)
— a one-task exercise (produce a valid game state using
only the public API above) with an automated verifier.
Run it once and you'll know the orientation stuck.

## Class-1/2 segregation — Elm precedent, Python parallel landed

The Elm side moved its locked-down rule code into a
`Game/Rules/` subtree (Card + StackType + predicates
`isLegalStack` / `isPartialOk` / `neighbors`) plus property
tests that lock the laws — see `../elm/README.md` §
"Game/Rules/" for the precedent.

The Python parallel landed in the same shape. Class-1/2
rule content lives under `rules/`:

- **`rules/card.py`** — Card primitives: `RANKS` / `SUITS`
  / `RED` constants, `card(label, deck)` parser, `label` /
  `card_label` renderers, `color`. Mirrors
  `Game.Rules.Card`.
- **`rules/stack_type.py`** — Value-cycle (`successor`),
  classification (`classify`), and rule predicates
  (`is_partial_ok`, `neighbors`). Mirrors
  `Game.Rules.StackType`.
- **`rules/__init__.py`** — re-exports the package's
  public surface so callers write
  `from rules import classify, neighbors, RED, ...`.

What stayed where:

- **`classified_card_stack.py`** — the `ClassifiedCardStack`
  data type (cards + cached kind + cached n) + verb-eligibility
  predicates (`can_peel` etc.) + verb executors (`peel` / `pluck`
  / `yank` / `steal` / `split_out`) + the absorb probes
  (`kind_after_absorb_right` / `_left`, `extends_tables`) +
  `kinds_after_splice` / `splice`. Class-3 strategy. The TS
  sibling at `../ts/src/classified_card_stack.ts` mirrors
  this shape. The Elm `Game.Agent.Enumerator` port is on
  life-support.
- **`buckets.py`** — 4-bucket BFS state shape +
  `state_sig` + `trouble_count` + `is_victory`. Same shape
  as before — Elm keeps `Game.Agent.Buckets` outside
  `Game/Rules/`, so the Python parallel keeps it here too.
- **`move.py`** — Move desc dataclasses + describe /
  narrate / hint. Render functions are Class-4 (UX
  flavor); the dataclasses themselves are Class-2.

**The volatility-class principle in one paragraph:** code
segregates by how often its underlying truth changes.
**Class 1** = game rules (never change). **Class 2** =
domain primitives (locked, battle-tested). **Class 3** =
physics (deterministic functions, locked with property
tests). **Class 4** = UX cadence (Steve's tuning). **Class
5** = layout (fiddly). Test rigor scales to class:
strict at the bottom, light at the top. Module seams
should track class boundaries — physics living inside a
UX module is a smell; rules tangled with strategy is a
smell.

## Two strategic layers, one fading

The Python agent has two pieces of strategy code:

- **The four-bucket BFS planner**, current strategic brain
  (milestone 2026-04-25; focus rule + SPLIT_OUT verb landed
  2026-04-26 morning; module split + dataclass migration
  landed 2026-04-26 afternoon). State is `FocusedState`
  (Buckets + lineage NamedTuples); pure BFS-by-length with
  iterative max-trouble cap. 21/21 corpus solved (3 plans
  STRICTLY shorter than the pre-focus-rule baseline).
  Lives in five focused modules mirroring Elm's
  `Game.Agent.*` tree:
  - `buckets.py` — state shape + state_sig + type aliases +
    `classify_buckets` boundary helper
  - `classified_card_stack.py` — the CCS data type + 7-kind
    alphabet + verb predicates/executors + absorb probes
    (`extends_tables`) + splice probe/executor
  - `move.py` — desc dataclasses + describe / narrate / hint
  - `enumerator.py` — move generator dispatcher + per-move-
    type helpers + focus rule + filters
  - `bfs.py` — search engine
  Plus the `rules/` subpackage (Class-1/2 truth layer):
  card model + rule predicates. (`classify` lives here too
  for non-BFS callers; the BFS hot path uses
  `ClassifiedCardStack.kind`.)

- **`strategy.py` — the trick engine**, legacy. Per-trick
  emitters (`direct_play`, `pair_peel`, `split_for_set`, …)
  that produce primitive sequences for high-confidence
  patterns. Still wired into the Elm conformance hint
  scenarios; abandonment plan is in flight.

## The Python agent's stance — plan, then execute

The agent mimics a human's small-scale spatial planning.
Before emitting a primitive sequence, it simulates the
final board and every intermediate state, and pre-plans
geometry corrections upstream — not after.
`strategy.py`'s `_plan_merge_hand` is the canonical
implementation of this discipline (still load-bearing for
trick output as long as `strategy.py` is alive).

Concrete examples of what this buys us:
- The replay shows a coherent sequence of human-plausible
  moves, not "ugly in the middle, fine at the end."
- Scope of planning stays shallow (2–3 logical board
  changes, up to 6–7 primitives) — well within what a
  human does in their head.
- `_fix_geometry` stays as a last-ditch safety net; it
  should rarely fire, and when it does it's a signal that
  the trick-specific emitter needs a plan upgrade.

## Then — read the load-bearing modules

Per-module roles live in each file's top-of-file docstring.
The `.claude` sidecar system was retired 2026-04-28; commit
history is now the authoritative record of design decisions.

Ordered by "load-bearing first":

- **BFS planner — five-module split.**
  **Start here for any planner-side work.**
  - `bfs.py` — the search engine (`solve`, `bfs_with_cap`).
    Boundary: `solve_state_with_descs` calls `classify_buckets`,
    promoting raw input to CCS once at entry.
  - `enumerator.py` — move generator dispatcher; per move type
    (extract+absorb, free pull, shift, splice, push, engulf)
    a small focused helper. Focus rule + doomed-third filter
    + extractable index.
  - `classified_card_stack.py` — the `ClassifiedCardStack`
    data type, the 7-kind alphabet, the verb predicates +
    executors, the absorb probes (`kind_after_absorb_*`,
    `extends_tables`), and the splice probe + executor.
    Most of the BFS hot-path arithmetic lives here.
  - `move.py` — Move desc dataclasses + describe / narrate
    / hint.
  - `buckets.py` — 4-bucket state shape + `classify_buckets`
    boundary helper + `state_sig` + type aliases.
- **Rules subpackage** (Class-1/2 truth layer; mirrors Elm
  `Game/Rules/`). Used by callers OUTSIDE the BFS hot path —
  see "BFS data shape" below for why.
  - `rules/card.py` — card model + label parser/renderers +
    suit color.
  - `rules/stack_type.py` — `successor`, `is_partial_ok`,
    `neighbors`. (`classify` also lives here for non-BFS
    callers; the BFS hot path uses `ClassifiedCardStack.kind`
    instead.)
- `verbs.py` — VERB → PRIMITIVE library; decomposes a
  BFS desc into UI primitives via content-based stack lookup.
- `primitives.py` — PRIMITIVE → GESTURE library;
  to_wire_shape / apply_locally / send_one. The canonical
  send path used by every driver.
- `agent_prelude.py` — hand-aware outer loop. Search order:
  (a) triple-in-hand (zero BFS, best outcome), (b) pair-via-BFS,
  (c) singleton-via-BFS. `find_play_with_budget` is the budgeted
  variant; `find_play` uses defaults.
- `agent_game.py` — autonomous-play harness:
  dealer.deal → loop find_play → place + plan → complete_turn.
- `strategy.py` — the trick engine. PLANNED-LEGACY but
  still wired. Per-trick emitters, primitive ordering
  discipline, plan-then-execute for `merge_hand`.
- `geometry.py` — board-frame geometry primitives
  (find_open_loc, find_violation, pinned viewport
  constants).
- `gesture_synth.py` — synthesizes intra-board
  floater-top-left paths where Python knows both endpoints.
- `client.py` — thin HTTP wrapper around the Gopher
  endpoints.
- `puzzle_catalog.py` — reads
  `games/lynrummy/conformance/mined_seeds.json` and writes
  the JSON the Elm Puzzles gallery loads. (Per the no-DB
  policy: mined seeds live in the repo as JSON.)
- `telemetry.py` — read-side of the DB's gesture
  capture. Analysis, not gameplay.

### Corpus regression

The corpus regression target lives in
`corpus/baseline_post_focus.txt`. Three DSL files contribute
corpus scenarios: `planner_corpus.dsl` (21 solvable puzzles,
`corpus_sid_*`), `planner_corpus_extras.dsl` (unsolvable cases
and SOLVER_SPEED timing benchmarks, `extra_*`), and
`baseline_board_81.dsl` (auto-generated 81-card baseline suite,
`baseline_board_*`). Run via `ops/check-conformance` — that
invokes `cmd/fixturegen` to compile fixtures, then Python
`test_dsl_conformance.py`, then the Elm suite.

To add a hand-crafted benchmark case, add it to
`planner_corpus_extras.dsl` and re-run `ops/check-conformance`.
To regenerate the full 81-card suite after a solver change, run
`npm run bench:gen-baseline` from `../ts/` (see § "Agent
orientation" Step 4).

The pre-DSL corpus tooling (`corpus_report.py`,
`corpus_lab_catalog.py`) and the agent-vs-human harness
(`agent_board_lab.py`, `board_lab_puzzles.py`, `study.py`)
were purged 2026-04-27. The older DSL pipeline
(`dsl_planner` / `dsl_player` / `board_classifier` /
`dsl`) and the IDDFS planner (`beginner` /
`run_corpus_v2` / `beginner_corpus`) were purged
2026-04-27. Their roles are now covered by the
DSL conformance pipeline plus replay walkthroughs.

## The DSL conformance bridge

Python + Elm both exercise the same scenarios, defined once
in `games/lynrummy/conformance/scenarios/*.dsl` and compiled
by `cmd/fixturegen` into Python JSON fixtures + Elm test
files. Central cross-language bridge per `BRIDGES.md`.
Scenario files (run `ops/check-conformance` to regenerate
after any DSL edit):

- `planner_corpus.dsl` — 21 solvable corpus puzzles (`corpus_sid_*`).
- `planner_corpus_extras.dsl` — unsolvable cases + SOLVER_SPEED
  timing benchmarks (`extra_*`). Hand-editable; new benchmark
  cases go here.
- `baseline_board_81.dsl` — auto-generated 81-card baseline suite
  (`baseline_board_*`). Do not hand-edit; regenerate via
  `npm run bench:gen-baseline` (in `../ts/`).
- `planner.dsl` — `enumerate_moves` unit scenarios.
- `hint_game_seed42.dsl` — `hint_for_hand` conformance (Python only).
- `referee.dsl`, `board_geometry.dsl`, `drag_invariant.dsl`,
  `gesture.dsl` — UI/referee ops (Elm-primary).

`test_dsl_conformance.py` is the Python runner; `ops/check-conformance`
is the full gate (fixturegen + Python + Elm).

## Test contracts

The Python suite (run each test file directly) covers:

- `test_classified_card_stack.py` — CCS data type, 7-kind
  classifier, the five verb predicates + executors, absorb
  probes, splice probe + executor (including a parity test
  diffing the parent-kind splice shortcut against the rigorous
  classifier across many positions).
- `test_buckets_boundary.py` — `classify_buckets` (the BFS
  input boundary) and state ops (`state_sig`, `trouble_count`,
  `is_victory`) under CCS-shaped buckets.
- `test_bfs_extract.py` — verb-executor decomposition
  (`_extract_pieces` per verb + purity contracts on
  `do_extract`, `remove_absorber`, `graduate`).
- `test_bfs_enumerate.py` — snapshot per move type +
  doomed-third filter pinning (`test_doomed_partial_pruned`,
  `test_doomed_growing_partial_is_reachable`).
- `test_bfs_failure.py` — wall-time-guarded tests pinning
  futility detection (singleton with no board, set partial
  with no third, lonely-trouble-rich-helpers, etc).
- `test_verbs.py` — all 5 BFS desc types, asserting both
  primitive shape and post-trick geometry.
- `test_plan_merge_hand.py` — geometry pre-flight planner.
- `test_follow_up_merges.py` — post-trick follow-up scan.
- `test_dsl_conformance.py` — cross-language scenarios
  compiled from the conformance DSL (referee + hint +
  planner; planner.dsl includes futility cases via
  `expect: no_plan`).
- `test_agent_prelude.py` — hand-aware outer loop
  (pair-with-third, pair-via-BFS, singleton fallback,
  stuck → None, pair-priority).
- `test_gesture_synth.py` — drag-path synthesis.

## Solver work — see SOLVER.md

If your work touches the BFS solver (`bfs.py`, `enumerator.py`,
`classified_card_stack.py`, `move.py`, `buckets.py`, the `rules/`
subpackage, or the `verbs.py` / `primitives.py` / `agent_prelude.py`
adjacent layers), [`SOLVER.md`](SOLVER.md) is the canonical
reference. It documents:

  - The core principle (earn knowledge, use earned knowledge —
    commitment vs. speculation).
  - The BFS data shape (CCS, the 7-kind alphabet, three-bucket
    extends, no-dunder discipline).
  - The "no side parameter" rule.
  - The cross-language iteration-order canon (don't break Elm).
  - The five-gate validation methodology that every solver-touching
    change must run.
  - Bench gold files (in `../ts/bench/`: `baseline_board_81_gold.txt`,
    `bench_outer_shell_gold.txt`) and their capture process.
  - Pre-port discipline for the upcoming TypeScript engine.

Sub-agents dispatched to solver work must be told to read
`SOLVER.md`. The cost of a missed regression in the solver is high.

For the broader `corpus/baseline_post_focus.txt` correctness
regression target (depth distribution
`[2,5,2,4,5,4,6,4,1,7,2,5,2,1,1,2,3,1,2,5,1]`, 21 scenarios named
`corpus_sid_*`), see SOLVER.md § Validation methodology.

For non-solver changes, `./check.sh` is the gate.

## Sibling: TypeScript engine

A TS port of the BFS engine lives at `../ts/`. Status: leaves
complete (214 DSL scenarios), engine v1 complete (148 plan-line
cross-check vs Python), browser integration pending. The TS engine
will replace the Elm BFS in the browser. Python remains the
experimentation surface; TS tracks Python via the DSL conformance
contract. See [`../ts/README.md`](../ts/README.md) and
[`SOLVER.md`](SOLVER.md) § "TypeScript sibling — landed v1".

The Elm BFS (`elm/src/Game/Agent/`) is on life-support — it works
in production but has drifted from Python and is not actively
maintained. Don't invest in further Elm-side BFS work.

## TODO

- Mark `strategy.py` and friends PLANNED-LEGACY in their
  module docstrings once the abandonment plan is concrete.
