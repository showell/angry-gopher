// Drive the whole route and verify the model is sound WITHOUT ever building a
// global-world coordinate system. Continuity is checked by expressing each
// car position in segment 1's frame, composing only local segment-to-segment
// transforms (lengths + turn signs) — the same relational facts advanceCar uses.
//
// Run: node test/test_model.ts
import { buildWorld, initialState, advanceCar, assertInvariants, STEP, DPHI } from '../model.ts';
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

// --- "roads don't loop back": no two non-adjacent centrelines come within a
// lane width of each other (so the road rectangles never overlap/cross). ---
function cross(o: P, p: P, q: P): number {
  return (p.a - o.a) * (q.x - o.x) - (p.x - o.x) * (q.a - o.a);
}
function ptSeg(p: P, a: P, b: P): number {
  const dx = b.a - a.a, dy = b.x - a.x, len2 = dx * dx + dy * dy || 1;
  const t = Math.max(0, Math.min(1, ((p.a - a.a) * dx + (p.x - a.x) * dy) / len2));
  return Math.hypot(p.a - (a.a + t * dx), p.x - (a.x + t * dy));
}
function segDist(p1: P, p2: P, p3: P, p4: P): number {
  const cr = (s: P, e: P) => (cross(p3, p4, s) > 0) !== (cross(p3, p4, e) > 0);
  if (cr(p1, p2) && ((cross(p1, p2, p3) > 0) !== (cross(p1, p2, p4) > 0))) return 0;  // proper crossing
  return Math.min(ptSeg(p1, p3, p4), ptSeg(p2, p3, p4), ptSeg(p3, p1, p2), ptSeg(p4, p1, p2));
}
function minRoadGap(world: World): number {
  const n = world.order.length;
  const ln: Array<[P, P]> = [];
  for (let i = 0; i < n; i++) {
    const L = world.segments[world.order[i]].length;
    ln.push([localToRef(i, 0, 0, world), localToRef(i, L, 0, world)]);
  }
  let min = Infinity;
  for (let i = 0; i < n; i++) {
    for (let j = i + 2; j < n; j++) min = Math.min(min, segDist(ln[i][0], ln[i][1], ln[j][0], ln[j][1]));
  }
  return min;
}

function main(): void {
  const world = buildWorld();
  const last = world.order[world.order.length - 1];
  const headings = segHeadings(world);

  let s = initialState(world);
  const states: CarState[] = [s];
  let handoffs = 0, maxAcross = 0;

  for (let i = 0; i < 5000; i++) {
    const n = advanceCar(s, world);
    if (n.segment !== s.segment) handoffs++;
    maxAcross = Math.max(maxAcross, Math.abs(n.across));
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

  // 3) position continuity (in seg-1 frame): no jump bigger than one cruise step
  let maxPosJump = 0;
  for (let i = 1; i < states.length; i++) {
    const p0 = inRefFrame(states[i - 1], world), p1 = inRefFrame(states[i], world);
    maxPosJump = Math.max(maxPosJump, Math.hypot(p1.a - p0.a, p1.x - p0.x));
  }
  if (maxPosJump > STEP + 1e-6) throw new Error(`position jump ${maxPosJump.toFixed(4)} > STEP`);

  // 4) the route actually completes at the end of the last segment
  if (s.segment !== last) throw new Error(`did not reach ${last}, stuck on ${s.segment}`);
  const endGap = world.segments[last].length - s.along;
  if (Math.abs(endGap) > STEP) throw new Error(`not at the end of ${last} (gap ${endGap})`);

  // 5) roads don't loop back on each other
  const gap = minRoadGap(world);
  const lane = world.segments[world.order[0]].width;
  if (gap < lane) throw new Error(`roads loop/overlap: nearest non-adjacent gap ${gap.toFixed(2)}m < lane ${lane}m`);

  console.log('PASS');
  console.log(`  segments          : ${world.order.length}`);
  console.log(`  presses to finish : ${states.length - 1}`);
  console.log(`  handoffs          : ${handoffs}`);
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad (largest turn step = ${maxOmega.toFixed(4)})`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (cruise step = ${STEP})`);
  console.log(`  max lateral offset: ${maxAcross.toFixed(3)} m (through the turns)`);
  console.log(`  nearest road gap  : ${gap.toFixed(2)} m (>= lane ${lane}m -> no loops)`);
}

main();
