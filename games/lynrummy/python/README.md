# LynRummy — Python agent subsystem

**Status:** `STILL_EVOLVING` (stub). Expect this to grow.

This subtree is the Python LynRummy agent — a complete player
without a presentation layer. It chooses legal moves with its
own hint logic, validates them against its own referee
equivalent, keeps its own action log, and posts events to the
server for later witness.

## Before reading the Python code

Start with [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. The sections on
**each actor owns its own view**, **constraints must be real
not artificial** (the "Python has no DOM but KNOWS geometry"
point), **two coordinate frames** (board frame vs. viewport),
and **agents plan then execute** are all directly load-bearing
for why this subtree is shaped the way it is.

## The Python agent's stance — plan, then execute

The agent mimics a human's small-scale spatial planning.
Before emitting a trick's primitive sequence, it simulates
the final board and every intermediate state, and pre-plans
geometry corrections upstream — not after. `strategy.py`'s
`_plan_merge_hand` is the canonical implementation of this
discipline: it's called by every trick that emits
`merge_hand`, and if the in-place merge would spill off the
board it emits `move_stack` BEFORE the merge, sized for the
eventual stack.

Concrete examples of what this buys us:
- The replay shows a coherent sequence of human-plausible
  moves, not "ugly in the middle, fine at the end."
- Scope of planning stays shallow (2–3 logical board
  changes, up to 6–7 primitives) — well within what a
  human does in their head. Multi-trick lookahead is a
  different layer (see
  `project_board_consolidation_scanner.md`).
- `_fix_geometry` stays as a last-ditch safety net; it
  should rarely fire, and when it does it's a signal that
  the trick-specific emitter needs a plan upgrade.

## Then — read sidecars

Every `.py` file here has a sibling `.claude` sidecar (tests
excluded — `sidecar_audit` skips `test_*.py` by convention).
Ordered by "load-bearing first":

- `hints.claude` — per-trick emitters + the hint
  orchestration. The strategic brain.
- `auto_player.claude` — the main loop: fetch state, pick a
  trick, post primitives, repeat.
- `geometry.claude` — board-frame geometry primitives
  (find_open_loc, find_violation, pinned viewport
  constants).
- `gesture_synth.claude` — synthesizes intra-board pointer
  paths where Python HONESTLY knows both endpoints.
  Deliberately returns None for hand-origin actions;
  constraints must be real.
- `client.claude` — thin HTTP wrapper around the Gopher
  endpoints.
- `puzzles.claude`, `puzzle_harness.claude`, `compare.claude`,
  `dsl.claude` — puzzle/decomposition tooling (agent-side
  study instruments).
- `test_dsl_conformance.claude` — DSL-driven invariant test
  runner; shares fixtures with Elm via
  `cmd/fixturegen`.
- `telemetry.claude` — the read-side of the DB's gesture
  capture. Analysis, not gameplay.
- Repo-wide tooling at `../../../tools/sidecar_audit.{claude,py}`
  — drift + coverage check across all sidecars.

## The DSL conformance bridge

Python + Elm both exercise the same hint / invariant / build-
suggestions scenarios, defined once in
`games/lynrummy/conformance/scenarios/*.dsl` and compiled by
`cmd/fixturegen` into Python JSON fixtures + Elm Elm-test
files. This is our central cross-language bridge and a key
example of the `BRIDGES.md` principles in action. See
`cmd/fixturegen/main.claude` for the generator pipeline and
`test_dsl_conformance.claude` for the Python consumer.

## TODO (stub-level)

- Document the auto_player's three engagement modes (fully
  autonomous / outbound-only / two-way coordination) per the
  architecture doc's framing.
- Cross-link to the `BRIDGES.md` principle explicitly from
  the conformance-tooling entries.
