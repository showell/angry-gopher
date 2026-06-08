// Drive the whole route and verify the model is sound WITHOUT ever building a
// global-world coordinate system. Continuity is checked by expressing each
// Rider position in segment 1's frame, composing only local segment-to-segment
// transforms (lengths + turn signs) — the same relational facts getNextRiderState uses.
//
// Run: node test/test_model.ts
import { initialRiderState, getNextRiderState, assertInvariants, MAX_LEAN, TURN_OMEGA, MAX_TURN_ANGLE, leanFor, gazeAngle, GAZE_SEQUENCE, APPROACH_INTERSECTION_DIST } from '../model.ts';
import type { RiderState } from '../model.ts';
import { buildWorld } from '../road_segment.ts';
import type { World } from '../road_segment.ts';
import { SUN_BEARING, sunHeightPx, horizonCrestPx, SUN_RADIUS_PX } from '../horizon.ts';

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
    const ix = world.intersections[world.segments[world.order[i]].exitIxn];
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
    const ix = world.intersections[A.exitIxn];
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

// --- "roads don't cross themselves" (the exact invariant) ---
// Express every segment's centreline endpoints in seg-1's frame (composing only local
// segment-to-segment transforms, never a global coordinate system), then check that no two
// NON-ADJACENT segments intersect. Adjacent segments legitimately share an endpoint at their
// joint, so they're skipped. This is EXACT — it replaces an older conservative "each point marches
// north" proxy that rejected perfectly valid routes which merely doubled back for a stretch (e.g. a
// long segment heading south-west does not, in fact, cross anything).
interface RefPt { a: number; x: number }
function crossesItself(world: World): string | null {
  const segs = world.order.map((id, i) => ({
    id, s: localToRef(i, 0, 0, world), e: localToRef(i, world.segments[id].length, 0, world),
  }));
  const turnDir = (o: RefPt, p: RefPt, q: RefPt): number => (p.a - o.a) * (q.x - o.x) - (p.x - o.x) * (q.a - o.a);
  const within = (o: RefPt, p: RefPt, q: RefPt): boolean =>
    Math.min(o.a, p.a) - 1e-9 <= q.a && q.a <= Math.max(o.a, p.a) + 1e-9 &&
    Math.min(o.x, p.x) - 1e-9 <= q.x && q.x <= Math.max(o.x, p.x) + 1e-9;
  const hit = (a: RefPt, b: RefPt, c: RefPt, d: RefPt): boolean => {
    const d1 = turnDir(c, d, a), d2 = turnDir(c, d, b), d3 = turnDir(a, b, c), d4 = turnDir(a, b, d);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
    if (Math.abs(d1) < 1e-9 && within(c, d, a)) return true;
    if (Math.abs(d2) < 1e-9 && within(c, d, b)) return true;
    if (Math.abs(d3) < 1e-9 && within(a, b, c)) return true;
    if (Math.abs(d4) < 1e-9 && within(a, b, d)) return true;
    return false;
  };
  for (let i = 0; i < segs.length; i++) {
    for (let j = i + 2; j < segs.length; j++) {   // skip self + adjacent (they share a joint endpoint)
      if (hit(segs[i].s, segs[i].e, segs[j].s, segs[j].e)) return `${segs[i].id} crosses ${segs[j].id}`;
    }
  }
  return null;
}

