# Lyn Rummy

A 2-deck, 2-player rummy variant, built around a **shared board** where players
assemble runs and sets from their hands. Named for **Lyn** — Steve's aunt (his
mother's sister), who taught the family to play. For the rules, see
[`RULES.md`](./RULES.md); for the big-picture design, [`ARCHITECTURE.md`](./ARCHITECTURE.md).

It's live in production at https://lynrummy.com — a DigitalOcean droplet running
the zig server behind Caddy, where family and friends log in and play (solo or
against the built-in agent: deal, play, hint, agent-play, replay, resume).

## Status: mature and parked

Lyn Rummy is the oldest of the site's three subsystems and is **no longer under
active development** — it works, it ships, and attention has moved to Chat/Docs/
Blog. It still deploys with the rest of the single binary. **The code is the
authority** for how anything works; this doc and its siblings exist to orient a
human reader, not to drive new engineering (for that, go to the code).

## How it's built

Three actors, covered in [`ARCHITECTURE.md`](./ARCHITECTURE.md):

- **`ts/`** — the TypeScript **agent**: the BFS solver, the verb→gesture
  pipeline, self-play, and the in-browser bundle that powers the Hint button.
  The design rationale is in [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) (solver) and
  [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md) (how a logical play becomes
  human-looking gestures).
- **`elm/`** — the in-browser **UI**: the full game (`Game.elm`) and the
  single-board puzzle (`Puzzle.elm`). (Elm was the original UI bet; see the
  honest retrospective in [`ARCHITECTURE.md`](./ARCHITECTURE.md).)
- **the zig server** — **dumb storage**: it holds session files and never
  referees or reasons.

The standout architectural idea — and the most fun to work with — is a single
**DSL spoken over the wire**. One short, canonical grammar carries the same
shape across all three runtimes: conformance fixtures, on-disk session files
(`meta`, `actions.dsl`), the new-session wire body, the resume bundle, and agent
transcripts. A sample session header:

```
created_at: 1778500538
label:

board:
  at ( 20,  70): K♠ A♠ 2♠ 3♠
  ...
```

It's what let Steve and Claude debug the game by reading the wire together. Most
parsing happens at test time, and conformance is gated by `ops/check`. The full
grammar tour + examples live in [`ARCHITECTURE.md`](./ARCHITECTURE.md) under "DSL
is the lingua franca".

## Building & running

`ops/start` rebuilds everything and serves on `:9001` (open `/game` for a full
game, `/puzzles` for the gallery). The front-end artifacts (`elm.js`, `puzzle.js`,
the TS `engine.js` bundle) are built and `@embedFile`d into the binary;
`ops/build_elm` / `ops/build_engine_js` regenerate them. Deploy is the occasional,
deliberate `ops/deploy`. Run `ops/list` for the full script index.

Gates (each leaf <20s warm):

- **`ops/check_lynrummy`** (~30s) — the subsystem gate: zig build + a doc-link
  check + the Elm and TS suites. Use this while working here.
- **`ops/check`** (~35s) — the full pre-commit gate (both subsystems).
- **`ops/check_full`** (~75s) — adds the slow tier: agent self-play across 6
  seeds + perf benches.

The honest test invariant: conformance calls the *same* codepath the production
Hint path does (`findLogicalMovesForPlay` in `ts/plan/hand_play.ts`). A tuning
note worth knowing: hint plan-depth (`MAX_PLAN_LENGTH` in `ts/bfs/engine_v2.ts`)
is **5** — depth 4 benches fine but visibly under-plays in real games (see
[`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md)).

## A small glossary

- **Game** vs **puzzle** — a *game* is a full session (turns, opponent, deck,
  scoring); a *puzzle* is a frozen mid-game board handed to a player to execute a
  single trick's worth of moves. The gallery at `/puzzles` holds puzzles.
- **Card** vs **panel** — a *card* is always a playing card; a *panel* is a
  rectangular UI container (e.g. one puzzle in the gallery).

## Where to read next

- [`RULES.md`](./RULES.md) — what the game actually is.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the three actors, the DSL-over-the-wire
  idea, frames of reference, and the Elm retrospective.
- [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) · [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md)
  — solver design and the gesture-layer doctrine, for anyone reading the engine.
