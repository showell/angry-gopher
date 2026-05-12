# Lyn Rummy — entry points and maturity

**Status:** Living document. Last refreshed 2026-05-10.

A catch-up reference — what code is actually running today,
what it does, and how mature each piece is. Companion to
`ARCHITECTURE.md` (which covers principles and structure).
This one answers "where do I start reading" and "is this a
SPIKE or production?".

## Web entry points (Browser apps)

Two Elm `Browser.element` boots, both compiled from
`games/lynrummy/elm/`:

| Source | Output | URL | Role |
|---|---|---|---|
| `src/Main.elm` | `elm.js` | `/gopher/lynrummy-elm/` | Full Lyn Rummy game client |
| `src/Puzzle.elm` | `puzzle.js` | `/gopher/puzzle/` | Single-board puzzle |

The full-game host embeds `Main.Play`. The puzzle host is
dedicated — it composes `Game.*` primitives directly and
keeps its own replay engine in `src/Puzzle/Replay.elm`.

**Maturity: both are production code paths.** The full game
runs end-to-end (deal → play → complete turns → score). The
puzzle host renders one mid-game position at a time, seeded
from `conformance/mined_seeds.dsl` (featured name hardcoded
in `views/puzzle.go`); supports drag, undo, replay.


## Server-side handlers (Go)

The Go server is dumb URL-keyed file storage for LynRummy
session data. No referee, no replay, no dealer — Elm owns
all of that now.

In `views/`:

- `lynrummy_elm.go` — full-game HTTP surface: allocates
  sequential session ids (the one smart exception), appends
  Elm-posted action lines to
  `games/lynrummy/data/lynrummy-elm/sessions/<id>/{meta,actions.dsl,annotations.jsonl}`.
  Each line of `actions.dsl` is one wire-DSL action.
- `puzzle.go` — puzzle HTTP surface: at page-render time it
  picks the featured puzzle from `conformance/mined_seeds.dsl`,
  allocates a session id from a separate counter, writes the
  session's DSL `meta` file, and bakes a single DSL string
  (`session_id:` + `board:` block) into the Elm flag so the
  client has zero post-load round-trips. Subsequent action
  POSTs land at `/gopher/puzzle/sessions/<id>/actions`,
  appending to `games/lynrummy/data/puzzle/sessions/<id>/actions.dsl`.
  Puzzle and full-game sessions live in distinct on-disk
  namespaces and never share session ids.
- `gamedata.go` — file-storage primitives shared by both
  surfaces.
- The broader `views/wiki_*.go` and friends host the rest of
  Angry Gopher. Unrelated to Lyn Rummy.

**Maturity: production for both.**


## CLI / agent tooling

### Mining + fixture generation (repo-root `tools/`)

- `games/lynrummy/ts/tools/generate_puzzles.ts` — self-play-
  driven puzzle catalog generator. Plays the agent across
  several seeded games and captures the first state past
  ~30 cards on board where engine_v2 returns a length-3 plan.
  Writes `games/lynrummy/puzzles/puzzles.json` (the small a3_*
  catalog used by `planner_puzzles.dsl`). Hard-coded N=5.
- `games/lynrummy/ts/tools/replay_puzzles.ts` — emits
  `puzzle_walkthroughs.dsl` from the puzzle catalog.
- `tools/export_replay_walkthroughs.ts` — concatenates
  per-puzzle primitive sequences from
  `conformance/scenarios/verb_to_primitives_corpus.dsl`
  into `conformance/scenarios/replay_walkthroughs.dsl`. Run
  after re-pinning corpus DSL scenarios.

The 81-card timing gold is generated from TS — see
`games/lynrummy/ts/bench/gen_baseline_board.ts`. The DSL
plan-text scenarios (`planner_corpus*.dsl`,
`planner_mined.dsl`) are committed-and-static.

### DSL conformance dispatch

- `games/lynrummy/conformance/scenarios/*.dsl` is parsed
  natively by both runners at test time (no codegen step).
  Elm: `tests/Game/ConformanceDsl.elm` →
  `tests/Game/ConformanceTests.elm` (the `verify` case-match
  is the live op registry — grep `case sc.op of`). TS:
  `games/lynrummy/ts/test/conformance_dsl.ts` + per-test
  runners.
  **Run via `ops/check-conformance`**, not ad-hoc.

### TypeScript agent (`games/lynrummy/ts/`)

The canonical agent. Modules:

- `src/engine_v2.ts` — A* solver with admissible heuristic,
  closed-list dedup, card-tracker liveness pruning. See
  [`ts/ENGINE_V2.md`](ts/ENGINE_V2.md).
- `src/verbs.ts` — verb→primitive pipeline. Hand-aware
  merging (R1), small→large swaps (R2), inline pre-flight
  (R3). See [`ts/PHYSICAL_PLAN.md`](ts/PHYSICAL_PLAN.md).
- `src/physical_plan.ts` — the loop. `physicalPlan(initialBoard,
  hand, planDescs)` over honest state.
- `src/agent_player.ts` — full 2-hand games to deck-low.
- `src/transcript.ts` — Elm-replayable DSL writer (`meta` +
  `actions.dsl`, file-system, no HTTP).
- `src/validate_session.ts` — re-reads emitted sessions and
  replays via `applyLocally`; the bench script gates on this.
- `src/classified_card_stack.ts`, `src/buckets.ts`,
  `src/move.ts`, `src/enumerator.ts`, `src/hand_play.ts` —
  the BFS infrastructure.

Run tests with `npm test` from `games/lynrummy/ts/` — Node
v24's native TS support runs `.ts` files directly. See
[`ts/README.md`](ts/README.md).

## Conformance test surfaces

From `games/lynrummy/elm/`:

- `npx elm-test` — full Elm suite. Mix of unit tests
  (e.g., `Lib.PlaceStackTest`) and DSL conformance.
- `npx elm-review` — `NoUnused.*` rules with generated-tests
  + test-Exports exemptions.

From `games/lynrummy/ts/`:

- `npm test` — leaf conformance + engine cross-check + verb
  fixtures + physical_plan + walkthroughs + agent self-play.
  The canonical conformance run point.

The single canonical run point for both elm-test and
elm-review is `games/lynrummy/elm/`. The puzzle host shares
this single project.


## What is NOT current (avoid confusion)

- `games/lynrummy/elm/src/Game/Strategy/` — orphan
  production code (the legacy trick engine). Not imported by
  anything `Main.*` / `Puzzle.*` renders; pending deletion.

---

See also: [`elm/README.md`](./elm/README.md) — links here
for the current map of entry points.
