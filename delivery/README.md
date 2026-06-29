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

## For the curious (mostly: developers)

GitHub visitors are mostly engineers, so here are the brass tacks. This is a
small, finished **capacitated vehicle-routing (CVRP)** simulator written in pure,
client-side **TypeScript**. The zig server just bakes the esbuilt bundle into its
binary (`@embedFile`) and serves a near-empty HTML shell; everything you see —
the canvas, the map, the animation, the solve — runs in your browser. No server
logic, no user data, fully deterministic.

**Status: parked.** The algorithm was "declared done" in June 2026: we could no
longer construct a day whose hardest routes were *bugs* rather than *explicable
structure* (a corridor that's simply overloaded, a sacrificial "hero" haul, a
cascade of hand-offs). When the routes stopped surprising us, we stopped. **The
code is the authority** for how anything works; this file orients a human, and the
deeper "why" lives in the essay below.

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

The solver knows nothing about Seattle. A handful of small hints in `geography.ts`
(truck anchor regions, the lake, the bridges) give the general algorithm just
enough local knowledge to behave like a real delivery manager would expect.
`TAXONOMY.md` reads the resulting neighborhood "roles" straight off the data —
they're revealed, not imposed.

### Where things live

- **Code (the truth):** `main.ts` (canvas/input/animation), `geography.ts` (the
  map + fleet), `orders.ts` (the daily draw), `roadgraph.ts` (the road substrate),
  `solver.ts` (the heart), `map_view.ts` (drawing).
- **Dev harnesses** (deterministic; run from the repo **root** so they find their
  data; esbuild with `--format=esm` for the `node:` imports): `painsweep.ts` (an
  N=100 scorecard), `painreg.ts` (an N=500 synergy regression → `pain_baseline.json`),
  `racerank.ts` (subtractive race-prune analysis), plus `solver_check.ts` /
  `roadgraph_check.ts`.
- **`TAXONOMY.md`** — the neighborhood-role affinity matrix.

### Building, running, testing

- **Run it:** `ops/start`, then open `/delivery`. The bundle is built by
  `ops/build_delivery` (esbuild `*.ts` → `app.js`) and `@embedFile`'d via
  `build.zig`; deploy rides `ops/deploy` (Steve's sign-off only).
- **Typecheck:** `npm --prefix delivery run typecheck` (i.e. `tsc --noEmit -p .`).
  Note the conformance gate (`ops/check`) does not typecheck this directory — run
  the typecheck here when you touch the TypeScript.

### The one essay to read

The clearest single account of the cost model, the race, and what the routes
*mean* is the blog post **"The Ghost in the Cost Function"** at
[lynrummy.com/blog/the-ghost-in-the-cost-function](https://lynrummy.com/blog/the-ghost-in-the-cost-function).
For the lineage of this and its sibling toy (the Safari driving screensaver), see
the repo's top-level `HISTORY.md`.

This was built by Steve and Claude together. It's parked, but the code is tidy and
the harnesses still run — if you (or an agent you're working with) want to build on
top of what we wrote, start with this file, then the essay, then `solver.ts`.
