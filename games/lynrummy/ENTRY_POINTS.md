# Lyn Rummy — entry points

**Status:** Living document. Last refreshed 2026-05-12.

A catch-up reference — what code is actually running today
and where to find it. Companion to `ARCHITECTURE.md` (which
covers principles and structure).

IMPORTANT: Be general in this document. Point to other
README files (when available) for details.

## Web entry points (Browser apps)

Two Elm `Browser.element` boots, both compiled from
`games/lynrummy/elm/`:

| Source | Output | URL | Role |
|---|---|---|---|
| `src/Game.elm` | `elm.js` | `/gopher/lynrummy-elm/` | Full Lyn Rummy game client |
| `src/Puzzle.elm` | `puzzle.js` | `/gopher/puzzle/` | Single-board puzzle |

## Server-side handlers (Go)

The Go server is dumb URL-keyed file storage for LynRummy
session data. No referee, no replay, no dealer — Elm owns
all of that now.

In `views/`:

- `lynrummy_elm.go`
- `puzzle.go`
- `gamedata.go`
- The broader `views/wiki_*.go` and friends host the rest of
  Angry Gopher. Unrelated to Lyn Rummy.

## CLI / agent tooling

### Mining + fixture generation

See `games/lynrummy/ts/tools/` for agent-side tooling.

### DSL conformance dispatch

See `games/lynrummy/conformance/scenarios/*.dsl`
for our DSL-based tests.


### TypeScript agent (`games/lynrummy/ts/`)

The TS code does "agent" calculations to solve
the Lyn Rummy games and puzzles. It's used by
the agent directly and will soon be in the UI.

See its README.md for more details.

## Conformance test surfaces

The single canonical run point is **`ops/check`** (~20s warm)
from the repo root. It composes:

- `ops/test_ts` — TS typecheck + leaf + engine cross-check + verbs
  + physical_plan + walkthroughs + elmFindPlay + dead-export scan.
- `ops/test_elm` — embed DSLs + standalone Elm typecheck +
  elm make + elm-test + elm-review.
- `ops/test_go` — `go build ./...`.

`ops/check_full` adds `test/test_full_game.ts` (agent self-play
across 6 seeds, ~28s) — the only >20s test in the repo.

Run individual gates (`ops/test_ts` / `ops/test_elm` /
`ops/test_go`) during language-focused iteration. The bare
elm-test / elm-review / tsc / go build commands work too but
skip the cross-language sequencing the scripts encode.

See also: [`elm/README.md`](./elm/README.md) — links here
for the current map of entry points.
