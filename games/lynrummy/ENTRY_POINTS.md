# Lyn Rummy — entry points and maturity

**Status:** Living document. Last refreshed 2026-05-12.

A catch-up reference — what code is actually running today,
what it does, and how mature each piece is. Companion to
`ARCHITECTURE.md` (which covers principles and structure).

IMPORTANT: Be general in this document. Point to other
README files (when available) for details.

## Web entry points (Browser apps)

Two Elm `Browser.element` boots, both compiled from
`games/lynrummy/elm/`:

| Source | Output | URL | Role |
|---|---|---|---|
| `src/Main.elm` | `elm.js` | `/gopher/lynrummy-elm/` | Full Lyn Rummy game client |
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

### Mining + fixture generation (repo-root `tools/`)

See games/lynrummy/ts/tools for agent-side tooling.

### DSL conformance dispatch

See `games/lynrummy/conformance/scenarios/*.dsl`
for our DSL-based tests.


### TypeScript agent (`games/lynrummy/ts/`)

The TS code does "agent" calculations to solve
the Lyn Rummy games and puzzles. It's used by
the agent directly and will soon be in the UI.

See its README.md for more details.

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

See also: [`elm/README.md`](./elm/README.md) — links here
for the current map of entry points.
