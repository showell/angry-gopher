# Building Lyn Rummy

Single-page reference for everything you compile, bundle, or
regenerate to run the live system. Wrapped in `ops/*` scripts
so you don't have to remember flags.

## Dev-loop entry points

- **`ops/start`** — launches the dev server (Go on `:9000`,
  reload-on-write). Reads from already-built artifacts; does
  not rebuild.
- **`ops/build_elm`** — rebuilds **everything the browser
  needs**, in order:
  1. `ops/build_engine_js` (TS engine → JS bundle)
  2. `Main.elm` → `games/lynrummy/elm/elm.js`
  3. `Puzzle.elm` → `games/lynrummy/elm/puzzle.js`

After editing any `.elm` or any `.ts` file under
`games/lynrummy/ts/src/`, run `ops/build_elm` and reload the
browser.

## Build artifacts

All three live at `games/lynrummy/elm/` and are served by
`views/lynrummy_elm.go` and `views/puzzle.go`:

| File | Source | Served at |
|------|--------|-----------|
| `elm.js` | `elm/src/Main.elm` | `/gopher/lynrummy-elm/elm.js` |
| `puzzle.js` | `elm/src/Puzzle.elm` | `/gopher/puzzle/puzzle.js` |
| `engine.js` | `ts/src/engine_entry.ts` (esbuild bundle) | `/gopher/lynrummy-elm/engine.js` |

`engine.js` exposes a single browser global, `LynRummyEngine`,
with two layers of exports:

- **External-caller API (kept name-stable for non-Elm consumers):**
  `solveBoard(board)`, `agentPlay(board)`, `gameHintLines(hand, board)`.
- **Elm-facing wrappers (one-liners that narrow wide return types):**
  `elmSolveBoard`, `elmAgentPlay`, `elmGameHint`. The `elm`-prefixed
  names signal at the call site that the function is consumed by
  Elm — a touch on any of them (or on the underlying functions they
  call) means the `engine.js` bundle needs to be rebuilt before the
  UI is tested.

The full-game Elm client calls into the Elm-facing wrappers via
`port engineRequest` / `port engineResponse`, mediated by a small
JS glue file (`engine_glue.js`) that converts the wire-shape
`{value, suit, origin_deck}` objects to the TS Card record
`{rank, suit, deck}`.

## ops scripts

- `ops/build_engine_js` — esbuild → IIFE bundle. Entry point
  is `games/lynrummy/ts/elm_api/engine_entry.ts`. Output is
  `games/lynrummy/elm/engine.js`. ~75KB. Uses `npx --yes
  esbuild` so no local install is needed; the first run is
  slower while npm caches esbuild.
- `ops/build_elm` — the umbrella. Calls `ops/build_engine_js`
  first, then compiles both Elm entry points.
- `ops/check-conformance` — runs the cross-language DSL
  conformance suite (Elm + TS).

## Other regenerators

These don't run on every build — invoke as needed:

- **Puzzle catalogs.** Two TS tools mine boards for puzzle
  use:
  - `games/lynrummy/ts/tools/generate_puzzles.ts` writes
    `games/lynrummy/puzzles/puzzles.json` (the small a3_*
    catalog used by `planner_puzzles.dsl`).
  - `games/lynrummy/ts/tools/replay_puzzles.ts` emits
    `puzzle_walkthroughs.dsl`.
  The single-puzzle UI host (`/gopher/puzzle/`) reads its
  featured board from `conformance/mined_seeds.dsl`; the
  hard-coded `featuredPuzzleName` lives in `views/puzzle.go`.
- **Bench baselines.** `npm run bench:gen-baseline` (in `ts/`)
  rebuilds the 81-card baseline DSL suite. Don't regenerate
  unless you're explicitly tracking a perf shift.

## Prerequisites

- **Node.js** with npm + `npx` on PATH (used by both Elm
  install and esbuild).
- **Go** (for `ops/start`).
- The Elm compiler comes from `games/lynrummy/elm/node_modules/`
  — run `npm install` there once on a fresh checkout.
