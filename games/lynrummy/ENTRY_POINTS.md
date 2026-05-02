# Lyn Rummy — entry points and maturity

**Status:** Living document. Last refreshed 2026-05-01.

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
| `src/Puzzles.elm` | `puzzles.js` | `/gopher/puzzles/` | Puzzle gallery (multi-panel) |

Both share the same `Game.*` and `Main.*` source tree. The
Puzzles gallery is a vertical stack of `Main.Play`
instances, one per mined puzzle, sharing a single page-load
session id.

**Maturity: both are production code paths.** The full game
runs end-to-end (deal → play → complete turns → score). The
puzzle gallery hosts the "Let agent play" + "Hint" buttons
plus per-panel annotations the user uses to exercise the
agent on real puzzles. The Puzzles surface began life as a
SPIKE called BOARD_LAB; that framing has been outgrown by
real use, and the rename to "Puzzles" landed 2026-04-27.


## Server-side handlers (Go)

The Go server is dumb URL-keyed file storage for LynRummy
session data (LEAN_PASS phase 2, 2026-04-28). No referee, no
replay, no dealer — Elm owns all of that now.

In `views/`:

- `lynrummy_elm.go` — full-game HTTP surface: allocates
  sequential session ids (the one smart exception), writes
  Elm-posted bodies verbatim to
  `games/lynrummy/data/lynrummy-elm/sessions/<id>/{meta.json,actions/<seq>.json}`.
- `puzzles.go` — puzzle HTTP surface: catalog at page-load
  (allocates a session id), then puzzle plays write through
  the unified `/sessions/<id>/actions/<seq>` URL space.
  `/gopher/puzzles/annotate` survives as a small back-compat
  shim that writes to `annotations/<seq>.json`.
- `gamedata.go` — file-storage primitives shared by both
  surfaces.
- The broader `views/wiki_*.go` and friends host the rest of
  Angry Gopher. Unrelated to Lyn Rummy.

**Maturity: production for both.**


## CLI / agent tooling

### Mining + fixture generation (repo-root `tools/`)

These live at `/tools/` (repo root), not `games/lynrummy/python/tools/`.

- `mine_puzzles.py` — generates puzzles from agent
  gameplay snapshots; writes
  `games/lynrummy/conformance/mined_seeds.json` directly.
  Stable; produces the corpus the Puzzles gallery serves.
- `export_primitives_fixtures.py` — captures Python verbs +
  geometry_plan output per BFS plan step. Asserts the
  post-step pack-gap invariant at generation time. Produces
  `primitives_fixtures.json` plus an auto-generated Elm test
  module.
- `export_replay_walkthroughs.py` — concatenates per-puzzle
  primitive sequences into `replay_walkthroughs.dsl`. One
  full-walkthrough scenario per puzzle.

The DSL plan-text scenarios (`planner_corpus*.dsl`,
`planner_mined.dsl`) are now committed-and-static — the
exporters that generated them retired 2026-05-02 with the
TS solver migration. Regenerate by hand if a future plan-
shape change requires it.

A separate `games/lynrummy/python/tools/` holds solver-side
utilities (`hint_demo.py` for end-to-end hint output, now
running through `ts_solver`). The 81-card timing gold is
now generated from TS — see
`games/lynrummy/ts/bench/gen_baseline_board.ts`.

All remaining exporters are stable, regenerate cleanly, and
feed the same conformance pipeline.

### DSL → test code

- `cmd/fixturegen` — reads
  `games/lynrummy/conformance/scenarios/*.dsl`, emits Elm test
  code + JSON fixtures (consumed by Python conformance) +
  ops manifest. Op set: `validate_game_move`,
  `validate_turn_complete`, `build_suggestions`,
  `hint_invariant`, `enumerate_moves`, `solve`,
  `find_open_loc`, `click_agent_play`, `replay_invariant`.
  Go target retired 2026-04-28 with the Go domain package.
  **Run via `ops/check-conformance`**, not ad-hoc.

### Python agent core (`games/lynrummy/python/`)

- `bfs.py` — four-bucket BFS solver with focus rule, iterative
  cap, doomed-third filter. The experimentation surface for
  solver work; see [`python/SOLVER.md`](python/SOLVER.md).
- `classified_card_stack.py` — the CCS data type + verb
  library + absorb / splice probes & executors. Most BFS
  hot-path arithmetic.
- `verbs.py` — verb-to-primitive layer (geometry-agnostic).
- `geometry_plan.py` — unified geometry post-pass. Walks
  primitive sequences, injects pre-flights at points where
  the next primitive would crowd a pre-existing stack.

Older but stable: `dealer.py`, `strategy.py`. (PLANNED-LEGACY:
`strategy.py` will retire when the BFS planner takes over the
full-game hint path.)

### TypeScript BFS engine (`games/lynrummy/ts/`)

- `src/classified_card_stack.ts`, `src/buckets.ts`,
  `src/move.ts`, `src/enumerator.ts`, `src/bfs.ts` — the BFS
  engine, sibling to Python's solver. Matches Python plan-line-
  for-plan-line via the DSL conformance contract. Will replace
  the Elm `Game.Agent.*` BFS in the browser via Elm ports.
- Run tests with `npm test` from `games/lynrummy/ts/` — Node
  v24's native TS support runs `.ts` files directly, no compile
  step. See [`ts/README.md`](ts/README.md).


## Conformance test surfaces

From `games/lynrummy/elm/`:

- `npx elm-test` — full Elm suite. Mix of unit (e.g.,
  `Game.PlaceStackTest`), integration
  (`Game.AgentPlayThroughTest`, drives click+drain through
  `Play.update`), and DSL conformance.
- `npx elm-review` — `NoUnused.*` rules with generated-tests
  + test-Exports exemptions.

From `games/lynrummy/python/`:

- `./check.sh` — runs every `test_*.py` in the directory,
  including `test_dsl_conformance.py`.

From `games/lynrummy/ts/`:

- `npm test` — leaf primitive conformance + engine plan-line
  cross-check vs the Python-emitted fixtures.

The single canonical run point for both elm-test and
elm-review is `games/lynrummy/elm/`. The Puzzles gallery
shares this single project (unified 2026-04-27).


## What is NOT current (avoid confusion)

- The Cat TS UI (`angry-cat/`) — legacy Lyn Rummy UI. Still
  in the repo but not in the agent flow.
- The pre-DSL corpus tooling (`corpus_report.py`,
  `corpus_lab_catalog.py`) and the agent-vs-human harness
  (`agent_board_lab.py`, `board_lab_puzzles.py`, `study.py`)
  — purged 2026-04-27; superseded by the DSL conformance
  pipeline.
- Old "review mode" in the puzzle UI — ripped 2026-04-26.

---

See also: [`elm/README.md`](./elm/README.md) — links here for
the current map of entry points.