function main(): void {
  const world = buildWorld();
  const last = world.order[world.order.length - 1];
  const headings = segHeadings(world);

  // CONFIG: every turn must be <= 90deg — the straighten-out geometry (the only turn
  // mechanism) breaks beyond it (the Rider would enter the next segment pointed back).
  for (const id of world.order) {
    const angle = world.intersections[world.segments[id].exitIxn].angle;   // terminus -> 0, no throw
    if (angle > MAX_TURN_ANGLE + 1e-9) {
      throw new Error(`turn on ${id} is ${(angle * 180 / Math.PI).toFixed(0)}deg, over the ${(MAX_TURN_ANGLE * 180 / Math.PI).toFixed(0)}deg max`);
    }
  }

  // CONFIG: every segment is at least MIN_SEG_LENGTH long — the route relies on this breathing
  // room (full tree/critter sets + room to accelerate and decelerate; no degenerate-short cases).
  const MIN_SEG_LENGTH = 300;
  for (const id of world.order) {
    const len = world.segments[id].length;
    if (len < MIN_SEG_LENGTH) throw new Error(`segment ${id} is ${len}m, under the ${MIN_SEG_LENGTH}m minimum`);
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

  // 1b) the distracted-rider GAZE: it must be back to straight (0) before the braking zone, and
  // it must run the exact configured sequence.
  for (const st of states) {
    const distToEnd = world.segments[st.segment].length - st.along;
    if (distToEnd <= APPROACH_INTERSECTION_DIST && Math.abs(gazeAngle(st)) > 1e-9) {
      throw new Error(`gaze ${(gazeAngle(st) * 180 / Math.PI).toFixed(0)}deg still off-straight within the ${APPROACH_INTERSECTION_DIST}m approach on ${st.segment}`);
    }
  }
  const DEG = Math.PI / 180;
  const gazeVals = states.map((st) => gazeAngle(st));
  const first = gazeVals.findIndex((g) => Math.abs(g) > 1e-9);
  if (first < 0) throw new Error('the distracted-rider glance never fired');
  for (let k = 0; k < GAZE_SEQUENCE.length; k++) {
    if (Math.abs(gazeVals[first + k] - GAZE_SEQUENCE[k] * DEG) > 1e-9) {
      throw new Error(`glance frame ${k}: ${(gazeVals[first + k] / DEG).toFixed(2)}deg != ${GAZE_SEQUENCE[k]}deg`);
    }
  }
  if (Math.abs(gazeVals[first + GAZE_SEQUENCE.length]) > 1e-9) throw new Error('glance did not return to straight after the sequence');

  // 1c) the SUNSET over seg9 (the special segment). seg9 must be the long, sun-ward stretch: at
  // least 1000m (it hosts the mid-segment radio tower), headed roughly toward the sun, with PART of
  // the sun already behind the western range as the Rider turns onto it, and the sun's CENTRE still
  // above that range by the segment's end. The sun height is a pure function of the step (the same
  // step the renderer uses), so this pins the calibration in horizon.ts to the route's timing.
  const seg9Len = world.segments['seg9'].length;
  if (seg9Len < 1000) throw new Error(`seg9 is ${seg9Len}m, under the 1000m it needs for its mid-segment tower`);
  const onSeg9 = states.map((st, i) => (st.segment === 'seg9' ? i : -1)).filter((i) => i >= 0);
  if (!onSeg9.length) throw new Error('the Rider never drove seg9');
  const s9start = onSeg9[0], s9end = onSeg9[onSeg9.length - 1];
  const sunwardDeg = Math.abs(wrap(headings['seg9'] - SUN_BEARING)) * 180 / Math.PI;
  if (sunwardDeg > 20) throw new Error(`seg9 heads ${sunwardDeg.toFixed(0)}deg off the sun (> 20deg) — not a sun-ward approach`);
  const crest = horizonCrestPx(SUN_BEARING);                       // the western range at the sun's bearing
  const sunBottomOnEntry = sunHeightPx(s9start) - SUN_RADIUS_PX;
  const sunCentreAtExit = sunHeightPx(s9end);
  if (!(sunBottomOnEntry < crest)) {
    throw new Error(`onto seg9 the sun bottom (${sunBottomOnEntry.toFixed(0)}px) is not yet behind the crest (${crest.toFixed(0)}px)`);
  }
  if (!(sunCentreAtExit > crest)) {
    throw new Error(`by seg9's end the sun centre (${sunCentreAtExit.toFixed(0)}px) has already dropped below the crest (${crest.toFixed(0)}px)`);
  }

  // 1d) the SUNSET over seg12 (the SECOND sun-ward stretch, 800m): headed toward the sun but LESS
  // directly than seg9, with at least PART of the sun still present (its top above the western
  // range) as the Rider turns onto it. Locks the seg12 angle + the lower sun position there.
  const seg12Len = world.segments['seg12'].length;
  if (seg12Len !== 800) throw new Error(`seg12 is ${seg12Len}m, expected 800m`);
  const onSeg12 = states.map((st, i) => (st.segment === 'seg12' ? i : -1)).filter((i) => i >= 0);
  if (!onSeg12.length) throw new Error('the Rider never drove seg12');
  const sun12offDeg = Math.abs(wrap(headings['seg12'] - SUN_BEARING)) * 180 / Math.PI;
  if (!(sun12offDeg > sunwardDeg && sun12offDeg < 50)) {
    throw new Error(`seg12 heads ${sun12offDeg.toFixed(0)}deg off the sun — expected between seg9's ${sunwardDeg.toFixed(0)}deg and 50deg (toward it, less directly than seg9)`);
  }
  const sun12TopOnEntry = sunHeightPx(onSeg12[0]) + SUN_RADIUS_PX;
  if (!(sun12TopOnEntry > crest)) {
    throw new Error(`onto seg12 no sun is present: its top (${sun12TopOnEntry.toFixed(0)}px) is below the crest (${crest.toFixed(0)}px)`);
  }

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

  // 5) roads don't cross themselves — the exact invariant (no two non-adjacent segments intersect)
  const crossing = crossesItself(world);
  if (crossing) throw new Error(`route self-intersects: ${crossing}`);

  console.log('PASS');
  console.log(`  segments          : ${world.order.length}`);
  console.log(`  presses to finish : ${states.length - 1}`);
  console.log(`  segment crossings : ${crossings}`);
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad (largest turn step = ${maxOmega.toFixed(4)})`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (peak speed = ${maxV.toFixed(4)} m/press)`);
  console.log(`  max off-centre    : ${maxAcross.toFixed(3)} m (bulge; road half-width = ${(world.segments[world.order[0]].width / 2).toFixed(1)})`);
  console.log(`  max lean          : ${(maxLean * 180 / Math.PI).toFixed(1)} deg (runtime cap 45; ceiling = MAX_LEAN ${(MAX_LEAN * 180 / Math.PI).toFixed(0)})`);
  console.log(`  max tilt step     : ${(maxTiltStep * 180 / Math.PI).toFixed(2)} deg/press (limit 1.0)`);
  console.log(`  self-intersect    : none (${world.order.length} segments checked pairwise)`);
}

main();
