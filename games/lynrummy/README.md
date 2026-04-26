# Lyn Rummy — Go subsystem

**Status:** `WORKHORSE` for the referee + wire path; the
older trick engine + hint scenarios are retiring.

This subtree holds the Go-side Lyn Rummy code that runs inside
Angry Gopher: domain types (Card, CardStack, Hand, etc.),
dealer, referee, replay, scoring, the primitives-only wire
format, and the server-side rendezvous point for multi-actor
sessions.

## Before reading the Go code

Start with [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. It explains the
event-driven model, the per-actor log story, and where the Go
subsystem fits relative to the Elm UI and Python agent.

## Then — read sidecars

Every `.go` file here has a sibling `.claude` sidecar. The
sidecar carries the module's role + domain knowledge +
maturity label. Open the sidecar first when landing in a file
you haven't touched before.

Ordered by "load-bearing first" (check `LABELS.md` at the
repo root for the generated label index):

- `wire_action.claude` — the wire format as seen from Go.
  Primitives-only. The envelope shape.
- `referee.claude` — move validation: protocol / geometry /
  semantics / inventory. Stateless.
- `replay.claude` — the action-log reducer. Folds events
  forward from a deck seed.
- `dealer.claude` — opening board + deck seed. Coordination
  artifact for multi-player sessions.
- `board_geometry.claude` — bounds, overlap, viewport-pinning
  constants.
- `card_stack.claude`, `card.claude`, `hand.claude`,
  `stack_type.claude`, `score.claude`, `turn_result.claude`
  — domain primitives.
- `events.claude` — what's left of `events.go` after the
  2026-04-20 rip. Currently vestigial.

## Subsystems inside `games/lynrummy/`

- `elm/` — the human-facing client (Main.Play + Game.* +
  Main.* harness). Served at `/gopher/lynrummy-elm/`.
  Includes a partial port of the Python agent
  (`src/Game/Agent/`) — see `elm/README.md` for the
  Python-side drift this port hasn't picked up yet.
- `python/` — agent tools: BFS planner, hand-aware
  outer loop, verb/primitive translators, autonomous
  self-play harness, conformance runner, OPTIMIZE_PYTHON
  diagnostics. The trick engine that this READ-ME used to
  reference is retiring; `agent_game.py` is the current
  driver, not `auto_player.py` (deleted 2026-04-25).
- `board-lab/` — curated puzzle gallery (added 2026-04-23).
  Elm sub-app at `board-lab/elm/` importing Main.Play from
  `elm/src/Main/`; Python puzzle catalog at
  `../python/board_lab_puzzles.py`. Served at
  `/gopher/board-lab/`.

## Tests

- `go test ./games/lynrummy/...` runs the Go suite.
- `referee_conformance_test.go` is **generated** by
  `cmd/fixturegen` from the DSL scenarios under
  `conformance/scenarios/`. Don't hand-edit. See
  `cmd/fixturegen/main.claude` for the pipeline.

## Conformance DSL

The DSL under `conformance/scenarios/` is the cross-language
contract. Three scenario files compile to all three targets
via `cmd/fixturegen`:

- `referee.dsl` — referee ops (Go + Elm tests).
- `tricks.dsl` — hint/trick invariants (Elm + Python; will
  retire as the trick engine retires).
- `planner.dsl` — `enumerate_moves` + `solve` ops for the
  four-bucket BFS planner. 6 enumerate_moves cases are live
  on both Python and Elm. Per-card `narrate_contains` /
  `hint_contains` cases live on Python only — Elm stubs
  them with `Expect.pass` until the renderers port. See
  `elm/README.md` for the current drift list. Futility
  cases (`expect: no_plan`) — UNCERTAIN whether Elm
  exercises these end-to-end after the focus-rule port
  (2026-04-26); needs a dedicated re-check.

See `cmd/fixturegen/main.claude` for the codegen pipeline
and `python/test_dsl_conformance.py` for the Python runner.

## TODO

- Document the `/gopher/lynrummy-elm/*` HTTP surface (lives in
  `views/lynrummy_elm.go`, not in this package).
- Retire the trick engine. The BFS planner port to Elm is
  near-complete as of 2026-04-26 (focus rule + SPLIT_OUT +
  doomed-third filters all live). Remaining drift is
  perf/diagnostic only (loop inversion, narrate/hint,
  diagnostics callback) — none block retirement.
