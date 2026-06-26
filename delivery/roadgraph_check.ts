// roadgraph_check.ts — a dev sanity check for the routing substrate. Not part of
// the browser bundle; run it after editing the graph:
//
//   delivery/node_modules/.bin/esbuild delivery/roadgraph_check.ts \
//     --bundle --platform=node --format=esm --outfile=/tmp/rgc.mjs && node /tmp/rgc.mjs
//
// It proves the graph is connected (every neighborhood reachable from the FC),
// prints the FC->neighborhood travel times, and shows the demand split + a
// coarse cost floor for the default order draw.

import { buildSubstrate, NEIGHBORHOOD_SLOWDOWN, SERVICE, SPEED, edges } from "./roadgraph.ts";
import { chooseOrders, demandByNeighborhood } from "./orders.ts";
import { FLEET, NEIGHBORHOODS } from "./geography.ts";

const sub = buildSubstrate();

console.log(`nodes: ${sub.nodes.length}   edges: ${edges().length}`);
console.log(`speed factors:`, SPEED, `  neighborhood slowdown=${NEIGHBORHOOD_SLOWDOWN}x  SERVICE=${SERVICE}\n`);

// 1) Connectivity — nothing should be unreachable from the warehouse.
const unreachable = NEIGHBORHOODS.map((n) => n.name).filter((n) => !Number.isFinite(sub.time("FC", n)));
console.log(unreachable.length ? `UNREACHABLE from FC: ${unreachable.join(", ")}` : "connectivity: OK (all reachable from FC)");

// 2) FC -> each neighborhood, sorted nearest-first (the "painful to get to" axis).
console.log("\nFC -> neighborhood (min, shortest path):");
const byDist = NEIGHBORHOODS.map((n) => ({ name: n.name, t: sub.time("FC", n.name) })).sort((a, b) => a.t - b.t);
for (const { name, t } of byDist) console.log(`  ${name.padEnd(14)} ${Math.round(t).toString().padStart(3)}`);

// 3) Medina is now deliberately awkward (no FC/Bellevue direct edge).
console.log(
  `\nMedina access: FC->Medina=${Math.round(sub.time("FC", "Medina"))}` +
    `  (Kirkland=${Math.round(sub.time("FC", "Kirkland"))}, via 520 U-District=${Math.round(sub.time("FC", "U-District"))})`,
);

// 4) Demand split for the default draw, vs capacity.
const orders = chooseOrders(49, FLEET.orders);
const demand = demandByNeighborhood(orders);
const cap = FLEET.trucks * FLEET.totesPerTruck;
const total = [...demand.values()].reduce((s, v) => s + v, 0);
console.log(`\norders=${total}  capacity=${FLEET.trucks}x${FLEET.totesPerTruck}=${cap}`);
const over = [...demand.entries()].filter(([, d]) => d > FLEET.totesPerTruck);
console.log(`neighborhoods forced to split (demand > ${FLEET.totesPerTruck}): ${over.length ? over.map(([n, d]) => `${n}(${d})`).join(", ") : "none"}`);

// 5) Coarse cost floor: every active neighborhood costs at least its orders'
//    SERVICE plus a round trip from the FC. Just a smell test, not the solver.
let floor = 0;
for (const [n, d] of demand) floor += d * SERVICE + 2 * sub.time("FC", n);
console.log(`coarse cost floor (each nbhd once, solo from FC): ${Math.round(floor)} min over ${demand.size} neighborhoods`);
