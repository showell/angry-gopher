// solver_check.ts — dev sanity for the routing solver. Not in the browser
// bundle; run it after editing the solver or the cost model:
//
//   delivery/node_modules/.bin/esbuild delivery/solver_check.ts \
//     --bundle --platform=node --format=esm --outfile=/tmp/sc.mjs && node /tmp/sc.mjs
//
// It solves the default order draw and asserts the plan is legal (every truck
// within capacity, fleet count respected, nothing unrouted), then prints each
// truck's route and the cost breakdown vs the coarse floor.

import { buildSubstrate } from "./roadgraph.ts";
import { solve } from "./solver.ts";
import { chooseOrders, ordersByNeighborhood } from "./orders.ts";
import { FLEET } from "./geography.ts";

const sub = buildSubstrate();

let failures = 0;
function check(ok: boolean, msg: string): void {
  console.log(`${ok ? "  ok  " : " FAIL "} ${msg}`);
  if (!ok) failures++;
}

// Solve several seeds so we exercise more than one demand shape.
for (const seed of [49, 7, 1234, 88]) {
  const orders = chooseOrders(seed, FLEET.orders);
  const byNbhd = ordersByNeighborhood(orders);
  const plan = solve(sub, byNbhd);

  const totalOrders = [...byNbhd.values()].reduce((s, v) => s + v.length, 0);
  const planned = plan.routes.reduce((s, r) => s + r.orders, 0);

  console.log(`\n=== seed ${seed}: ${totalOrders} orders over ${byNbhd.size} neighborhoods ===`);
  plan.routes.forEach((r, i) => {
    const tag = `truck ${i + 1}`.padEnd(8);
    const load = `${r.orders}/${FLEET.totesPerTruck}`.padStart(5);
    console.log(`  ${tag} ${load} totes  ${Math.round(r.time).toString().padStart(3)} min   FC → ${r.stops.map((s) => `${s.nbhd}(${s.orders})`).join(" → ")} → FC`);
  });
  console.log(`  total ${Math.round(plan.totalTime)} min  =  travel ${Math.round(plan.travel)} + local ${Math.round(plan.local)} + service ${Math.round(plan.service)}`);

  check(plan.routes.length <= FLEET.trucks, `uses ${plan.routes.length} ≤ ${FLEET.trucks} trucks`);
  check(plan.routes.every((r) => r.orders <= FLEET.totesPerTruck), `every truck within ${FLEET.totesPerTruck}-tote capacity`);
  check(plan.unrouted.length === 0, `nothing unrouted (${plan.unrouted.length} stranded)`);
  check(planned === totalOrders, `delivers all ${totalOrders} orders (planned ${planned})`);
}

console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`}`);
if (failures > 0) throw new Error(`${failures} solver check(s) failed`);
