# Building Lyn Rummy

Single-page reference for everything you compile, bundle, or
regenerate to run the live system. Wrapped in `ops/*` scripts
so you don't have to remember flags.

## Dev-loop entry points

- **`ops/start`** — launches the dev server (zig on `:9001`).
  Rebuilds first — it calls `ops/build_elm` (Elm + TS bundles)
  and `zig build`, then relaunches — so a plain `ops/start`
  picks up source edits.
- **`ops/build_elm`** — rebuilds **everything the browser
  needs**, in order:
  1. `ops/build_engine_js` (TS engine → JS bundle)
  2. `Game.elm` → `games/lynrummy/elm/elm.js`
  3. `Puzzle.elm` → `games/lynrummy/elm/puzzle.js`

After editing any `.elm` or any `.ts` file under
`games/lynrummy/ts/`, run `ops/build_elm` and reload the
browser.

## Build artifacts

All three live at `games/lynrummy/elm/` and are served by the zig
server (`zig-server/src/game.zig` and `zig-server/src/puzzles.zig`):

| File | Source | Served at |
|------|--------|-----------|
| `elm.js` | `elm/src/Game.elm` | `/game/elm.js` |
| `puzzle.js` | `elm/src/Puzzle.elm` | `/puzzles/puzzle.js` |
| `engine.js` | `ts/elm_api/engine_entry.ts` (esbuild bundle) | `/game/engine.js` |

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
- `ops/check` — pre-commit gate. Composes `ops/check_zig` +
  `ops/test_ts` + `ops/test_elm` + `ops/test_docs` + `ops/test_css`
  (~35s warm). `ops/check_full` adds the agent self-play suite.

## Other regenerators

These don't run on every build — invoke as needed:

- **Puzzle catalogs.** The single-puzzle UI host
  (`/puzzles`) reads its featured board from
  `conformance/mined_seeds.dsl`; the catalog handling lives in
  `zig-server/src/puzzles.zig`.
- **Bench gold.** `npm run bench:81-single-cards` and
  `npm run bench:6-card-hands` (in `ts/`) each run a perf
  bench that compares against and rewrites its own gold file
  on success. Run after deliberate solver changes; on
  noisy machines, re-run once before treating a failure as
  a real regression.

## Prerequisites

- **Node.js** with npm + `npx` on PATH (used by both Elm
  install and esbuild).
- **zig** (for `ops/start` + `ops/deploy`).
- The Elm compiler comes from `games/lynrummy/elm/node_modules/`
  — run `npm install` there once on a fresh checkout.
