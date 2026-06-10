// Drive the whole route and verify the model is sound WITHOUT ever building a
// global-world coordinate system. Continuity is checked by expressing each
// Rider position in segment 1's frame, composing only local segment-to-segment
// transforms (lengths + turn signs) — the same relational facts getNextRiderState uses.
//
// Run: node test/test_model.ts
import { initialRiderState, getNextRiderState, MAX_LEAN, TURN_OMEGA, MAX_TURN_ANGLE, leanFor, APPROACH_INTERSECTION_DIST, routeDistance } from '../rider.ts';
import { gazeAngle, nextRiderGaze, GAZE_SEQUENCE } from '../rider_gaze.ts';
import type { RiderState } from '../rider.ts';
import { initialTruck, nextTruck, courseLength } from '../truck.ts';
import type { TruckState } from '../truck.ts';
import { buildWorld } from '../world.ts';
import type { World } from '../world.ts';
import { CornerCreature } from '../safari_critter.ts';
import { SUN_BEARING, sunHeightPx, SUN_RADIUS_PX } from '../sun.ts';
import { horizonCrestPx } from '../mountain.ts';

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
  return h[s.segment] + s.yaw;
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

// Per-state invariants (moved out of getNextRiderState — these are a TEST concern, not a runtime cost in
// the shipped game). The Rider may sit BEFORE a segment's start (negative along — he crosses into a turn
// at the inner edge, just shy of the begin line); this pins down "how far before is reasonable", plus the
// usual finite and bounded checks.
const QUARTER = Math.PI / 2;
function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error('invariant violated: ' + msg);
}
function assertInvariants(s: RiderState, world: World): void {
  const seg = world.segments[s.segment];
  assert(Number.isFinite(s.along) && Number.isFinite(s.across) && Number.isFinite(s.yaw),
         `finite (${s.along},${s.across},${s.yaw})`);
  assert(Number.isFinite(s.v) && s.v >= -1e-9 && s.v <= 8, `v sane (${s.v})`);
  assert(Math.abs(s.yaw) <= QUARTER + 1e-6, `|yaw| <= 90deg (${s.yaw})`);
  // a turn enters at along = -hw/sin(entryAngle), before the begin line — that's expected
  const entryAngle = seg.entryIxn ? world.intersections[seg.entryIxn].angle : 0;
  const entryFloor = entryAngle > 0 ? -(seg.width / 2) / Math.sin(entryAngle) : 0;
  assert(s.along >= entryFloor - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + 1e-6, `along not past end (${s.along})`);
  assert(Math.abs(s.across) <= seg.width / 2 + 1, `across bounded (${s.across})`);
  // eyes on the road while pointed notably off the lane (mid straighten-out) — no distracted glance
  if (Math.abs(s.yaw) > 6 * Math.PI / 180) assert(s.gazeStep < 0, 'no distracted glance mid-turn (eyes on the road)');
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

  // CONFIG: crocodiles only lurk at RIGHT-turn corners. Their lagoon is authored off the corner's
  // LEFT, which is the OUTER side of a right turn (where the guard rail rides); a crocodile at a left
  // turn would put the lagoon on the inner side, over the road. Any croc at a non-right turn is a bug.
  for (const ixn of Object.values(world.intersections)) {
    if (ixn.creature === CornerCreature.CROCODILE && ixn.sign <= 0) {
      throw new Error(`crocodiles only belong at right turns, but ${ixn.id} (sign ${ixn.sign}) has one`);
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

  // the chased truck, simulated in lockstep with the rider (exactly as main.ts advances it)
  const L = courseLength(world);
  let truck: TruckState = initialTruck();
  let minGap = Infinity, maxGap = truck.pos;   // the truck's lead over the rider, tracked across the drive

  for (let i = 0; i < 8000; i++) {
    const n = nextRiderGaze(getNextRiderState(s, world), world);   // bike, then gaze (the same order as main.ts)
    if (n.segment !== s.segment) crossings++;
    maxAcross = Math.max(maxAcross, Math.abs(n.across));
    maxV = Math.max(maxV, n.v);
    // stuck at the route end?
    if (n.segment === s.segment && n.along === s.along) break;   // stuck (terminus: stopped dead)
    states.push(n);
    s = n;
    const rd = routeDistance(n, world);
    truck = nextTruck(truck, rd, world, L);
    const gap = truck.pos - rd;
    minGap = Math.min(minGap, gap);
    maxGap = Math.max(maxGap, gap);
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

  // 1c) the SUNSET over seg7 (the special segment). seg7 must be the long, sun-ward stretch: at
  // least 1000m (it hosts the mid-segment radio tower), headed roughly toward the sun, with the sun
  // still UP as the Rider turns onto it and dropping PART-BEHIND the western range by the segment's
  // end — it SETS behind the range across the stretch. (With the fast descent the sun can't be
  // part-behind at both ends of the window, so we pin the setting, not a single instant.) The sun
  // height is a pure function of the step, pinning the horizon.ts calibration to the route's timing.
  const seg7Len = world.segments['seg7'].length;
  if (seg7Len < 1000) throw new Error(`seg7 is ${seg7Len}m, under the 1000m it needs for its mid-segment tower`);
  const onSeg7 = states.map((st, i) => (st.segment === 'seg7' ? i : -1)).filter((i) => i >= 0);
  if (!onSeg7.length) throw new Error('the Rider never drove seg7');
  const s7start = onSeg7[0], s7end = onSeg7[onSeg7.length - 1];
  const sunwardDeg = Math.abs(wrap(headings['seg7'] - SUN_BEARING)) * 180 / Math.PI;
  if (sunwardDeg > 20) throw new Error(`seg7 heads ${sunwardDeg.toFixed(0)}deg off the sun (> 20deg) — not a sun-ward approach`);
  const crest = horizonCrestPx(SUN_BEARING);                       // the western range at the sun's bearing
  // the one coupling between sun.ts and mountain.ts: the sun must SET BEHIND the western range, so
  // at the sun's bearing the crest is a real mountain, not open sky (which rolls to only ~30px).
  const MOUNTAIN_CREST_MIN = 40;
  if (crest < MOUNTAIN_CREST_MIN) throw new Error(`sun and west range decoupled: crest at the sun's bearing is only ${crest.toFixed(0)}px (open sky, not a mountain)`);
  const sunCentreOnEntry = sunHeightPx(s7start);
  const sunBottomAtExit = sunHeightPx(s7end) - SUN_RADIUS_PX;
  if (!(sunCentreOnEntry > crest)) {
    throw new Error(`onto seg7 the sun centre (${sunCentreOnEntry.toFixed(0)}px) is already below the crest (${crest.toFixed(0)}px) — not still up`);
  }
  if (!(sunBottomAtExit < crest)) {
    throw new Error(`by seg7's end the sun bottom (${sunBottomAtExit.toFixed(0)}px) is still above the crest (${crest.toFixed(0)}px) — it hasn't set behind`);
  }

  // 1d) the SUNSET over seg10 (the SECOND sun-ward stretch, 800m): its sun-ward angle is LOCKED to
  // its authored value (~32deg off the sun — more toward it than seg7's ~7deg, but still off-axis),
  // with at least PART of the sun still present (its top above the western range) as the Rider turns
  // onto it. A change to the route shifts the angle by a turn-angle step (>=5deg), which the tight
  // tolerance catches.
  const seg10Len = world.segments['seg10'].length;
  if (seg10Len !== 800) throw new Error(`seg10 is ${seg10Len}m, expected 800m`);
  const onSeg10 = states.map((st, i) => (st.segment === 'seg10' ? i : -1)).filter((i) => i >= 0);
  if (!onSeg10.length) throw new Error('the Rider never drove seg10');
  const SEG10_OFF_SUN_DEG = 32;   // the authored seg10 sun-ward angle
  const sun10offDeg = Math.abs(wrap(headings['seg10'] - SUN_BEARING)) * 180 / Math.PI;
  if (Math.abs(sun10offDeg - SEG10_OFF_SUN_DEG) > 2) {
    throw new Error(`seg10 is ${sun10offDeg.toFixed(1)}deg off the sun, expected the locked ~${SEG10_OFF_SUN_DEG}deg (more toward it than seg7's ${sunwardDeg.toFixed(0)}deg)`);
  }
  const sun10TopOnEntry = sunHeightPx(onSeg10[0]) + SUN_RADIUS_PX;
  if (!(sun10TopOnEntry > crest)) {
    throw new Error(`onto seg10 no sun is present: its top (${sun10TopOnEntry.toFixed(0)}px) is below the crest (${crest.toFixed(0)}px)`);
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

  // 6) the truck chase: the truck starts ahead of us and STAYS ahead the whole route. It runs its own
  // schedule (lead lerping from the head start toward ~0), braking for corners and flooring it when it
  // falls behind. The near-miss is the fun, so verify we never catch it (its lead stays > 0 throughout).
  if (minGap <= 0) throw new Error(`caught the truck (min lead ${minGap.toFixed(1)}m) — it should stay ahead the whole route; raise the truck's speed`);

  console.log('PASS');
  console.log(`  segments          : ${world.order.length}`);
  console.log(`  presses to finish : ${states.length - 1}`);
  console.log(`  truck lead range  : ${minGap.toFixed(0)}m .. ${maxGap.toFixed(0)}m (stays ahead — never caught)`);
  console.log(`  segment crossings : ${crossings}`);
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad (largest turn step = ${maxOmega.toFixed(4)})`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (peak speed = ${maxV.toFixed(4)} m/press)`);
  console.log(`  max off-centre    : ${maxAcross.toFixed(3)} m (bulge; road half-width = ${(world.segments[world.order[0]].width / 2).toFixed(1)})`);
  console.log(`  max lean          : ${(maxLean * 180 / Math.PI).toFixed(1)} deg (runtime cap 45; ceiling = MAX_LEAN ${(MAX_LEAN * 180 / Math.PI).toFixed(0)})`);
  console.log(`  max tilt step     : ${(maxTiltStep * 180 / Math.PI).toFixed(2)} deg/press (limit 1.0)`);
  console.log(`  self-intersect    : none (${world.order.length} segments checked pairwise)`);
}

main();
