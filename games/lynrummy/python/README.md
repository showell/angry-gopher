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
threaded explicitly. See `bfs_solver.claude` and
`verbs.claude` for the conventions. The discipline is by
convention, not by `frozen=True` types — Elm-readable shape,
Python-idiomatic mechanics.

## Before reading the Python code

Start with [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. The sections on
**each actor owns its own view**, **constraints must be real
not artificial**, **two coordinate frames** (board frame vs.
viewport), and **agents plan then execute** are all directly
load-bearing for why this subtree is shaped the way it is.

## Two strategic layers, one fading

The Python agent has two pieces of strategy code:

- **`bfs_solver.py` — the four-bucket BFS planner**,
  current strategic brain (milestone 2026-04-25). State is
  HELPER / TROUBLE / GROWING / COMPLETE; pure BFS-by-length
  with iterative max-trouble cap. 21/21 corpus solved,
  ~25% faster than beginner.py. See `bfs_solver.claude`.

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
  patterns. Still wired into `auto_player.py` for now;
  abandonment plan is in flight (affects Elm too — its
  `Game.Strategy.*` modules and the conformance hint
  scenarios).

When both engines stall on the same board, that's the
"Steve-level puzzle" sweet spot the hunt drivers harvest.

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

- `bfs_solver.claude` — the four-bucket BFS planner.
  Current strategic brain. **Start here for any
  planner-side work.**
- `verbs.claude` — VERB → PRIMITIVE library; decomposes a
  BFS desc into UI primitives via content-based stack lookup.
- `primitives.claude` — PRIMITIVE → GESTURE library;
  to_wire_shape / apply_locally / send_one. Canonical send
  path; auto_player imports from here.
- `bfs_play.claude` — the replay driver: BFS plan executed
  on the actual board, watchable in the browser.
- `beginner.claude` — the IDDFS predecessor. Kept for now
  as a comparable baseline; same corpus minus 1 stuck.
- `strategy.claude` — the trick engine. PLANNED-LEGACY but
  still wired. Per-trick emitters, primitive ordering
  discipline, plan-then-execute for `merge_hand`.
- `auto_player.claude` — the main loop: fetch state, pick a
  trick / planner suggestion, post primitives, repeat.
- `geometry.claude` — board-frame geometry primitives
  (find_open_loc, find_violation, pinned viewport
  constants).
- `gesture_synth.claude` — synthesizes intra-board
  floater-top-left paths where Python knows both endpoints.
- `client.claude` — thin HTTP wrapper around the Gopher
  endpoints.
- `board_lab_puzzles.py` — canonical puzzle catalog for
  BOARD_LAB. Single source of truth for the JSON Go serves.
- `agent_board_lab.py` — runs the strategy engine against
  every puzzle in the catalog; persists a session per
  puzzle (label `"agent: <title>"`).
- `study.py` — reads captured sessions for a named puzzle
  and prints divergence between human and agent attempts.
- `telemetry.claude` — read-side of the DB's gesture
  capture. Analysis, not gameplay.
- Repo-wide tooling at `../../../tools/sidecar_audit.{claude,py}`
  — drift + coverage check across all sidecars.

### Corpus runners

- `corpus_report.claude` — runs `bfs_solver` against
  `corpus/sessions.txt` and emits a Markdown report.
  Regenerable in ~3-5s.
- `corpus_lab_catalog.claude` — same corpus → BOARD_LAB
  gallery JSON, with the BFS plan attached as
  `agent_solution` per puzzle.
- `run_corpus_v2.claude` — beginner-side counterpart.
- `beginner_corpus.claude` — hand-built fixtures for
  beginner.py before/after testing.

### Hunt drivers

`beginner_hunt.claude`, `complex_hunt.claude`,
`deep_hunt.claude`, `one_card_hunt.claude` — drive
`auto_player` on randomized deals until a stall, then ask
`beginner_plan` if it can rescue. Used to harvest the
random-deal corpus.

### Older DSL pipeline (retirement TBD)

`dsl_planner.claude`, `dsl_player.claude`,
`board_classifier.claude`, `dsl.claude` — peel/park/extend/
dissolve/home verb vocabulary, pre-dates `bfs_solver`. Kept
as a comparable baseline; not load-bearing.

### Legacy puzzle harness (queued for purge)

`puzzles.claude`, `puzzle_harness.claude`, `compare.claude`
— pre-BOARD_LAB Python cluster. See MINI_PROJECTS /
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
  `_extract_pieces` per verb plus purity contracts.
- `test_bfs_enumerate.py` — 6 hand-built snapshot tests
  for `_enumerate_moves` across all five move types.
- `test_verbs.py` — 7 tests across all 5 BFS desc types,
  asserting both primitive shape and post-trick geometry.
- `test_plan_merge_hand.py` — 3 tests for the geometry
  pre-flight planner.
- `test_follow_up_merges.py` — 7 tests for the post-trick
  follow-up scan.
- `test_dsl_conformance.py` — 24 cross-language scenarios
  compiled from the conformance DSL (referee + hint +
  planner).
- `test_gesture_synth.py` — 7 tests for drag-path synthesis.

These are the snapshots the upcoming Elm port will mirror.

## TODO

- Tag `strategy.claude` and friends PLANNED-LEGACY once the
  abandonment plan is concrete.
- Decide the older DSL pipeline's fate
  (`dsl_planner.py` / `dsl_player.py` /
  `board_classifier.py`) — retire or keep as baseline.
- Begin the Elm port — see `bfs_solver.claude` § Port to
  Elm.
