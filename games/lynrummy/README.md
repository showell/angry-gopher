# Lyn Rummy

A 2-deck rummy variant for one or more players (the hosted game plays
two-handed), built around a **shared board** where players assemble runs and
sets from their hands. Named for **Lyn** — Steve's aunt (his
mother's sister), who taught the family to play. For the rules, see
[`RULES.md`](./RULES.md); for the big-picture design, [`ARCHITECTURE.md`](./ARCHITECTURE.md).

It's live in production at https://lynrummy.com — a DigitalOcean droplet running
the zig server behind Caddy, where family and friends log in and play (solo or
against the built-in agent: deal, play, hint, agent-play, replay, resume).

## Status: mature and parked (2026-07-25)

The game and puzzles are the oldest of the site's subsystems — they work,
they ship, and as of 2026-07-25 the whole subsystem is **parked** again.
The two big pieces built since the previous park, both live in
production:

- the **beginner tutorial** at `/tutorial` — a public, ungated page in
  plain HTML+JS (`tutorial/` — no Elm, no TS, no solver), gated by
  `ops/test_tutorial`. Content-complete; Steve owns the remaining-gaps
  list (top item: a real photo demonstrating a hand play).
- the **zig solver** at [`zig/`](./zig/README.md), which took over the
  thinking: hints, futility certificates, and the Player Two opponent
  all run it (the original TS engine is mostly retired but still does
  the DSL/geometry work — see "How it's built"). Where to resume is
  written down in that README's **"Parked 2026-07-25 — the resume
  kit"** section: queued work (certificate v2's packing witness,
  puzzle-path certificates), the deeper-repair evidence pile, the
  sets-three-away theorem, and the human-vs-solver calibration record.

**The code is the authority** for how
anything works; this doc and its siblings exist to orient a human reader,
not to drive new engineering (for that, go to the code).

## How it's built

Four parts, covered in [`ARCHITECTURE.md`](./ARCHITECTURE.md) (the tutorial
is a deliberately separate fifth: `tutorial/tutorial.js` re-ports the rules
and board gestures from the Elm spec into ~650 lines of dependency-free JS,
served by its own tiny zig handler):

- **`zig/`** — the **solver**, and since 2026-07 the production brain: one
  converged pipeline (futility prefilters → local repair → the rank-sweep
  oracle) behind both Hint buttons, the futility certificates, and the
  Player Two opponent — compiled to `solver.wasm` for the browser, tested
  natively. Orientation in [`zig/README.md`](./zig/README.md).
- **`ts/`** — the original TypeScript engine, now **mostly retired but still
  working**: its BFS solver and hint logic no longer serve production, but
  its DSL parsers/emitters and the verb→gesture layer
  ([`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md)) are live — they translate
  the zig solver's answers into locations, drag paths, and primitives — and
  its full-game harness still powers self-play conformance and the bake-off
  baseline. The retired solver's design record is
  [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md).
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
the TS `engine.js` bundle, the solver's `solver.wasm`) are built and `@embedFile`d
into the binary; `ops/build_elm` / `ops/build_engine_js` /
`ops/build_lynrummy_wasm` regenerate them. Deploy is the occasional,
deliberate `ops/deploy`. Run `ops/list` for the full script index.

Gates (warm timings; a cold cache roughly doubles them):

- **`ops/check_lynrummy`** (~30s) — the subsystem gate: zig build + a doc-link
  check + the Elm and TS suites. Use this while working here.
- **`ops/check`** (~40s) — the full pre-commit gate (both subsystems).
- **`ops/check_full`** (~2 min) — adds the slow tier: agent self-play across 6
  seeds + perf benches. Dominated by self-play, which is variable — a single
  seed can run anywhere from ~3s to ~30s, so the total wanders a fair bit.

The honest test invariant: conformance drives the *same* codepaths production
does. The hints and Player Two are gated through the real `solver.wasm`
artifact plus the TS lowering (`ops/check_solver`: native zig suites, the
79-puzzle gallery gate, and the cross-language agent wire), and every gallery
puzzle must solve from its own stacks — exactly what the Hint button sees.

## A small glossary

- **Game** vs **puzzle** — a *game* is a full session (turns, opponent, deck,
  scoring); a *puzzle* is a frozen mid-game board handed to a player to execute a
  single trick's worth of moves. The gallery at `/puzzles` holds puzzles.
- **Card** vs **panel** — a *card* is always a playing card; a *panel* is a
  rectangular UI container (e.g. one puzzle in the gallery).

## Where to read next

- [`RULES.md`](./RULES.md) — what the game actually is.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the actors, the DSL-over-the-wire
  idea, frames of reference, and the Elm retrospective.
- [`zig/README.md`](./zig/README.md) — the production solver: the graph
  framing, the converged pipeline, repair, the sim, and the wasm wire.
- [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md) — the gesture-layer doctrine
  (still live under the zig solver) ·
  [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) — the retired TS solver's design
  record.
