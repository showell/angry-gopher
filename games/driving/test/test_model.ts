// Drive the whole route and verify the model is sound WITHOUT ever building a
// global-world coordinate system. Continuity is checked by expressing each
// Rider position in segment 1's frame, composing only local segment-to-segment
// transforms (lengths + turn signs) — the same relational facts getNextRiderState uses.
//
// Run: node test/test_model.ts
import { initialRiderState, getNextRiderState, assertInvariants, MAX_LEAN, TURN_OMEGA, MAX_TURN_ANGLE, leanFor } from '../model.ts';
import type { RiderState } from '../model.ts';
import { buildWorld } from '../road_segment.ts';
import type { World } from '../road_segment.ts';

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
    const ix = world.intersections[world.segments[world.order[i]].exitIxn as string];
    h[world.order[i + 1]] = h[world.order[i]] + ix.sign * ix.angle;
  }
  return h;
}
function heading(s: RiderState, h: Record<string, number>): number {
  return h[s.segment] + s.angle;
}

// a point in segment[idx]'s frame, expressed in segment-1's frame (a chosen
// reference, not global): compose only local B->A transforms. Every turn is a
// straighten-out, so the join is always at the INNER edge of the corner.
interface P { a: number; x: number }
function localToRef(idx: number, a: number, x: number, world: World): P {
  let i = idx;
  while (i > 0) {
    const A = world.segments[world.order[i - 1]];   // B was entered from A
    const ix = world.intersections[A.exitIxn as string];
    const sgn = ix.sign, L = A.length, theta = ix.angle, hw = A.width / 2;
    const cos = Math.cos(theta), sin = Math.sin(theta);
    const aA = L + hw * sin + a * cos - x * sgn * sin;
    const xA = sgn * hw * (1 - cos) + a * sgn * sin + x * cos;
    a = aA; x = xA; i--;
  }
  return { a, x };
}
function inRefFrame(s: RiderState, world: World): P {
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

  // CONFIG: every turn must be <= 90deg — the straighten-out geometry (the only turn
  // mechanism) breaks beyond it (the Rider would enter the next segment pointed back).
  for (const id of world.order) {
    const ix = world.segments[id].exitIxn;
    const angle = ix ? world.intersections[ix].angle : 0;
    if (angle > MAX_TURN_ANGLE + 1e-9) {
      throw new Error(`turn on ${id} is ${(angle * 180 / Math.PI).toFixed(0)}deg, over the ${(MAX_TURN_ANGLE * 180 / Math.PI).toFixed(0)}deg max`);
    }
  }

  let s = initialRiderState(world);
  const states: RiderState[] = [s];
  let crossings = 0, maxAcross = 0, maxV = 0;

  for (let i = 0; i < 8000; i++) {
    const n = getNextRiderState(s, world);
    if (n.segment !== s.segment) crossings++;
    maxAcross = Math.max(maxAcross, Math.abs(n.across));
    maxV = Math.max(maxV, n.v);
    // stuck at the route end?
    if (n.segment === s.segment && n.along === s.along && n.turn === null) break;
    states.push(n);
    s = n;
  }

  // 0) the model's per-segment northHeading matches an independent accumulation
  for (const id of world.order) {
    if (Math.abs(world.segments[id].northHeading - headings[id]) > 1e-9) {
      throw new Error(`northHeading mismatch on ${id}: ${world.segments[id].northHeading} vs ${headings[id]}`);
    }
  }

  // 1) invariants on every state
  for (const st of states) assertInvariants(st, world);

  // 2) heading continuity: no single-press jump bigger than the rotation ceiling. The
  // straighten-out rotates at a fixed TURN_OMEGA (jerk-limited up to it), the same for
  // every turn angle, so that one constant bounds every per-press heading change.
  const maxOmega = TURN_OMEGA;
  let maxHeadingJump = 0, maxLean = 0, maxTiltStep = 0, prevTilt = 0;
  for (let i = 1; i < states.length; i++) {
    const dh = wrap(heading(states[i], headings) - heading(states[i - 1], headings));
    maxHeadingJump = Math.max(maxHeadingJump, Math.abs(dh));
    const tilt = leanFor(dh);   // camera roll, ~ the per-press rotation
    maxLean = Math.max(maxLean, Math.abs(tilt));
    maxTiltStep = Math.max(maxTiltStep, Math.abs(tilt - prevTilt));   // how sharply the bank changes frame-to-frame
    prevTilt = tilt;
  }
  if (maxHeadingJump > maxOmega + 1e-6) throw new Error(`heading jump ${maxHeadingJump} > maxOmega ${maxOmega}`);

  // 2c) lean (camera roll): the per-press rotation is capped at TURN_OMEGA, so the lean it
  // produces never exceeds MAX_LEAN; the sharp turns should actually reach close to it.
  if (maxLean > MAX_LEAN + 1e-6) throw new Error(`max lean ${(maxLean * 180 / Math.PI).toFixed(1)}deg exceeded MAX_LEAN ${(MAX_LEAN * 180 / Math.PI).toFixed(0)}deg`);
  if (maxLean < MAX_LEAN - 3 * Math.PI / 180) throw new Error(`max lean ${(maxLean * 180 / Math.PI).toFixed(1)}deg never approached MAX_LEAN ${(MAX_LEAN * 180 / Math.PI).toFixed(0)}deg`);

  // 2d) no SHARP banking: the tilt may change at most 1deg per press.
  if (maxTiltStep > 1 * Math.PI / 180 + 1e-9) throw new Error(`tilt step ${(maxTiltStep * 180 / Math.PI).toFixed(2)}deg > 1deg`);

  // 2b) the Rider never leaves the road — the core safety property of straighten-out
  const roadHW = world.segments[world.order[0]].width / 2;
  if (maxAcross > roadHW + 1e-6) throw new Error(`rider left the road: |across| ${maxAcross.toFixed(3)} > ${roadHW}`);

  // 3) position continuity (in seg-1 frame): no single-press jump bigger than
  // the fastest press (each press advances by the Rider's speed v).
  let maxPosJump = 0;
  for (let i = 1; i < states.length; i++) {
    const p0 = inRefFrame(states[i - 1], world), p1 = inRefFrame(states[i], world);
    maxPosJump = Math.max(maxPosJump, Math.hypot(p1.a - p0.a, p1.x - p0.x));
  }
  // tolerance is loose (not 1e-6) because inRefFrame composes ~13 rotations, so a
  // true v-sized step picks up ~1e-4 of float noise; a real discontinuity is O(v).
  if (maxPosJump > maxV + 1e-2) throw new Error(`position jump ${maxPosJump.toFixed(4)} > maxV ${maxV.toFixed(4)}`);

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

  console.log('PASS');
  console.log(`  segments          : ${world.order.length}`);
  console.log(`  presses to finish : ${states.length - 1}`);
  console.log(`  segment crossings : ${crossings}`);
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad (largest turn step = ${maxOmega.toFixed(4)})`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (peak speed = ${maxV.toFixed(4)} m/press)`);
  console.log(`  max off-centre    : ${maxAcross.toFixed(3)} m (bulge; road half-width = ${(world.segments[world.order[0]].width / 2).toFixed(1)})`);
  console.log(`  max lean          : ${(maxLean * 180 / Math.PI).toFixed(1)} deg (runtime cap 45; ceiling = MAX_LEAN ${(MAX_LEAN * 180 / Math.PI).toFixed(0)})`);
  console.log(`  max tilt step     : ${(maxTiltStep * 180 / Math.PI).toFixed(2)} deg/press (limit 1.0)`);
  console.log(`  northings (N>N-2) : ${north.map((v) => v.toFixed(0)).join(' ')}`);
}

main();
