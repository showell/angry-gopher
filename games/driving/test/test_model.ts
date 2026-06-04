// Drive the whole route and verify the model is sound WITHOUT ever building a
// global-world coordinate system. Continuity is checked by expressing each
// car position in segment 1's frame, composing only local segment-to-segment
// transforms (lengths + turn signs) — the same relational facts advanceCar uses.
//
// Run: node test/test_model.ts
import { buildWorld, initialState, advanceCar, assertInvariants, DPHI } from '../model.ts';
import type { CarState, World } from '../model.ts';

function wrap(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

// reference heading per segment, accumulated from TURN ANGLES (seg-1 = 0). This
// uses only relational facts (turn angle + sign), never a global direction.
function segHeadings(world: World): Record<string, number> {
  const h: Record<string, number> = { [world.order[0]]: 0 };
  for (let i = 0; i < world.order.length - 1; i++) {
    const s = world.segments[world.order[i]];
    h[world.order[i + 1]] = h[world.order[i]] + s.exitSign * s.exitAngle;
  }
  return h;
}
function heading(s: CarState, h: Record<string, number>): number {
  return h[s.segment] + s.angle;
}

// a point in segment[idx]'s frame, expressed in segment-1's frame (a chosen
// reference, not global): compose only local B->A transforms (rotate THETA
// about the corner).
interface P { a: number; x: number }
function localToRef(idx: number, a: number, x: number, world: World): P {
  let i = idx;
  while (i > 0) {
    const A = world.segments[world.order[i - 1]];   // B was entered from A
    const sgn = A.exitSign, L = A.length, theta = A.exitAngle;
    const cos = Math.cos(theta), sin = Math.sin(theta);
    const aA = L + a * cos - x * sgn * sin;
    const xA = a * sgn * sin + x * cos;
    a = aA; x = xA; i--;
  }
  return { a, x };
}
function inRefFrame(s: CarState, world: World): P {
  return localToRef(world.order.indexOf(s.segment), s.along, s.across, world);
}

// --- "roads don't loop back" (constructive invariant) ---
// Global north = seg1's forward direction (the drive starts heading north), so
// the northing of a point is just its `along` coordinate in seg-1's frame. Key
// points are the start, then each segment's far end (its intersection). Every
// point must be NORTH of the point two before it: the even- and odd-indexed
// points each march strictly north, so the path can dip south at most once
// between northward steps and can never curl back to cross itself.
function northings(world: World): number[] {
  const out = [0];  // p0 = the start
  for (let i = 0; i < world.order.length; i++) {
    out.push(localToRef(i, world.segments[world.order[i]].length, 0, world).a);
  }
  return out;
}

function main(): void {
  const world = buildWorld();
  const last = world.order[world.order.length - 1];
  const headings = segHeadings(world);

  let s = initialState(world);
  const states: CarState[] = [s];
  let handoffs = 0, maxAcross = 0, maxV = 0;

  for (let i = 0; i < 8000; i++) {
    const n = advanceCar(s, world);
    if (n.segment !== s.segment) handoffs++;
    maxAcross = Math.max(maxAcross, Math.abs(n.across));
    maxV = Math.max(maxV, n.v);
    // stuck at the route end?
    if (n.segment === s.segment && n.along === s.along && n.turn === null) break;
    states.push(n);
    s = n;
  }

  // 1) invariants on every state
  for (const st of states) assertInvariants(st, world);

  // 2) heading continuity: no jump bigger than the LARGEST single turn step
  // (omega scales with the turn angle, so a 120deg turn steps faster than DPHI).
  let maxAngle = 0;
  for (const id of world.order) maxAngle = Math.max(maxAngle, world.segments[id].exitAngle);
  const maxOmega = DPHI * maxAngle / (Math.PI / 2);
  let maxHeadingJump = 0;
  for (let i = 1; i < states.length; i++) {
    const dh = Math.abs(wrap(heading(states[i], headings) - heading(states[i - 1], headings)));
    maxHeadingJump = Math.max(maxHeadingJump, dh);
  }
  if (maxHeadingJump > maxOmega + 1e-6) throw new Error(`heading jump ${maxHeadingJump} > maxOmega ${maxOmega}`);

  // 3) position continuity (in seg-1 frame): no single-press jump bigger than
  // the fastest press (each press advances by the car's speed v).
  let maxPosJump = 0;
  for (let i = 1; i < states.length; i++) {
    const p0 = inRefFrame(states[i - 1], world), p1 = inRefFrame(states[i], world);
    maxPosJump = Math.max(maxPosJump, Math.hypot(p1.a - p0.a, p1.x - p0.x));
  }
  if (maxPosJump > maxV + 1e-6) throw new Error(`position jump ${maxPosJump.toFixed(4)} > maxV ${maxV.toFixed(4)}`);

  // 4) the route actually completes, coasting to a stop at the end of the last segment
  if (s.segment !== last) throw new Error(`did not reach ${last}, stuck on ${s.segment}`);
  const endGap = world.segments[last].length - s.along;
  if (Math.abs(endGap) > 1e-6) throw new Error(`not at the end of ${last} (gap ${endGap})`);

  // 5) roads don't loop back: each key point is north of the one two before it
  const north = northings(world);
  for (let N = 2; N < north.length; N++) {
    if (!(north[N] > north[N - 2])) {
      throw new Error(`loop risk: point ${N} north ${north[N].toFixed(1)} <= point ${N - 2} north ${north[N - 2].toFixed(1)}`);
    }
  }

  // 6) the long test segment accelerates past ~7 trees before the driver sees
  // the intersection and starts braking.
  const seg3 = world.segments['seg3'];
  let decelAlong = seg3.length;
  for (let i = 1; i < states.length; i++) {
    if (states[i].segment === 'seg3' && states[i - 1].segment === 'seg3'
        && states[i].v < states[i - 1].v - 1e-9) { decelAlong = states[i - 1].along; break; }
  }
  const treesBeforeDecel = seg3.trees.filter((t) => t.side === 'left' && t.along <= decelAlong).length;

  console.log('PASS');
  console.log(`  segments          : ${world.order.length}`);
  console.log(`  presses to finish : ${states.length - 1}`);
  console.log(`  handoffs          : ${handoffs}`);
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad (largest turn step = ${maxOmega.toFixed(4)})`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (peak speed = ${maxV.toFixed(4)} m/press)`);
  console.log(`  max lateral offset: ${maxAcross.toFixed(3)} m (through the turns)`);
  console.log(`  seg3 accel zone   : ${treesBeforeDecel} trees/side before braking (decel onset @ ${decelAlong.toFixed(1)}m)`);
  console.log(`  northings (N>N-2) : ${north.map((v) => v.toFixed(0)).join(' ')}`);
}

main();
