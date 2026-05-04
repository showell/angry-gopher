# Lyn Rummy

**Status:** `WORKHORSE`. Elm is the autonomous client (deals,
referees, replays). TypeScript is the agent (solver, verb
pipeline, full-game player, transcript writer). Go is dumb
file storage at `views/lynrummy_elm.go` + `views/puzzles.go`.
Python is legacy/utility (dealer + tests + puzzle catalog).

## Before reading the code

Start with [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. It explains the
event-driven model, the per-actor log story, and how Elm and
Python relate.

## Subsystems

- `ts/` — **The TypeScript agent.** Solver (`engine_v2.ts`),
  verb→primitive pipeline (`verbs.ts`), spatial-execution
  loop (`physical_plan.ts`), full-game player
  (`agent_player.ts`), transcript writer (`transcript.ts`).
  See `ts/README.md` and `ts/PHYSICAL_PLAN.md`.
- `elm/` — the human-facing client (Main.Play + Game.* +
  Main.* harness). Served at `/gopher/lynrummy-elm/`.
  Game.Rules locked-down primitives, the dealer (Game.Dealer),
  and a referee (Game.Referee). The legacy BFS port at
  `src/Game/Agent/` and trick engine at `src/Game/Strategy/`
  are still wired in for the live-game hint button; both
  retire when `TS_ELM_INTEGRATION` lands.
- `python/` — Legacy/utility. The Python solver modules
  still pass their tests as a frozen parallel implementation;
  `dealer.py`, `puzzle_catalog.py`, and one-off tools remain
  useful. See `python/README.md`.
- `puzzles/` — curated puzzle gallery. Elm sub-app compiled
  from `elm/src/Puzzles.elm`, embedding `Main.Play` per
  panel. Served at `/gopher/puzzles/`. The catalog is
  generated from `conformance/mined_seeds.json` via
  `python/puzzle_catalog.py`.
- `data/` — file-system-backed session data. The counter
  `next-session-id.txt` lives at the root of `data/`;
  per-session directories live under
  `data/lynrummy-elm/sessions/<id>/` with `meta.json`,
  `actions/<seq>.json` (one envelope per action), and
  `annotations/<seq>.json` (puzzle-only). All committed.

  Distinguishing **full-game vs puzzle** sessions: full-game
  meta carries an `initial_state` block (board + hands +
  deck); puzzle sessions are tagged
  `label: "puzzles page-load"` with no `initial_state`.

  **Reading sessions in DSL form** (Steve's preferred chat
  format): `python3 tools/show_session.py <session_id>`.
  Renders cards as DSL shorthand (e.g. `8C'`, `KS`, `2H`)
  one stack per row. Always use this when discussing a
  session in conversation — never paste raw JSON envelopes.
- `conformance/scenarios/*.dsl` — cross-language scenario
  contract. Compiled to Elm tests + JSON fixtures via
  `cmd/fixturegen`. Single source of truth for Elm ↔ TS
  parity.

## Conformance DSL

The DSL under `conformance/scenarios/` is the cross-language
contract. Scenario files compile to Elm tests + JSON
fixtures via `cmd/fixturegen`. Read `undo_walkthrough.dsl`
first if you're new — it reads like a game transcript and
shows the interaction model concretely.

**Solver / planner:**
- `planner.dsl`, `planner_corpus.dsl`,
  `planner_corpus_extras.dsl`, `planner_mined.dsl` —
  `enumerate_moves` + `solve` ops.
- `baseline_board_81.dsl` — auto-generated 81-card baseline
  suite (regenerate via `npm run bench:gen-baseline` in
  `ts/`).
- `hint_game_seed42.dsl` — `hint_for_hand` ops.

**Verb / gesture pipeline:**
- `verb_to_primitives.dsl`, `verb_to_primitives_corpus.dsl`
  — per-verb primitive expansion. The runner asserts
  `findViolation == null` after every primitive.
- `physical_plan_corpus.dsl` — integration: hand cards +
  multi-verb plans + R1/R3 cases. Same per-step overlap
  guarantee.

**Referee / rules:**
- `referee.dsl` — referee ops.

**UI / interaction:**
- `place_stack.dsl`, `click_agent_play.dsl`,
  `click_arbitration.dsl`, `drag_invariant.dsl`,
  `gesture.dsl`, `board_geometry.dsl`, `wing_oracle.dsl` —
  Elm-side invariants.
- `replay_walkthroughs.dsl` — replay invariants.
- `undo_walkthrough.dsl` — board-only and hand-card undo
  scenarios (read first as a primer).

See `../../cmd/fixturegen/main.go` for the codegen pipeline
and `ts/test/test_engine_conformance.ts` for the TS runner.
Elm + TS cover the contract.

## TODO

- **`TS_ELM_INTEGRATION`** — wire the live-game hint
  button (currently still routed through
  `Game.Strategy.Hint` + `Game.Agent.*` BFS port) into the
  TS engine. Tracked in `claude-steve/MINI_PROJECTS.md`.
  Once landed, both legacy Elm trees retire.
