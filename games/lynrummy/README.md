# Lyn Rummy

A 2-deck, 2-player rummy variant. The game is built around a
shared board where players assemble runs and sets out of cards
from their hands. For the rules, see
[`RULES.md`](./RULES.md).

## Status

**Internal alpha.** The game is fully playable end-to-end:
deal, play, hint, agent-play, replay, resume. There is no
public release yet. Steve plays solo or against the agent
through the in-browser UI; everything runs locally.

The TS solver is wired into the live-game Hint button so
the strongest available player is always one click away.
Full games can be auto-played end-to-end against a fixed
seed for testing or analysis.

A hard-earned tuning note: hint plan-depth (`HINT_MAX_PLAN_LENGTH`
in `ts/src/hand_play.ts`) is **5**, not 4. Depth 4 looks fine on
benchmarks but visibly under-plays in real games — multi-stack
rebuilds that an engaged human finds in seconds were beyond
reach. Depth 5 is the smallest setting that closes that gap;
the worked examples are seed-42 turns 10 and 11. See
[`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) for the empirical write-up.

## Agent responsibilities

The TS agent at `ts/` owns three end-to-end jobs:

- **Self-play.** Plays full 2-hand games to deck-low against
  a fixed seed; writes the result as an Elm-replayable JSON
  transcript Steve can step through in the UI. Driver:
  `npm run bench:end-of-deck -- --write-transcript [seeds...]`.
- **Hint generation.** The full game's Hint button calls
  into `hand_play.ts:findPlay` over Elm ports.
- **Conformance + perf gates.** `ops/check-conformance` runs
  the TS suite (leaf primitives + engine cross-check + verb
  fixtures + physical-plan integration + replay walkthroughs
  + agent self-play) alongside the Elm suite. Bench gold
  files at `ts/bench/*_gold.txt` lock baseline wall-time
  per scenario.

## Gating & testing

Two gate modes.

**`ops/check-conformance --skip-slow` (~10s).** Default for
day-to-day Elm iteration. Runs Elm standalone + tests +
elm-review + the cross-language integration suites (leaf
primitives, verb fixtures, physical_plan, replay
walkthroughs). Skips the two TS-only suites that are
essentially engine-workouts — `test_engine_conformance.ts`
and `test_agent_player.ts`. Both stress the BFS solver and
run byte-identical when the engine hasn't changed; running
them after an Elm-only edit is wasted budget.

**`ops/check-conformance` no flag (~75s).** Full gate. Run
before committing changes that touch the engine, the agent
loop, or the bucket pipeline — anything that could plausibly
shift solver behavior. Also run as a final pass at the end
of an Elm-only chunk (cheap insurance, lands intact).

Treat any phase >15s as worth flagging — per-phase timing is
printed for exactly this reason. The honest test invariant
is that conformance calls the same codepath the production
hint path does (`findPlanForBuckets` in
`ts/src/hand_play.ts`); divergence in solver options means
the gate isn't load-bearing.

## Subsystems

- `ts/` — the TypeScript agent (solver, verb pipeline,
  self-play, transcript writer, browser bundle). See
  [`ts/README.md`](./ts/README.md).
- `elm/` — the in-browser UI: full game (`Main.elm`) and
  the single-board puzzle (`Puzzle.elm`). See
  [`elm/README.md`](./elm/README.md).
- `conformance/mined_seeds.json` — positioned mid-game
  boards the puzzle host picks from. Generated upstream by
  `ts/tools/generate_puzzles.ts`.
- `data/` — file-system-backed session storage (full games
  in `lynrummy-elm/sessions/`, puzzle attempts in
  `puzzle/sessions/`). All committed.
- `conformance/` — DSL scenarios that pin the cross-language
  contract between Elm and TS. Compiled to fixtures by
  `cmd/fixturegen`.

## Where to read next

- [`RULES.md`](./RULES.md) — what the game actually is.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the system-wide
  design (events, action logs, frames of reference, who
  runs what). Read at every named-project kickoff.
- [`ENTRY_POINTS.md`](./ENTRY_POINTS.md) — concrete entry
  points (Elm boots, server handlers, conformance test
  surfaces).
- [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) and
  [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md) — solver
  design and the gesture-layer doctrine.
- [`BUILDING.md`](./BUILDING.md) — build steps (Elm compile,
  TS engine bundle, fixturegen).
