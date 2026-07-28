# Seattle Delivery

**Welcome to the Seattle Delivery toy!** Open [lynrummy.com/delivery](https://lynrummy.com/delivery),
press **space**, and watch eight trucks fan out across a deliberately not-to-scale,
slightly winking map of Seattle to deliver a hundred grocery orders. There's no
score and nothing to win — it's a screensaver with an algorithm at its heart, and
the fun is watching the routes make sense.

A few keys are all you need:

- **space** — play the day; the trucks drive their routes and drop totes, then park.
- **S** — shuffle up a brand-new shift (a fresh random draw of orders). Each shift
  is numbered, so you can say "that one looked weird on S58" and mean it.
- **A** — step *through the solver itself*, one move at a time, to watch the plan
  get built. **←/→** scrub either animation; **B** or **Esc** backs out to the static map.

Hover a neighborhood to see its name; hover a delivered house to highlight its truck.

## Under the hood

This is a small, finished **capacitated vehicle-routing (CVRP)** simulator. The
canvas, map, and animation are client-side **TypeScript**; the **solver is zig**,
compiled to WebAssembly (`solver.wasm`, from `zig/`) and called by the bundle at
each shuffle — it returns the whole plan (routes, display minutes, the solve-replay
frames) as one JSON blob. The zig server just bakes both artifacts into its binary
(`@embedFile`) and serves a near-empty HTML shell; everything still runs in your
browser. No server logic, no user data, fully deterministic.

**Status: parked (again).** The algorithm was "declared done" in June 2026: we
could no longer construct a day whose hardest routes were *bugs* rather than
*explicable structure* (a corridor that's simply overloaded, a sacrificial "hero"
haul, a cascade of hand-offs). When the routes stopped surprising us, we stopped.
In July 2026 the solver was **ported to zig and deployed** (see `zig/` below);
with that done, the toy is parked once more. **The code is the authority** for how
anything works; this file orients a human, and the deeper "why" lives in the essay
below.

**The language boundary is a standing decision, not a way-station (2026-07-28):
zig for the algorithm, TS for the display.** Safari's central aspect is its UI, so
it earned the nearly-full-zig treatment (draw-commands + a JS blitter); Delivery's
center is the solver, and the display code is ordinary canvas work that gains
nothing from a port. Consequence: the geography/road-graph data lives on BOTH
sides — the wasm needs it to decide, the TS to draw. That duplication is accepted:
the gold's substrate section pins the two in agreement (any drift fails
`ops/check_delivery` loudly), and unifying them would just be a single source file
plus deserializers in two languages — not an interesting problem. Don't "fix" it.

**A sibling worth knowing: [Safari Screensaver](../games/driving/README.md).**
Delivery's twin toy *in spirit* — a `<canvas>` the client draws itself, a near-empty
shell the zig server only serves, fully deterministic, the same "flipbook + algorithm"
paradigm. Both are now **Zig→WASM at the core**: Safari's wasm computes the
geometry and emits draw-commands a tiny JS blitter fills, and Delivery's wasm (since
2026-07) runs the whole solver behind the original TS canvas code. Same spirit,
different hard part: here it's **combinatorial cost** (route trucks to minimize an
honest number), there it's **perception** (the cheapest lie the eye will accept as a
sunset road).

### The algorithm, in one breath

Eight trucks, ~100 orders, asymmetric capacities (the west side carries more than
the east). The solver (`solver.ts`) builds routes with the **Clarke-Wright savings
heuristic**, then improves them with local search (2-opt / or-opt / exchange /
arc-rebalance). Every move is scored against a single **integer "pain" cost**
(`painOf`) — and that integer-ness is the one load-bearing trick: the hot path
does **no floating-point trig**, so the cost is bit-identical across JavaScript
engines, and the greedy tie-breaks never flip between Node and the browser. An
8-way construction **race** (pruned to 4-way once arc-rebalance made one axis
redundant) keeps the minimum, so the solver is provably never *worse* for the
extra search.

