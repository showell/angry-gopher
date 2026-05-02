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
  Game.Rules locked-down primitives, the dealer (Game.Dealer),
  and a referee (Game.Referee). The BFS planner port at
  `src/Game/Agent/` is on life-support — TS is the
  going-forward browser BFS. Elm is autonomous; the Go
  server is observational at most.
- `python/` — agent tools: BFS planner (the experimentation
  surface), hand-aware outer loop, verb/primitive translators,
  autonomous self-play harness, DSL conformance runner.
  `agent_game.py` is the driver. See `python/SOLVER.md` for
  solver-specific design.
- `ts/` — TypeScript port of the BFS engine. Sibling to
  `python/`; matches Python plan-line-for-plan-line on the
  148-scenario conformance suite. Will replace the Elm BFS in
  the browser via Elm ports. See `ts/README.md`.
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

  **Reading sessions in DSL form** (Steve's preferred chat
  format): `python3 tools/show_session.py <session_id>`.
  Renders cards as DSL shorthand (e.g. `8C'`, `KS`, `2H`) one
  stack per row. Always use this when discussing a session in
  conversation — never paste raw JSON envelopes.
- `conformance/scenarios/*.dsl` — cross-language scenario
  contract. Compiled to Elm tests + Python JSON fixtures
  via `cmd/fixturegen`. Single source of truth for Elm ↔
  Python parity.

## Conformance DSL

The DSL under `conformance/scenarios/` is the cross-language
contract. Scenario files compile to Elm tests + Python JSON
fixtures via `cmd/fixturegen`. Current files (read
`undo_walkthrough.dsl` first if you're new — it reads like a
game transcript and shows the interaction model concretely):

**Solver / planner:**
- `planner.dsl`, `planner_corpus.dsl`, `planner_corpus_extras.dsl`,
  `planner_mined.dsl` — `enumerate_moves` + `solve` ops.
- `baseline_board_81.dsl` — auto-generated 81-card baseline
  suite (regenerate via `npm run bench:gen-baseline` in `ts/`).
- `hint_game_seed42.dsl` — `hint_for_hand` ops (Python only).

**Referee / rules:**
- `referee.dsl` — referee ops.

**UI / interaction:**
- `place_stack.dsl` — `find_open_loc` ops.
- `click_agent_play.dsl`, `click_arbitration.dsl` — agent-click
  + click-arbitration invariants.
- `drag_invariant.dsl`, `gesture.dsl` — drag state machine,
  floaterTopLeft invariant, pathFrame correctness.
- `board_geometry.dsl` — typed board-geometry validation.
- `wing_oracle.dsl` — wing-detection invariants.
- `replay_walkthroughs.dsl` — replay invariants.
- `undo_walkthrough.dsl` — board-only and hand-card undo
  scenarios (read first as a primer).

See `../../cmd/fixturegen/main.go` for the codegen pipeline
and `python/test_dsl_conformance.py` for the Python runner.

## TODO

- **Browser BFS swap.** Replace the Elm `Game.Agent.*` BFS
  with the TS engine via Elm ports. Possibly expand the TS
  surface to handle hand-to-board interactions too, so the
  Elm/TS split doesn't bisect feature work. Open question.
- Retire the trick engine (`Game.Strategy.Hint` on the Elm
  side, `strategy.py` on the Python side). The BFS planner
  is the replacement; full-game UI swap pending per
  `~/.claude/projects/.../memory/project_hint_solver_split.md`.
- Doc-sweep `views/puzzles.go`'s `puzzlesAnnotateShim` once
  Puzzles.elm migrates to the unified URL space.
