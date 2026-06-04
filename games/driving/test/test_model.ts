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

// car position expressed in segment-1's frame (a chosen reference, not global):
// compose only the local B->A transforms (rotate by THETA about the corner).
function inRefFrame(s: CarState, world: World): { a: number; x: number } {
  let i = world.order.indexOf(s.segment);
  let a = s.along, x = s.across;
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

  // 2) heading continuity: no jump bigger than one turn step
  let maxHeadingJump = 0;
  for (let i = 1; i < states.length; i++) {
    const dh = Math.abs(wrap(heading(states[i], headings) - heading(states[i - 1], headings)));
    maxHeadingJump = Math.max(maxHeadingJump, dh);
  }
  if (maxHeadingJump > DPHI + 1e-6) throw new Error(`heading jump ${maxHeadingJump} > DPHI`);

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

  console.log('PASS');
  console.log(`  presses to finish : ${states.length - 1}`);
  console.log(`  handoffs          : ${handoffs}`);
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad (turn step = ${DPHI})`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (cruise step = ${STEP})`);
  console.log(`  max lateral offset: ${maxAcross.toFixed(3)} m (through the turns)`);
}

main();
