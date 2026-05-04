# Lyn Rummy — entry points and maturity

**Status:** Living document. Last refreshed 2026-05-04.

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
session data. No referee, no replay, no dealer — Elm owns
all of that now.

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

- `tools/mine_puzzles.py` — generates puzzles from agent
  gameplay snapshots; writes
  `games/lynrummy/conformance/mined_seeds.json` directly.
- `tools/export_replay_walkthroughs.ts` — concatenates
  per-puzzle primitive sequences from
  `conformance/scenarios/verb_to_primitives_corpus.dsl`
  into `conformance/scenarios/replay_walkthroughs.dsl`. Run
  after re-pinning corpus DSL scenarios.

The 81-card timing gold is generated from TS — see
`games/lynrummy/ts/bench/gen_baseline_board.ts`. The DSL
plan-text scenarios (`planner_corpus*.dsl`,
`planner_mined.dsl`) are committed-and-static.

### DSL → test code

- `cmd/fixturegen` — reads
  `games/lynrummy/conformance/scenarios/*.dsl`, emits Elm test
  code + JSON fixtures (consumed by Python conformance) +
  ops manifest. Op set is registered in `cmd/fixturegen/main.go`'s
  `opRegistry` (single source of truth). Run
  `git grep '^\s*Name:' cmd/fixturegen/main.go` to enumerate.
  Go target retired 2026-04-28 with the Go domain package.
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
- `src/transcript.ts` — Elm-replayable JSON writer
  (file-system, no HTTP).
- `src/classified_card_stack.ts`, `src/buckets.ts`,
  `src/move.ts`, `src/enumerator.ts`, `src/hand_play.ts` —
  the BFS infrastructure.

Run tests with `npm test` from `games/lynrummy/ts/` — Node
v24's native TS support runs `.ts` files directly. See
[`ts/README.md`](ts/README.md).

## Conformance test surfaces

From `games/lynrummy/elm/`:

- `npx elm-test` — full Elm suite. Mix of unit (e.g.,
  `Game.PlaceStackTest`), integration
  (`Game.AgentPlayThroughTest`, drives click+drain through
  `Play.update`), and DSL conformance.
- `npx elm-review` — `NoUnused.*` rules with generated-tests
  + test-Exports exemptions.

From `games/lynrummy/ts/`:

- `npm test` — leaf conformance + engine cross-check + verb
  fixtures + physical_plan + walkthroughs + agent self-play.
  The canonical conformance run point.

The single canonical run point for both elm-test and
elm-review is `games/lynrummy/elm/`. The Puzzles gallery
shares this single project (unified 2026-04-27).


## What is NOT current (avoid confusion)

- The Cat TS UI (`angry-cat/`) — legacy Lyn Rummy UI.
  Still in the repo but not in the agent flow.
- The Python solver path is a frozen parallel
  implementation; new solver work goes to `games/lynrummy/ts/`.
- The Elm `Game.Agent.*` BFS port + `Game.Strategy.*`
  trick engine are still wired in for the live-game hint
  button; both retire when `TS_ELM_INTEGRATION` lands.

---

See also: [`elm/README.md`](./elm/README.md) — links here
for the current map of entry points.
