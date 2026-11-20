# Lyn Rummy

A two-deck rummy for one or more players (the hosted game plays two-handed),
built around a **shared board** where players build runs and sets from their
hands. It is named for **Lyn**, Steve's aunt, who taught the family to play.
The rules are in [`RULES.md`](./RULES.md) and the design in
[`ARCHITECTURE.md`](./ARCHITECTURE.md).

It is live at https://lynrummy.com: deal, play, hint, let the agent play,
replay and resume, solo or against the built-in agent.

**The game is mature and parked.** The solver's README,
[`zig/README.md`](./zig/README.md), has a "resume kit" saying where work
would pick up.

## How it's built

Four parts:

- **`zig/`**, the **solver**, does the thinking: one pipeline (futility
  prefilters, then local repair, then the rank-sweep oracle) behind both
  Hint buttons, the futility certificates and the Player Two opponent. It
  compiles to `solver.wasm` for the browser and is tested natively.
- **`ts/`**, the original TypeScript engine, now does the DSL and the
  gestures: its parsers and emitters, and the verb-to-gesture layer
  ([`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md)) that turns the solver's
  answers into locations, drag paths and primitives. Its full-game harness
  runs self-play conformance and the bake-off baseline. Its own solver is
  retired; [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) is that solver's design
  record.
- **`elm/`** is the browser **UI**: the full game (`Game.elm`) and the
  single-board puzzle (`Puzzle.elm`). `ARCHITECTURE.md` has a retrospective
  on choosing Elm.
- **The zig server** is **plain storage**: it holds session files, and the
  clients do the refereeing and reasoning.

**One DSL is spoken everywhere.** One short grammar carries the same shapes
across all three languages: the conformance fixtures, the session files on
disk (`meta`, `actions.dsl`), the new-session wire body, the resume bundle
and agent transcripts. A session header:

```
created_at: 1778500538
label:

board:
  at ( 20,  70): K♠ A♠ 2♠ 3♠
  ...
```

Debugging the game is reading the wire. `ARCHITECTURE.md`, "DSL is the
lingua franca", tours the grammar.

## Building and running

`ops/start` rebuilds everything and serves on `:9001`; open `/game` for a
full game or `/puzzles` for the puzzles. The front-end artifacts
(`elm/elm.js`, `elm/puzzle.js`, the TS `engine.js` bundle and
`solver.wasm`) are embedded in the binary; `ops/build_elm`,
`ops/build_engine_js` and `ops/build_lynrummy_wasm` rebuild them. `ops/list`
lists every script and each gate's rough time.

The gates:

- **`ops/check_lynrummy`**, the game's gate: the common base (build and
  docs), the Elm and TS suites and `ops/check_solver`. Use it while working
  here.
- **`ops/check`**, the pre-commit gate across every app.
- **`ops/check_full`**, which adds agent self-play and the benches.

**Conformance runs the code production runs.** `ops/check_solver` gates the
hints and Player Two through the real `solver.wasm` and the TS lowering: the
native Zig suites, the puzzle gate and the cross-language agent wire. Every
puzzle must solve from its own stacks, as the Hint button sees it.

## Glossary

- **Game** and **puzzle**: a *game* is a full session (turns, opponent,
  deck, scoring); a *puzzle* is a frozen mid-game board to solve in a
  single trick's worth of moves. `/puzzles` holds the puzzles.
- **Card** and **panel**: a *card* is always a playing card; a *panel* is a
  rectangular UI container, such as one puzzle on the puzzles page.
