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
import { FLEET, NEIGHBORHOODS, TRUCK_ANCHORS, TRUCK_CAPS } from "./geography.ts";

const sub = buildSubstrate();

let failures = 0;
function check(ok: boolean, msg: string): void {
  console.log(`${ok ? "  ok  " : " FAIL "} ${msg}`);
  if (!ok) failures++;
}

// The anchor list must name real neighborhoods, one slot each within the fleet.
for (const name of TRUCK_ANCHORS) check(NEIGHBORHOODS.some((n) => n.name === name), `anchor "${name}" is a real neighborhood`);
check(TRUCK_ANCHORS.length <= FLEET.trucks, `${TRUCK_ANCHORS.length} anchors ≤ ${FLEET.trucks} truck slots`);

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
    if (r.stops.length === 0) {
      console.log(`  ${tag}  idle — ${TRUCK_ANCHORS[i] ?? "—"} had no run`);
      return;
    }
    const load = `${r.orders}/${TRUCK_CAPS[i]}`.padStart(5);
    console.log(`  ${tag} ${load} totes  ${Math.round(r.time).toString().padStart(3)} min   FC → ${r.stops.map((s) => `${s.nbhd}(${s.orders})`).join(" → ")} → FC`);
  });
  const deployed = plan.routes.filter((r) => r.stops.length > 0).length;
  console.log(`  ${deployed} of ${FLEET.trucks} trucks out  ·  total ${Math.round(plan.totalTime)} min  =  travel ${Math.round(plan.travel)} + local ${Math.round(plan.local)} + service ${Math.round(plan.service)}`);

  check(plan.routes.length === FLEET.trucks, `emits all ${FLEET.trucks} truck slots (${plan.routes.length})`);
  check(plan.routes.every((r, i) => r.orders <= TRUCK_CAPS[i]), `every truck within its slot capacity (14 west / 12 east)`);
  check(plan.unrouted.length === 0, `nothing unrouted (${plan.unrouted.length} stranded)`);
  check(planned === totalOrders, `delivers all ${totalOrders} orders (planned ${planned})`);

  // Regional identity: an anchor that ordered today rides its own truck slot.
  for (let slot = 0; slot < TRUCK_ANCHORS.length; slot++) {
    const name = TRUCK_ANCHORS[slot];
    if (!byNbhd.has(name)) continue; // no orders there today → slot may idle or host a neighbor
    const here = plan.routes[slot].stops.some((s) => s.nbhd === name);
    check(here, `Truck ${slot + 1} owns its anchor ${name}`);
  }
}

console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`}`);
if (failures > 0) throw new Error(`${failures} solver check(s) failed`);
