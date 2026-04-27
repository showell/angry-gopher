# Lyn Rummy — entry points and maturity

**Status:** Living document. Last refreshed 2026-04-27.

A catch-up reference — what code is actually running today,
what it does, and how mature each piece is. Companion to
`ARCHITECTURE.md` (which covers principles and structure) and
`WIRE.md` (which covers the action protocol). This one
answers "where do I start reading" and "is this a SPIKE or
production?".

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

In `views/`:

- `lynrummy_elm.go` — full-game HTTP surface: session
  bootstrap, action log fetch, action persistence,
  complete-turn validation. Writes to `lynrummy_elm_actions`.
- `puzzles.go` — puzzle HTTP surface: catalog at page-load,
  action persistence, annotations. Writes to
  `lynrummy_elm_puzzle_actions` and
  `lynrummy_puzzle_annotations`.
- The broader `views/wiki_*.go` and friends host the rest of
  Angry Gopher. Unrelated to Lyn Rummy.

**Maturity: production for both.**


## CLI / agent tooling

### Mining + fixture generation (`tools/`)

- `mine_puzzles.py` — generates puzzles from agent
  gameplay snapshots; writes to `lynrummy_puzzle_seeds`.
  Stable; produces the corpus the Puzzles gallery serves.
- `export_primitives_fixtures.py` — captures Python verbs +
  geometry_plan output per BFS plan step. Asserts the
  post-step pack-gap invariant at generation time. Produces
  `primitives_fixtures.json` plus an auto-generated Elm test
  module.
- `export_replay_walkthroughs.py` — concatenates per-puzzle
  primitive sequences into `replay_walkthroughs.dsl`. One
  full-walkthrough scenario per puzzle.
- `export_corpus_to_dsl.py` and `export_mined_to_dsl.py` —
  emit BFS plan-text scenarios. The corpus side is older;
  the mined side is the post-mining sibling.

All four exporters are stable, regenerate cleanly, and feed
the same conformance pipeline.

### DSL → test code (Go)

- `cmd/fixturegen` — reads
  `games/lynrummy/conformance/scenarios/*.dsl`, emits Go test
  code, Elm test code, and JSON fixtures. Op set:
  `validate_game_move`, `validate_turn_complete`,
  `build_suggestions`, `hint_invariant`, `enumerate_moves`,
  `solve`, `find_open_loc`, `click_agent_play`,
  `replay_invariant`. Most are mature.

### Python agent core (`games/lynrummy/python/`)

- `bfs.py` — four-bucket BFS solver with focus rule, iterative
  cap, doomed-third filter. Mature (21/21 corpus + 25 mined).
- `verbs.py` — verb-to-primitive layer (geometry-agnostic).
  Restructured 2026-04-27: per-verb pre-flight logic moved
  out into the unified planner.
- `geometry_plan.py` — the unified geometry post-pass. Walks
  primitive sequences, injects pre-flights at points where
  the next primitive would crowd a pre-existing stack. Newly
  introduced in the same restructuring.

Older but stable: `referee.py`, `dealer.py`, `cards.py`,
`strategy.py`, etc.


## Conformance test surfaces

From `games/lynrummy/elm/`:

- `npx elm-test` — 665 tests pass. Mix of unit (e.g.,
  `Game.PlaceStackTest`), integration
  (`Game.AgentPlayThroughTest`, drives click+drain through
  `Play.update`), and DSL conformance.
- `npx elm-review` — installed at the project's root level.
  `NoUnused.*` rules with generated-tests + test-Exports
  exemptions. Currently zero findings.

From `games/lynrummy/python/`:

- `python3 test_dsl_conformance.py` — 113 tests pass.

The single canonical run point for both elm-test and
elm-review is `games/lynrummy/elm/`. The Puzzles gallery
shares this single project (unified 2026-04-27).


## What is NOT current (avoid confusion)

- The Cat TS UI (`angry-cat/`) — legacy Lyn Rummy UI. Still
  in the repo but not in the agent flow.
- The pre-DSL corpus tooling (`corpus_report.py`,
  `corpus_lab_catalog.py`) and the agent-vs-human harness
  (`agent_board_lab.py`, `study.py`) — purged 2026-04-27;
  superseded by the DSL conformance pipeline.
- Old "review mode" in the puzzle UI — ripped 2026-04-26.
