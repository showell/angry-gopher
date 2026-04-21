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
point), and the **two coordinate frames** (board frame
vs. viewport) are directly load-bearing for why this subtree
is shaped the way it is.

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
