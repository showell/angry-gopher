# Lyn Rummy

**Status:** `WORKHORSE`. Elm is the autonomous client (deals,
referees, replays). Python is the agent / planner / conformance
side. Go is dumb file storage at `views/lynrummy_elm.go` plus
`views/puzzles.go` — the entire `games/lynrummy/` Go package
was retired 2026-04-28 in LEAN_PASS phase 2.

## Before reading the code

Start with [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. It explains the
event-driven model, the per-actor log story, and how Elm and
Python relate.

## Subsystems

- `elm/` — the human-facing client (Main.Play + Game.* +
  Main.* harness). Served at `/gopher/lynrummy-elm/`.
  Includes the BFS planner port (`src/Game/Agent/`),
  Game.Rules locked-down primitives, the dealer (Game.Dealer),
  and a referee (Game.Referee). Elm is autonomous; the Go
  server is observational at most.
- `python/` — agent tools: BFS planner, hand-aware outer
  loop, verb/primitive translators, autonomous self-play
  harness, DSL conformance runner. `agent_game.py` is the
  driver.
- `puzzles/` — curated puzzle gallery (added 2026-04-23).
  Elm sub-app compiled from `elm/src/Puzzles.elm`,
  embedding `Main.Play` per panel. Served at
  `/gopher/puzzles/`. The Python catalog is generated from
  `conformance/mined_seeds.json` via
  `python/puzzle_catalog.py`.
- `data/` — file-system-backed session data. The counter
  `next-session-id.txt` lives at the root of `data/`;
  per-session directories live under `data/lynrummy-elm/sessions/<id>/`
  with `meta.json` (created_at, label, full-game initial_state
  if applicable), `actions/<seq>.json` (one envelope per
  action), and `annotations/<seq>.json` (puzzle-only). All
  committed.

  Distinguishing **full-game vs puzzle** sessions: full-game
  meta carries an `initial_state` block (board + hands + deck);
  puzzle sessions are tagged `label: "puzzles page-load"`
  with no `initial_state` (the puzzle's state lives in the
  catalog). Action bodies for puzzle plays carry a
  `puzzle_name` field; full-game bodies don't.
- `conformance/scenarios/*.dsl` — cross-language scenario
  contract. Compiled to Elm tests + Python JSON fixtures
  via `cmd/fixturegen`. Single source of truth for Elm ↔
  Python parity.

## Conformance DSL

The DSL under `conformance/scenarios/` is the cross-language
contract. Scenario files compile to two targets via
`cmd/fixturegen`:

- `referee.dsl` — referee ops (Elm only; Go referee retired
  with the package 2026-04-28).
- `tricks.dsl` — hint/trick invariants (Elm + Python; will
  retire as the trick engine retires).
- `planner.dsl`, `planner_corpus.dsl`, `planner_corpus_extras.dsl`,
  `planner_mined.dsl` — `enumerate_moves` + `solve` ops for the
  four-bucket BFS planner. Elm + Python.
- `place_stack.dsl` — `find_open_loc` ops. Elm + Python.
- `click_agent_play.dsl` — agent-click invariants (Elm).
- `replay_walkthroughs.dsl` — replay invariants (Elm).

See `../../cmd/fixturegen/main.go` for the codegen pipeline
and `python/test_dsl_conformance.py` for the Python runner.

## TODO

- Retire the trick engine (`Game.Strategy.Hint` on the Elm
  side, `strategy.py` on the Python side). The BFS planner
  is the replacement; full-game UI swap pending per
  `~/.claude/projects/.../memory/project_hint_solver_split.md`.
- Doc-sweep `views/puzzles.go`'s `puzzlesAnnotateShim` once
  Puzzles.elm migrates to the unified URL space.
