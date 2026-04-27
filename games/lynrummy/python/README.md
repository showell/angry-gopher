# LynRummy — Python agent subsystem

**Status:** `WORKHORSE` for the BFS planner; older trick
engine + DSL pipeline kept as comparable baselines pending
retirement decisions. Currently the canonical home for
strategic-brain experimentation; will be the durable
iteration surface even after the Elm port lands.

This subtree is the Python LynRummy agent — a complete player
without a presentation layer. It chooses legal moves with its
own planning logic, validates them against its own referee
equivalent, keeps its own action log, and posts events to the
server for later witness.

The agent code follows a disciplined functional-Python style:
pure helpers, lists treated as immutable values, state
threaded explicitly. See `bfs.claude` / `enumerator.claude`
/ `move.claude` and `verbs.claude` for the conventions. The
discipline is by convention, not by `frozen=True` types —
Elm-readable shape, Python-idiomatic mechanics.

## Before reading the Python code

Start with [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. The sections on
**each actor owns its own view**, **constraints must be real
not artificial**, **two coordinate frames** (board frame vs.
viewport), and **agents plan then execute** are all directly
load-bearing for why this subtree is shaped the way it is.

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
  - `buckets.py` — state shape + state_sig + type aliases
  - `cards.py` — card primitives + verb eligibility
  - `move.py` — desc dataclasses + describe / narrate / hint
  - `enumerator.py` — move generator + focus rule + filters
  - `bfs.py` — search engine
  See per-module `*.claude` sidecars.

- **`beginner.py` — the IDDFS planner**, prior strategic
  brain.
  Trouble-driven search using PULL verbs (peel / pluck / yank
  / steal) and PUSH verbs (onto-set, onto-run-end). IDDFS
  returns shortest plans within a budget of trouble cards.
  Trouble-as-actor DSL: `5C 6C peel-pulls [4C] 5C 6C {-4C- 4D
  4S 4H}`. See `beginner.claude`.

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

## Then — read sidecars

Full sidecar coverage as of 2026-04-25. Run
`python3 ../../../tools/sidecar_audit.py` to verify.

Ordered by "load-bearing first":

- **BFS planner — five-module split** (post-2026-04-26).
  **Start here for any planner-side work.**
  - `bfs.claude` — the search engine (`solve`,
    `bfs_with_cap`).
  - `enumerator.claude` — INTRICATE move generator; focus
    rule + doomed-third filter + extractable index.
  - `move.claude` — Move desc dataclasses + describe /
    narrate / hint.
  - `buckets.claude` — state shape + `state_sig` + type
    aliases.
  - `cards.claude` — card primitives + verb eligibility.
- `verbs.claude` — VERB → PRIMITIVE library; decomposes a
  BFS desc into UI primitives via content-based stack lookup.
- `primitives.claude` — PRIMITIVE → GESTURE library;
  to_wire_shape / apply_locally / send_one. The canonical
  send path used by every driver.
- `agent_prelude.claude` — hand-aware outer loop;
  `find_play(hand, board)` returns a plausible play.
- `agent_game.claude` — autonomous-play harness:
  dealer.deal → loop find_play → place + plan → complete_turn.
- `bfs_play.claude` — the replay driver: BFS plan executed
  on the actual board, watchable in the browser.
- `beginner.claude` — the IDDFS predecessor. Kept for now
  as a comparable baseline; same corpus minus 1 stuck.
- `strategy.claude` — the trick engine. PLANNED-LEGACY but
  still wired. Per-trick emitters, primitive ordering
  discipline, plan-then-execute for `merge_hand`.
- `geometry.claude` — board-frame geometry primitives
  (find_open_loc, find_violation, pinned viewport
  constants).
- `gesture_synth.claude` — synthesizes intra-board
  floater-top-left paths where Python knows both endpoints.
- `client.claude` — thin HTTP wrapper around the Gopher
  endpoints.
- `puzzle_catalog.py` — reads mined puzzles from
  `lynrummy_puzzle_seeds` and writes the JSON the Elm
  Puzzles gallery loads.
- `telemetry.claude` — read-side of the DB's gesture
  capture. Analysis, not gameplay.
- Repo-wide tooling at `../../../tools/sidecar_audit.{claude,py}`
  — drift + coverage check across all sidecars.

### Corpus runners

- `run_corpus_v2.claude` — beginner-side counterpart.
- `beginner_corpus.claude` — hand-built fixtures for
  beginner.py before/after testing.

The pre-DSL corpus tooling (`corpus_report.py`,
`corpus_lab_catalog.py`) and the agent-vs-human harness
(`agent_board_lab.py`, `board_lab_puzzles.py`, `study.py`)
were purged 2026-04-27. Their role is now covered by the
DSL conformance pipeline plus replay walkthroughs.

### Older DSL pipeline (retirement TBD)

`dsl_planner.claude`, `dsl_player.claude`,
`board_classifier.claude`, `dsl.claude` — peel/park/extend/
dissolve/home verb vocabulary, pre-dates the four-bucket
BFS planner. Kept as a comparable baseline; not
load-bearing.

### Legacy puzzle harness (queued for purge)

`puzzles.claude`, `puzzle_harness.claude`, `compare.claude`
— pre-Puzzles-gallery Python cluster. See MINI_PROJECTS /
PURGE_LEGACY_PUZZLE_HARNESS.

## The DSL conformance bridge

Python + Elm both exercise the same scenarios, defined once
in `games/lynrummy/conformance/scenarios/*.dsl` and compiled
by `cmd/fixturegen` into Python JSON fixtures + Elm
Elm-test files. Central cross-language bridge per
`BRIDGES.md`. Three scenario files today:

- `referee.dsl` — referee ops (Go + Elm).
- `tricks.dsl` — hint/trick invariants (Elm + Python;
  retiring with the trick engine).
- `planner.dsl` — `enumerate_moves` over the four-bucket
  state. Python today; Elm gains live assertions when the
  BFS planner ports.

`test_dsl_conformance.py` is the Python runner — 24/24
scenarios pass as of 2026-04-25.

## Test contracts

The Python suite (run each test file directly) covers:

- `test_bfs_extract.py` — 15 tests pinning
  `_extract_pieces` per verb plus purity contracts on
  `_do_extract`, `_remove_absorber`, `_graduate`.
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
- `test_dsl_conformance.py` — 37 cross-language scenarios
  compiled from the conformance DSL (referee + hint +
  planner; planner.dsl includes futility cases via
  `expect: no_plan`).
- `test_agent_prelude.py` — 7 tests for the hand-aware
  outer loop (pair-with-third, pair-via-BFS, singleton
  fallback, stuck → None, pair-priority).
- `test_gesture_synth.py` — 7 tests for drag-path synthesis.

## Validation methodology (preventing solver regressions)

After any change touching the BFS planner modules
(`bfs.py` / `enumerator.py` / `move.py` / `cards.py` /
`buckets.py`) or the `verbs.py` / `primitives.py` /
`agent_prelude.py` layers, run all of:

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

3. **Snapshot perf check** — re-time captured snapshots
   against the new code:
   ```
   python3 perf_harness.py /tmp/perf_snapshots.jsonl \
       --top 5 --repeats 3
   ```
   Compare against the previous wall numbers in commit
   messages. Flag any wall regression > 25%.

4. **Offline self-play smoke** — quick "does autonomous
   play still terminate" check:
   ```
   python3 agent_game.py --offline --max-actions 200
   ```
   Should finish in <10s with at least a few plays
   completed.

5. **Sidecar audit** — every code file has its sidecar:
   ```
   python3 ../../../tools/sidecar_audit.py
   ```

Snapshot files are throwaway — re-capture periodically
with `agent_game.py --offline --capture FILE` to get fresh
representative samples.

## OPTIMIZE_PYTHON pruning landmarks (2026-04-25 / 26)

- **Loop inversion** in `enumerate_moves`: 35% reduction in
  `enumerate_moves` tottime via `_extractable_index`.
- **Merge-time doomed-third filter**: rejects 2-partial
  merges with no completion candidate in board inventory.
  Lifted into the `_admissible_partial` helper 2026-04-26.
- **State-level doomed-growing filter**: yields nothing
  from any state where an existing growing 2-partial has
  lost all its candidates.
- **Budget cap drop**: `_PROJECTION_MAX_STATES` 200000 →
  5000.

## Focus rule + SPLIT_OUT (2026-04-26)

- **`SplitOut` extract verb** — the missing fifth extraction
  primitive. Extracts the interior of a length-3 run,
  splitting it into two singleton TROUBLE fragments. Fills
  the only gap in the verb vocabulary so every helper card
  is reachable for absorption.
- **Focus rule** — BFS state extends to 5-tuple
  `(helper, trouble, growing, complete, lineage)` where
  `lineage[0]` is the focus. Each step must grow or consume
  the focus. Pruning win + canonical plan ordering.
- Together: the runaway puzzles 226 / 228 (DUP_CYCLE /
  EXCESSIVE_SACRIFICE) dissolved (10 / 11 lines instead of
  exhausting cap=8). Puzzle 227 confirmed genuinely
  unsolvable, proven in ~50ms via natural frontier
  termination at every cap.

Cumulative effect: 4–44× speedups on captured worst-case
projections (pre-focus); 2-3× additional on top of those
post-focus on snapshot top-5; corpus depths preserved or
shortened; full test suite green.

## TODO

- Tag `strategy.claude` and friends PLANNED-LEGACY once the
  abandonment plan is concrete.
- Decide the older DSL pipeline's fate
  (`dsl_planner.py` / `dsl_player.py` /
  `board_classifier.py`) — retire or keep as baseline.
- The Elm port (`games/lynrummy/elm/src/Game/Agent/`) is
  feature-complete on the correctness/perf axis as of
  2026-04-26. Remaining drift is renderer-only:
  `narrate` / `hint` aren't ported, and the
  `solve_state_with_descs` diagnostics callback isn't
  ported. Neither is load-bearing.
