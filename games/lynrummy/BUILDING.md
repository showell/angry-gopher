# Building Lyn Rummy

Single-page reference for everything you compile, bundle, or
regenerate to run the live system. Wrapped in `ops/*` scripts
so you don't have to remember flags.

## Dev-loop entry points

- **`ops/start`** — launches the dev server (Go on `:9000`,
  reload-on-write). Reads from already-built artifacts; does
  not rebuild.
- **`ops/build_elm`** — rebuilds **everything the puzzles
  page needs**, in order:
  1. `ops/build_engine_js` (TS engine → JS bundle)
  2. `Main.elm` → `games/lynrummy/elm/elm.js`
  3. `Puzzles.elm` → `games/lynrummy/elm/puzzles.js`

After editing any `.elm` or any `.ts` file under
`games/lynrummy/ts/src/`, run `ops/build_elm` and reload the
browser.

## Build artifacts

All three live at `games/lynrummy/elm/` and are served by
`views/lynrummy_elm.go` and `views/puzzles.go`:

| File | Source | Served at |
|------|--------|-----------|
| `elm.js` | `elm/src/Main.elm` | `/gopher/lynrummy-elm/elm.js` |
| `puzzles.js` | `elm/src/Puzzles.elm` | `/gopher/puzzles/puzzles.js` |
| `engine.js` | `ts/src/engine_entry.ts` (esbuild bundle) | `/gopher/puzzles/engine.js` |

`engine.js` exposes a single browser global: `LynRummyEngine`,
with `solveBoard(board)`, `solveStateWithDescs(state)`, and
`findPlay(hand, board)` exported. The Elm puzzles client
calls into it via `port engineRequest` / `port engineResponse`
mediated by a small JS glue file.

## ops scripts

- `ops/build_engine_js` — esbuild → IIFE bundle. Entry point
  is `games/lynrummy/ts/src/engine_entry.ts`. Output is
  `games/lynrummy/elm/engine.js`. ~75KB. Uses `npx --yes
  esbuild` so no local install is needed; the first run is
  slower while npm caches esbuild.
- `ops/build_elm` — the umbrella. Calls `ops/build_engine_js`
  first, then compiles both Elm entry points.
- `ops/check-conformance` — runs the cross-language DSL
  conformance suite (Elm + TS).

## Other regenerators

These don't run on every build — invoke as needed:

- **Conformance fixtures.** `cmd/fixturegen` (Go) compiles
  `conformance/scenarios/*.dsl` to Elm tests +
  `conformance/fixtures/*.json`. Run it after editing any
  `.dsl` scenario.
- **Puzzle catalog.** `games/lynrummy/ts/tools/generate_puzzles.ts`
  re-mines the 5-puzzle gallery into
  `games/lynrummy/puzzles/puzzles.json`. Hard-coded N=5 (no
  CLI args). Re-run after engine changes that should reshape
  the catalog.
- **Bench baselines.** `npm run bench:gen-baseline` (in `ts/`)
  rebuilds the 81-card baseline DSL suite. Don't regenerate
  unless you're explicitly tracking a perf shift.

## Prerequisites

- **Node.js** with npm + `npx` on PATH (used by both Elm
  install and esbuild).
- **Go** (for `ops/start` and `cmd/fixturegen`).
- **Python 3** (for `tools/show_session.py` and the legacy
  parallel solver tests under `python/`).
- The Elm compiler comes from `games/lynrummy/elm/node_modules/`
  — run `npm install` there once on a fresh checkout.
