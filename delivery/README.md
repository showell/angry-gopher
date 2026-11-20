# Seattle Delivery

Open [lynrummy.com/delivery](https://lynrummy.com/delivery), press **space**,
and watch eight trucks deliver a hundred grocery orders across a playful,
out-of-scale map of Seattle. It is a screensaver with an algorithm at its
heart: the fun is watching the routes make sense.

- **space** plays the day: the trucks drive their routes, drop totes and park.
- **S** shuffles a new shift. Each shift is numbered, so "S58" names one.
- **A** steps through the solver as it builds the plan. **←/→** scrub either
  animation; **B** or **Esc** returns to the static map.

Hover a neighbourhood to see its name, or a delivered house to highlight its
truck.

## How it works

It is a small **capacitated vehicle-routing (CVRP)** simulator. The canvas,
map and animation are TypeScript. The **solver is Zig**, compiled to
WebAssembly (`solver.wasm`, from `zig/`). The client calls it at each
shuffle and gets the whole plan back as one JSON blob: routes, display
minutes and the replay frames. The zig server embeds both artifacts and
serves a near-empty HTML shell. Everything runs in the browser and is fully
deterministic.

**Zig holds the algorithm and TS the display.** The display is ordinary
canvas work, so it stays in TS. The geography and road graph therefore live
on both sides: the wasm needs them to decide, the TS to draw. The gold's
substrate section holds the two in agreement, and `ops/check_delivery` fails
on any drift.

[Safari Screensaver](../games/driving/README.md) is its sibling: a canvas
the client draws, a Zig core in WebAssembly and a deterministic run. Its hard
part is perception; here it is combinatorial cost.

### The algorithm

Eight trucks carry about a hundred orders, and the west side's trucks carry
more than the east's. The solver (`zig/solver.zig`) builds routes with the
**Clarke-Wright savings heuristic**, then improves them by local search
(2-opt, or-opt, exchange, arc-rebalance). Every move is scored by one
**integer "pain" cost** (`painOf`). Integer arithmetic keeps the cost
bit-identical across JavaScript engines, so the greedy tie-breaks agree in
Node and the browser. A race of construction variants keeps the cheapest,
so the extra search can only help.

What you watch **emerges from that cost**. The one piece of local knowledge
is that Bellevue and Medina go last on their routes, since they sit across
the lake from the fulfillment center. `geography.ts` holds what is hard-coded
(the hints, the road graph, the truck anchors). `TAXONOMY.md` reads each
neighbourhood's role off the resulting routes.

### The code

`main.ts` is the client's entry point and `zig/solver.zig` the solver.
`solver.ts` is the reference implementation: `goldgen.ts` runs it to mint the
gold (`solver_gold.json`, `solver_frames_gold.json`), and the Zig solver
reproduces it bit for bit. The top of `zig/solver.zig` lists what keeps the
two faithful (tie-break order, Map and Set insertion order, snapshot
timing). The dev harnesses (`painsweep.ts`, `painreg.ts`, `racerank.ts` and
the `*_check.ts` files) run from the repo root; each header says how. Change
`zig/solver.zig` and `solver.ts` together.

### Building, running, testing

- **Run it:** `ops/start`, then open `/delivery`. `ops/build_delivery`
  bundles the TS into `app.js` and `ops/build_delivery_wasm` builds
  `solver.wasm` (committed); `zig-server/build.zig` embeds both.
- **The gate:** `ops/check_delivery` typechecks the TS, runs the Zig unit
  tests, re-solves every gold shift and compares it bit for bit, then
  rebuilds `solver.wasm` and drives it over every gold seed. Run it after
  touching `zig/` or the TS solver. `ops/check` leaves this directory out.
- **The gold** regenerates with `goldgen.ts` (its header has the command),
  for an intended change to the solver's behaviour. Read the git diff after.
