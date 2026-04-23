# Lyn Rummy — Go subsystem

**Status:** `STILL_EVOLVING` (stub). Expect this to grow.

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
- `python/` — agent tools (strategy + auto_player + board-
  lab harness + conformance runner).
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

## TODO (stub-level)

- Document the `/gopher/lynrummy-elm/*` HTTP surface (lives in
  `views/lynrummy_elm.go`, not in this package).
- Expand the "load-bearing first" reading order once the
  subsystem stabilizes again.
