# LynRummy — Python agent subsystem

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
from this directory. Expect every `test_*.py` to pass +
113/113 conformance. If anything is red, **stop** — pre-
existing failures are not permission to merge. Park your
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

For performance regression testing, use the automated timing checker:
```
python3 check_baseline_timing.py
```
This reads `baseline_board_81_timing.json` (stored baseline) and
times each of the 81 scenarios against the live solver. Only
scenarios with baseline > 200ms are checked (Python timer noise
dominates below that); currently that covers three "live-but-hard"
singletons (2S'≈663ms, 2C'≈517ms, 3H'≈280ms). A >10% slowdown
on any of those is flagged as a regression.

To regenerate the baseline after a solver improvement:
```
python3 tools/gen_baseline_board.py    # writes DSL + timing JSON
ops/check-conformance                  # picks up any DSL changes
python3 check_baseline_timing.py       # verify new baseline passes
```
Commit both `baseline_board_81.dsl` and `baseline_board_81_timing.json`.

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

**Step 6: Validation methodology** for any change touching
the BFS planner — see § "Validation methodology" below.
For non-planner changes, `./check.sh` is the gate.

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
  `kinds_after_splice` / `splice`. Class-3 strategy. The Elm
  parallels live in `Game.Agent.Enumerator` and the upcoming
  `Game.Agent.ClassifiedCardStack` port.
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
- `bench_outer_shell.py` — benchmarks the outer shell on the fixed
  60×6-card corpus from the Game 17 remaining 81 cards. Compares
  singleton-only vs. full (triple + pair + singleton) for plan
  quality and wall time. Gold output in `bench_outer_shell_gold.txt`.
- `agent_game.py` — autonomous-play harness:
  dealer.deal → loop find_play → place + plan → complete_turn.
- `bfs_play.py` — the replay driver: BFS plan executed
  on the actual board, watchable in the browser.
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
- `puzzle_catalog.py` — reads mined puzzles from
  `lynrummy_puzzle_seeds` and writes the JSON the Elm
  Puzzles gallery loads.
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
To regenerate the full 81-card suite after a solver change, use
`tools/gen_baseline_board.py` (see § "Agent orientation" Step 4).

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
  `tools/gen_baseline_board.py`.
- `planner.dsl` — `enumerate_moves` unit scenarios.
- `hint_game_seed42.dsl` — `hint_for_hand` conformance (Python only).
- `referee.dsl`, `board_geometry.dsl`, `drag_invariant.dsl`,
  `gesture.dsl` — UI/referee ops (Elm-primary).

`test_dsl_conformance.py` is the Python runner; `ops/check-conformance`
is the full gate (fixturegen + Python + Elm).

## Test contracts

The Python suite (run each test file directly) covers:

- `test_classified_card_stack.py` — 76 tests covering the
  CCS data type, the 7-kind classifier, the five verb
  predicates + executors, the absorb probes, and the splice
  probe + executor (including a parity test that diffs the
  parent-kind splice shortcut against the rigorous
  classifier across many positions).
- `test_buckets_boundary.py` — 23 tests covering
  `classify_buckets` (the BFS input boundary) and the state
  ops (`state_sig`, `trouble_count`, `is_victory`) under
  CCS-shaped buckets.
- `test_bfs_extract.py` — 16 tests pinning the verb-executor
  decomposition (`_extract_pieces` per verb + purity
  contracts on `do_extract`, `remove_absorber`, `graduate`).
- `test_bfs_enumerate.py` — 8 tests: snapshot per move
  type + doomed-third filter pinning
  (`test_doomed_partial_pruned`,
  `test_doomed_growing_partial_is_reachable`).
- `test_bfs_failure.py` — 8 wall-time-guarded tests pinning
  futility detection (singleton with no board, set partial
  with no third, lonely-trouble-rich-helpers, etc).
- `test_verbs.py` — 7 tests across all 5 BFS desc types,
  asserting both primitive shape and post-trick geometry.
- `test_plan_merge_hand.py` — 3 tests for the geometry
  pre-flight planner.
- `test_follow_up_merges.py` — 7 tests for the post-trick
  follow-up scan.
- `test_dsl_conformance.py` — 183 cross-language scenarios
  compiled from the conformance DSL (referee + hint +
  planner; planner.dsl includes futility cases via
  `expect: no_plan`).
- `test_agent_prelude.py` — 7 tests for the hand-aware
  outer loop (pair-with-third, pair-via-BFS, singleton
  fallback, stuck → None, pair-priority).
- `test_gesture_synth.py` — 7 tests for drag-path synthesis.

## Validation methodology (preventing solver regressions)

After any change touching the BFS planner modules
(`bfs.py` / `enumerator.py` / `move.py` /
`classified_card_stack.py` / `buckets.py` / `rules/`) or the
`verbs.py` / `primitives.py` / `agent_prelude.py` layers,
run all of:

1. **Unit + conformance suite** — run the gate script:
   ```
   ./check.sh
   ```
   `check.sh` runs every `test_*.py` in this directory and
   exits non-zero if any file fails (either by non-zero
   exit code OR by printing a `FAIL`/`FAILED` marker
   inline). Tests aren't load-bearing without enforcement;
   this script IS the enforcement. Solver-touching work
   must run it before commit. See
   `memory/feedback_tests_arent_load_bearing_without_enforcement.md`.

2. **Corpus regression** — depths must match the gold
   baseline at `corpus/baseline_post_focus.txt` (current
   gold; rerun 2026-04-27). Canonical depth distribution:
   `[2,5,2,4,5,4,6,4,1,7,2,5,2,1,1,2,3,1,2,5,1]`. The
   corpus is the 21 scenarios named `corpus_sid_*` in
   `conformance_fixtures.json` (compiled from
   `games/lynrummy/conformance/scenarios/planner_corpus.dsl`).
   Earlier baselines (`baseline_post_engulf.txt`,
   `baseline_pre_engulf.txt`, `baseline_bfs.txt`,
   `baseline.txt`) are kept as historical milestones, not
   the regression target.

3. **Baseline timing check** — verify no regressions on the
   81-card baseline suite:
   ```
   python3 check_baseline_timing.py
   ```
   Flags any scenario whose baseline exceeds 200ms and whose
   current time is >10% slower. Currently covers the three
   "live-but-hard" singletons (2S', 2C', 3H'). Exit code 1
   means a regression was detected.

   If the solver genuinely improved, regenerate the baseline:
   ```
   python3 tools/gen_baseline_board.py
   ops/check-conformance
   python3 check_baseline_timing.py
   ```
   then commit both `baseline_board_81.dsl` and
   `baseline_board_81_timing.json`.

4. **Offline self-play smoke** — quick "does autonomous
   play still terminate" check:
   ```
   python3 agent_game.py --offline --max-actions 200
   ```
   Should finish in <10s with at least a few plays
   completed.

5. **Outer shell benchmark** (for changes to `agent_prelude.py`) —
   compare singleton-only vs. full (triple + pair + singleton)
   across the fixed 60×6-card corpus:
   ```
   python3 bench_outer_shell.py
   ```
   Diff the output against the gold file:
   ```
   diff <(python3 bench_outer_shell.py) bench_outer_shell_gold.txt
   ```
   A regression looks like: full becomes slower *and* plan quality
   drops vs. the singleton-only baseline. If the solver genuinely
   improved, regenerate the gold file:
   ```
   python3 bench_outer_shell.py > bench_outer_shell_gold.txt
   ```
   then commit it.

Snapshot files are throwaway — re-capture periodically
with `agent_game.py --offline --capture FILE` to get fresh
representative samples.

## BFS performance vocabulary

**Tantalizing card** — a hand card that passes the
`_all_trouble_singletons_live` filter (a valid group using board
cards theoretically exists) but has no actual BFS solution. BFS
climbs through many cap levels before the plateau fires and confirms
`no_plan`. Tantalizing cards are the dominant driver of worst-case
outer-shell benchmark times; their apparent neighbors are locked
inside helper stacks whose dismantling causes cascading partial
stacks that cannot be reassembled.

Example: `2C:1` on the Game 17 board. Its set partners `2H:0` and
`2S:0` both exist on the board but are locked inside two separate
runs; freeing either one breaks a helper that cannot be repaired
without further dismantling.

Contrast with a **dead card** — one that fails the live-singleton
filter outright (no valid 3-card group exists in the pool at all)
and is rejected in O(1) before BFS even starts. Tantalizing cards
are the hard case; dead cards are cheap.

**Card-tracker query accelerator**: `card_neighbors.py` exposes
a 104-element `card_loc` bucket-tag array plus a precomputed `NEIGHBORS`
partner-pair table. Liveness queries are O(72) lookups instead of
O(pool²) classify scans. Used at two BFS sites: the static pre-BFS
dead-singleton filter and a dynamic per-state prune gated on
group-completion events. See [BFS_CARD_TRACKER.md](BFS_CARD_TRACKER.md).

## BFS data shape — the earned-knowledge model

The BFS solver is organized around a single principle: **every
computation should earn knowledge that the rest of the algorithm
uses, and every hot-loop operation should consume already-earned
knowledge instead of re-deriving it.** Where this conflicts with the
naive shape ("re-classify whenever you need to know what kind of
stack this is"), the data structure changes.

The pieces:

- **`ClassifiedCardStack` (CCS)** is the data shape inside BFS. Each
  CCS holds three slot reads: `cards` (tuple), `kind` (one of seven
  — `run` / `rb` / `set` / `pair_run` / `pair_rb` / `pair_set` /
  `singleton`), and `n` (cached length). No dunders — `len(stack)`,
  `for c in stack`, `stack[i]` all raise. Slot reads are direct;
  dunder dispatch is slow AND non-portable to Elm records.

- **The boundary classifies once.** `solve_state_with_descs` calls
  `classify_buckets`, which converts a raw input `Buckets` of
  card-list stacks into a `Buckets` of CCS. Any stack that fails
  to classify into one of the seven kinds raises `ValueError` —
  caller bug, not BFS bug. The "no `KIND_OTHER`" invariant holds
  inside; downstream code consumes `stack.kind` directly.

- **Probes earn the kind; executors consume it.**
  `kind_after_absorb_right(target, card)` returns the kind of the
  merged stack (or None). `absorb_right(target, card, kind)` builds
  the result with no re-validation. Same pattern for the splice
  probe + executor and for the source-side verbs (`peel` / `pluck`
  / `yank` / `steal` / `split_out`, each paired with a `can_X`
  predicate). The verb executors derive remnant kinds from the
  parent's kind family + length — no full reclassification.

- **Earned knowledge lives at the commitment point, not at
  speculative construction.** When the BFS commits to iterating one
  absorber against many candidate sources,
  `_build_absorber_shapes` earns the absorber's
  `extends: {(value, suit) → (right_kind, left_kind)}` table once.
  Hot-path callers iterate this dict — every entry guarantees at
  least one absorbing side, every (right_kind, left_kind) is the
  kind of the merged stack. No per-card probe call, no
  re-derivation. (An earlier attempt put extends tables on every
  CCS at construction; that was speculative pre-computation, not
  earned knowledge — most CCSs are never probed as absorbers, and
  paying construction cost for everyone lost the trade. The fix was
  to push the work to the absorber loop, where commitment exists.)

- **Validation is gated.** `check_baseline_timing.py` measures the
  81-card baseline suite under `bench_timing.py` (warmup +
  GC-disabled + `process_time` + min-of-20). Any hot scenario that
  regresses >10% versus the gold in `baseline_board_81_timing.json`
  fails the gate. Gold is refreshed only when the solver genuinely
  improves (regenerate via `tools/gen_baseline_board.py`, then
  commit both the JSON and the regenerated DSL).

## TODO

- Mark `strategy.py` and friends PLANNED-LEGACY in their
  module docstrings once the abandonment plan is concrete.
- The Elm port (`games/lynrummy/elm/src/Game/Agent/`) is
  feature-complete on the correctness/perf axis as of
  2026-04-26. Remaining drift is renderer-only:
  `narrate` / `hint` aren't ported, and the
  `solve_state_with_descs` diagnostics callback isn't
  ported. Neither is load-bearing.