Almost everything you watch is **emergent from that cost**, not coded as a rule
about Seattle. The one genuine bit of local knowledge we lean on: Bellevue and
Medina get deferred to the end of their routes, because they sit on the
fulfillment center's doorstep across the lake — Bellevue a direct hop, Medina the
SR-520 bridgehead. We're not shy about that; every city has its quirks, and coding
a hint or two is fair game. But the real dynamics live in the **pain cost** — change
it and the whole map reorganizes. `geography.ts` holds what little we hard-code (the
hints, the road graph, the truck anchors) and `TAXONOMY.md` reads the resulting
neighborhood roles straight off the data — revealed, not imposed.

### Where things live

- **Code (the truth):** `main.ts` (canvas/input/animation), `geography.ts` (the
  map + fleet), `orders.ts` (the daily draw), `roadgraph.ts` (the road substrate),
  `solver.ts` (the heart), `map_view.ts` (drawing).
- **`zig/` — the solver, ported and LIVE (2026-07).** `geography/orders/
  roadgraph/solver.zig` reproduce the TS solver **bit-for-bit** — route
  structure AND the replay frames/captions/display minutes — and `wasm.zig`
  ships it as `solver.wasm`, which `main.ts` calls in the browser. Proof:
  `gold_check.zig` (native) and `wasm_check.ts` (drives the real module)
  against `solver_gold.json` + `solver_frames_gold.json` — strict equality,
  trig floats at ULP tolerance. Gate: `ops/check_delivery`. `solver.ts`
  stays as the REFERENCE implementation (goldgen runs it; it's out of the
  browser bundle). Faithfulness subtleties (tie-break order, JS Map/Set
  insertion order, integer-collapsed epsilons, snapshot timing) are
  documented at the top of `zig/solver.zig`.
- **Dev harnesses** (deterministic; run from the repo **root** so they find their
  data; esbuild with `--format=esm` for the `node:` imports): `painsweep.ts` (an
  N=100 scorecard), `painreg.ts` (an N=500 synergy regression → `pain_baseline.json`),
  `racerank.ts` (subtractive race-prune analysis), plus `solver_check.ts` /
  `roadgraph_check.ts`, and `goldgen.ts` (→ `solver_gold.json`, the bit-exact
  20-shift gold corpus the zig solver port must reproduce).
- **`TAXONOMY.md`** — the neighborhood-role affinity matrix.

### Building, running, testing

- **Run it:** `ops/start`, then open `/delivery`. The bundle is built by
  `ops/build_delivery` (esbuild `*.ts` → `app.js`), the solver by
  `ops/build_delivery_wasm` (`zig/wasm.zig` → `solver.wasm`, committed); both
  are `@embedFile`'d via `build.zig`; deploy rides `ops/deploy` (Steve's
  sign-off only).
- **Typecheck:** `npm --prefix delivery run typecheck` (i.e. `tsc --noEmit -p .`).
  Note the conformance gate (`ops/check`) does not typecheck this directory — run
  the typecheck here when you touch the TypeScript.
- **The port gate:** `ops/check_delivery` — TS typecheck + zig unit tests +
  `gold_check` (every gold shift re-solved and compared bit-for-bit). Touch
  anything in `zig/` or the TS solver chain → run it. Regenerate the gold
  (`goldgen.ts`, header has the command) only on an INTENTIONAL solver
  semantics change, then eyeball the git diff.

### The one essay to read

The clearest single account of the cost model, the race, and what the routes
*mean* is the blog post **"The Ghost in the Cost Function"** at
[lynrummy.com/blog/the-ghost-in-the-cost-function](https://lynrummy.com/blog/the-ghost-in-the-cost-function).
For the lineage of this and its sibling toy (the Safari driving screensaver), see
the repo's top-level `HISTORY.md`.

This was built by Steve and Claude together. It's parked, but the code is tidy and
the harnesses still run — if you (or an agent you're working with) want to build on
top of what we wrote, start with this file, then the essay, then the solver:
`zig/solver.zig` is production, `solver.ts` the readable reference the gold is
minted from. Change either only in lockstep with the other, gated by
`ops/check_delivery`.
