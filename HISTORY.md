# HISTORY — the client-side toy apps

Two "flipbook + algorithm" toys live in production. The shared pattern: the zig
server `@embedFile`s the front-end and serves a near-empty HTML shell; the client
builds its own `<canvas>` and animates everything — no server logic for the toy
itself, fully deterministic. Each is a small, *finishable* problem with a real
algorithm at its core. They started as twins — both ~4k-LOC pure TypeScript — but
have **diverged in stack**: Delivery is still pure TS; Safari's camera was
re-implemented as a Zig→WASM core feeding a JS blitter.

## Safari Driving — `games/driving/`, served at `/driving`

A first-person 3D screensaver: a self-steering motorcycle ride down a winding road.
Rider-relative coordinates (no global world frame); the algorithmic heart is
**acceleration / turning**. **Originally written in TypeScript**, then ported to a
**Zig→WASM core + a JS blitter** — that became the official `/driving` on
2026-06-30 (the TS bundle is retired; the `.ts` source is kept as the port
reference). Design intent and build lessons live in `games/driving/README.md` —
read that before touching it.

## Seattle Delivery — `delivery/`, served at `/delivery` — PARKED 2026-06-29

A capacitated vehicle-routing (CVRP) sim: schedule 8 trucks to deliver 100 orders a
day across a deliberately not-to-scale, "winking" Seattle (Steve's AmazonFresh
memory). The algorithmic heart is the **Clarke-Wright savings heuristic** plus local
search (2-opt / or-opt / exchange / arc-rebalance), all minimizing one **integer
"pain" cost** (`solver.ts: painOf`) — trig-free, so it's bit-identical across JS
engines. An 8-way construction **race** (pruned to 4-way once arc-rebalance subsumed
the arc-construction axis), keep-min ⇒ never-worse. Regional truck anchoring,
asymmetric caps (west 14 / east 12). Playback animation + `A`-key step-through of the
solve, a progress meter, and a completion blink.

Status: the algorithm was **"declared done" (2026-06-28)** — we couldn't construct a
day whose hardest routes weren't *explicable* (corridor-overload, a sacrificial
"hero" haul, cascading hand-offs) rather than solver bugs. When the stories stopped
surprising us, we stopped.

Where things live (code is truth — ignore stale session notes):
- Code: `delivery/{main,map_view,geography,roadgraph,orders,solver}.ts`.
- Dev harnesses (deterministic; run from the repo **root**; esbuild `--format=esm`
  for the `node:fs` imports): `painsweep.ts` (N=100 scorecard), `painreg.ts` (N=500
  synergy regression → `pain_baseline.json`), `racerank.ts` (subtractive
  race-prune analysis).
- **The human-facing explainer of the whole design is the blog post "The Ghost in
  the Cost Function"** (`/blog/the-ghost-in-the-cost-function`) — the clearest single
  account of the cost model, the race, and what the routes "mean." The toy and the
  essay cross-link each other.

Lessons that outlived the toy (most also have their own memory, or live in the code
or the essay):
- An **integer, trig-free** cost is what buys cross-engine determinism — the real
  fix, not a float-quantize paper-over.
- Score a move at the cost the pipeline will **realize** (post-2-opt `tidiedCost`),
  not the raw insertion.
- **Unshackle a greedy operator → race conservative vs aggressive, keep-min**, rather
  than trusting the aggressive variant alone.
- A good **repair** pass can make a whole **construction** strategy redundant
  (arc-rebalance retired arc-construction). Surprising and backwards from most
  engineering — likely a luxury of a small, finite problem; do **not** export it as a
  law.
- Define the **population** before ranking it (the early "loops" mislabel).

Both apps deploy via `ops/deploy` (which rebuilds + ships the single zig binary).
Reviving either: read this file, then the README / the essay, then the code.
