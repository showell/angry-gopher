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

Build steps (Elm compile, TS engine bundle, fixturegen) live
in [`BUILDING.md`](./BUILDING.md). The standard rebuild after
editing any `.elm` or `ts/src/*.ts` file is `ops/build_elm`.

## Subsystems

- `ts/` — **The TypeScript agent.** Solver (`engine_v2.ts`),
  verb→primitive pipeline (`verbs.ts`), spatial-execution
  loop (`physical_plan.ts`), full-game player
  (`agent_player.ts`), transcript writer (`transcript.ts`).
  See `ts/README.md` and `ts/PHYSICAL_PLAN.md`.
- `elm/` — the human-facing client (Main.Play + Game.* +
  Main.* harness). Served at `/gopher/lynrummy-elm/`.
  Game.Rules locked-down primitives, the dealer
  (`Game.Dealer`), and a referee (`Game.Rules.Referee`).
  Hint and agent-play surfaces route through the TS engine
  over Elm ports.
- `puzzles/` — curated puzzle gallery. Elm sub-app compiled
  from `elm/src/Puzzles.elm`, embedding `Main.Play` per
  panel. Served at `/gopher/puzzles/`. The committed catalog
  lives at `puzzles/puzzles.json`; refresh by running
  `ts/tools/generate_puzzles.ts` against the current engine.
- `data/` — file-system-backed session data. Two top-level
  namespaces, each with its own id counter at the root of
  `data/`:

  - `next-session-id.txt` + `lynrummy-elm/sessions/<id>/` —
    full-game sessions. `meta.json`, `actions/<seq>.json`
    (one envelope per action), and rare
    `annotations/<seq>.json`.
  - `next-puzzle-session-id.txt` +
    `lynrummy-elm/puzzle-sessions/<id>/` — puzzle gallery
    page-loads. `meta.json` plus per-puzzle subdirs:
    `<puzzle_name>/actions/<seq>.json` and
    `<puzzle_name>/annotations/<seq>.json`. Not resumable
    by design.

  All committed.

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

