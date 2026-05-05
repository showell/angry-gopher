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

The TS solver is wired into both the live-game Hint button
and the puzzle gallery's "Let agent play" button, so the
strongest available player is always one click away. Full
games can be auto-played end-to-end against a fixed seed for
testing or analysis.

## Agent responsibilities

The TS agent at `ts/` owns three end-to-end jobs:

- **Self-play.** Plays full 2-hand games to deck-low against
  a fixed seed; writes the result as an Elm-replayable JSON
  transcript Steve can step through in the UI. Driver:
  `npm run bench:end-of-deck -- --write-transcript [seeds...]`.
- **Hint generation.** Both surfaces (full game + Puzzles)
  call into `hand_play.ts:findPlay` over Elm ports for the
  Hint button. The Puzzle "Let agent play" button uses the
  same engine to drive a complete puzzle solution.
- **Conformance + perf gates.** `ops/check-conformance` runs
  the TS suite (leaf primitives + engine cross-check + verb
  fixtures + physical-plan integration + replay walkthroughs
  + agent self-play) alongside the Elm suite. Bench gold
  files at `ts/bench/*_gold.txt` lock baseline wall-time
  per scenario.

## Subsystems

- `ts/` — the TypeScript agent (solver, verb pipeline,
  self-play, transcript writer, browser bundle). See
  [`ts/README.md`](./ts/README.md).
- `elm/` — the in-browser UI (full game + Puzzles gallery,
  both embedding `Main.Play`). See
  [`elm/README.md`](./elm/README.md).
- `puzzles/` — the curated puzzle catalog the gallery loads.
  Refresh via `ts/tools/generate_puzzles.ts`.
- `data/` — file-system-backed session storage (full games
  + per-puzzle attempts). All committed.
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
