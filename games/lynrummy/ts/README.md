# LynRummy — TypeScript agent

**Status:** Canonical agent. Solver, verb→primitive pipeline,
spatial-execution layer, full-game player, transcript writer
all live here. The Python solver retired during the migration;
the legacy `Game.Agent.*` Elm BFS port is on life-support
until `TS_ELM_INTEGRATION` lands.
**As of:** 2026-05-04.

## What this is

The complete LynRummy agent in TypeScript:

- **Solver:** [`engine_v2.ts`](src/engine_v2.ts) — A* with
  `half_debt` admissible heuristic, closed-list dedup,
  card-tracker liveness pruning. See
  [`ENGINE_V2.md`](./ENGINE_V2.md) for design notes and
  optimization levers.
- **Verb pipeline:** [`verbs.ts`](src/verbs.ts) — turns one
  solver verb into the primitive sequence a human at the
  kitchen table would emit. Hand-aware (R1), small→large
  swaps (R2), inline pre-flight (R3). See
  [`PHYSICAL_PLAN.md`](./PHYSICAL_PLAN.md) for the gesture-
  layer rules.
- **Loop:** [`physical_plan.ts`](src/physical_plan.ts) — one
  loop over the solver's plan with honest state (sim = real
  board, pendingHand = cards in hand). Multi-card placement
  seeded as a `place_hand` + `merge_hand` chain at a clean
  loc; single-card placements rely on R1 lift.
- **Player:** [`agent_player.ts`](src/agent_player.ts) —
  drives full 2-hand games to deck-low. Permanent invariants
  (board cleanliness, hand arithmetic, card conservation)
  throw on violation per "don't paper over."
- **Transcript:** [`transcript.ts`](src/transcript.ts) —
  writes Elm-replayable session JSON straight to the file
  system. Asserts `findViolation == null` after every
  primitive.

The TS agent uses the file system directly — no HTTP. The Go
server still indexes session ids and accepts wire POSTs from
Elm during live play, but the TS agent bypasses it.

## Agent responsibilities

This subtree owns three end-to-end responsibilities. When Steve
asks for any of these, the work happens here:

- **Generating sample games for review.** Full 2-hand self-play
  + Elm-replayable transcript writing live in this subtree.
  Driver: `npm run bench:end-of-deck -- --write-transcript [seeds...]`.
  Output: `data/lynrummy-elm/sessions/<id>/{meta.json, actions/*.json}`,
  ready for Elm to replay at the URL the Go server exposes. The
  Python subsystem does NOT generate transcripts.
- **Running the conformance suite.** The canonical gate
  `ops/check-conformance` runs `cmd/fixturegen` (Go, DSL →
  fixtures), then `npm test` in this subtree (leaf + engine +
  verbs + physical_plan + replay walkthroughs + agent self-play),
  then Elm `check.sh`. Python's `check.sh` is a separate
  parallel-implementation sanity check, NOT part of the canonical
  gate.
- **Running performance tests.** All perf harnesses live in
  `bench/`: `bench:check-baseline` (timing regression gate),
  `bench:end-of-deck` (full-game perf, 6 seeds), and the
  auxiliary measurement drivers. There are no Python perf
  benches in the active loop.

## Layout

| File | Role |
|---|---|
| `src/rules/card.ts` | Card type, label parser, RANKS / SUITS / RED. |
| `src/classified_card_stack.ts` | CCS data type, kind alphabet, leaf primitives. |
| `src/buckets.ts` | 4-bucket state shape, `classifyBuckets`, fast state-sig. |
| `src/move.ts` | Verb descriptor types + plan-line renderers. |
| `src/enumerator.ts` | Move generator dispatcher + per-move-type helpers. |
| `src/engine_v2.ts` | A* engine + heuristic + min-heap. |
| `src/card_neighbors.ts` | Card-tracker accelerator (NEIGHBORS, buildCardLoc, isLive). |
| `src/hand_play.ts` | Hand-aware outer loop — `findPlay`, `formatHint`. |
| `src/verbs.ts` | Verb→primitive pipeline (hand-aware, R1/R2/R3 inline). |
| `src/physical_plan.ts` | The loop. `physicalPlan(initialBoard, hand, planDescs)`. |
| `src/primitives.ts` | Primitive types + `applyLocally` + shared merge invariant. |
| `src/geometry.ts` | Geometry constants, `findOpenLoc`, `findViolation`, `findCrowding`. |
| `src/agent_player.ts` | Full-game player (2-hand alternating, deck-low termination). |
| `src/transcript.ts` | Elm-replayable JSON session writer. |

## Tests

```
npm test    # leaf + engine conformance + verb fixtures + physical_plan + walkthroughs + agent self-play
```

Individual suites:

| Script | DSL | Counts |
|---|---|---|
| `npm run test:leaf` | `conformance/leaf/*.dsl` | 212+ leaf primitives |
| `npm run test:engine` | `conformance/engine/*.json` | engine plan-line cross-check |
| `npm run test:verbs` | `conformance/scenarios/verb_to_primitives*.dsl` | 102 per-verb primitive sequences |
| `npm run test:physical-plan` | `conformance/scenarios/physical_plan_corpus.dsl` | integration: hand cards + multi-verb + R3 |
| `npm run test:replay-walkthroughs` | `conformance/scenarios/replay_walkthroughs.dsl` | full puzzle walkthroughs |
| `npm run test:agent-player` | (no DSL — plays real games) | 6 seeds × full game |

All DSL runners assert `findViolation == null` after every
emitted primitive — overlap drift fails the moment it
appears, not just at end-of-play.

Node v24's native TS support runs `.ts` files directly — no
compile step, no `tsx`, no dependencies.

## Bench

```
npm run bench:check-baseline   # 81-card timing regression check
npm run bench:gen-baseline     # regenerate gold after deliberate solver change
npm run bench:end-of-deck      # full-game perf, 6 seeds × deck-low
```

Gold timings live in `bench/baseline_board_81_gold.txt` and
`bench/bench_outer_shell_gold.txt`. Mulberry32 PRNG (seedable,
native to JS).

## State signature hashing

The engine uses a packed-int strategy for `Set` keys (JS
Sets compare objects by reference, not value). Each card
encodes as `((value*4)+suit)*2+deck` (max 111). `engine_v2`
adds a position-indexed `fastStateSig` (~1.2× faster than
the legacy stateSig, same dedup decisions). Decision
documented inline in `src/buckets.ts`.

## Design principles carried from the migration

These predate today's architecture but still apply verbatim:

- **Earn knowledge, use earned knowledge.** Probes earn the
  kind; executors consume it.
- **No `side` parameter on functions.** Pairs of named
  functions (`right_X` vs `left_X`), never a `side` arg.
  Side appears only in data layouts.
- **Iteration order is canon.** Plan-line output depends on
  the order moves are yielded. The DSL conformance suite
  pins it.
- **Splice is run/rb-only.** Set parents extend via the
  absorb operation, not splice.

## Pointers

- [`PHYSICAL_PLAN.md`](./PHYSICAL_PLAN.md) — gesture-layer
  doctrine (R1/R2/R3, the loop, the helpers).
- [`ENGINE_V2.md`](./ENGINE_V2.md) — solver design, heuristic
  choice, dedup strategy.
- [`../DOC_AUTHOR_RULES.md`](../DOC_AUTHOR_RULES.md) — read
  before touching docs in this subtree.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — repo-level
  context (events, action logs, frames of reference).
