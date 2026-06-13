// Drive the whole route and verify the model is sound WITHOUT ever building a
// global-world coordinate system. Continuity is checked by expressing each
// Rider position in segment 1's frame, composing only local segment-to-segment
// transforms (lengths + turn signs) — the same relational facts getNextRiderState uses.
//
// Run: node test/test_model.ts
import { initialRiderState, getNextRiderState, riderDebug, ForwardReason, MAX_TURN_ANGLE, routeDistance } from '../rider.ts';
import { nextRiderGaze, gazeFocus, PIG_GAZE_SPEED, GAZE_RELEASE_ANGLE, PIG_NOVELTY_COUNT } from '../rider_gaze.ts';
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
  // He crosses into a turn the frame his real position first lands within the new road (|across| < hw).
  // That happens on the inner-edge line, where along = (sgn*across - hw)/sin(entryAngle); for across in
  // [-hw, hw] the entry along spans [-2*hw/sin, 0], the floor being the worst case of crossing at the OUTER
  // road edge. (The old -hw/sin floor assumed a perfectly centred rider at the seam.)
  const entryAngle = seg.entryIxn ? world.intersections[seg.entryIxn].angle : 0;
  const entryFloor = entryAngle > 0 ? -seg.width / Math.sin(entryAngle) : 0;
  assert(s.along >= entryFloor - 1e-6, `along not far before start (${s.along})`);
  assert(s.along <= seg.length + 1e-6, `along not past end (${s.along})`);
  assert(Math.abs(s.across) <= seg.width / 2 + 1, `across bounded (${s.across})`);
  // the distracted gaze is a bounded VIEW angle (it tracks a pig off to the side, never beyond a right angle).
  // The precise pig-gaze behaviour (swivels toward the pig, slows, swings back before the corner) is asserted
  // in the deferred 1b block below, not here on every state.
  assert(Math.abs(s.gazeYaw) <= QUARTER + 1e-3, `gaze bounded (${s.gazeYaw})`);
  assert(s.focus >= 0 && s.focus <= 1, `focus in [0,1] (${s.focus})`);
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
  const shoulderDecel: Record<string, number> = {};   // BASELINE: most-negative accel while the shoulder brake is binding, per segment

  // BASELINE for the intersection-entry rework: per segment, the slowest the rider ever gets and the
  // hardest single-press deceleration he ever takes — each tagged with WHERE (segment-local along +
  // distance-to-segment-end, across) and the seg-1 reference-frame map point (x,y), plus, for the
  // brake, the ForwardReason that forced it. Slowest is charged to the segment the rider is ON; the
  // brake is charged to the APPROACH segment (the one he's on while deciding to slow).
  interface Slowest { v: number; along: number; across: number; x: number; y: number }
  interface Hardest { accel: number; reason: ForwardReason; along: number; across: number; x: number; y: number }
  const slowest: Record<string, Slowest> = {};
  const hardest: Record<string, Hardest> = {};

  // the chased truck, simulated in lockstep with the rider (exactly as main.ts advances it)
  const L = courseLength(world);
  let truck: TruckState = initialTruck();
  let minGap = Infinity, maxGap = truck.pos;   // the truck's lead over the rider, tracked across the drive

  for (let i = 0; i < 12000; i++) {
    const dbg = riderDebug(s, world);   // the forward decision FROM s (same one getNextRiderState makes); record shoulder braking
    if (dbg.forwardReason === ForwardReason.AVOID_SHOULDER)
      shoulderDecel[s.segment] = Math.min(shoulderDecel[s.segment] ?? 0, dbg.accel);
    const n = nextRiderGaze(getNextRiderState(s, world), world);   // bike, then gaze (the same order as main.ts)
    if (n.segment !== s.segment) crossings++;
    maxAcross = Math.max(maxAcross, Math.abs(n.across));
    maxV = Math.max(maxV, n.v);
    // BASELINE captures: slowest point (state n, on its own segment) and hardest realized brake
    // (v drop across this press, charged to the approach segment s with its forward reason).
    const rfn = inRefFrame(n, world);
    const sl = slowest[n.segment];
    if (!sl || n.v < sl.v) slowest[n.segment] = { v: n.v, along: n.along, across: n.across, x: rfn.x, y: rfn.a };
    const accel = n.v - s.v;
    const hd = hardest[s.segment];
    if (!hd || accel < hd.accel) {
      const rfs = inRefFrame(s, world);
      hardest[s.segment] = { accel, reason: dbg.forwardReason, along: s.along, across: s.across, x: rfs.x, y: rfs.a };
    }
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

  // BASELINE METRIC — max deceleration the SHOULDER brake imposes per segment (most-negative accel while
  // AVOID_SHOULDER is binding). Printed here, before the assertions, so it surfaces regardless of any later
  // failure (e.g. the gaze assertion while the distracted-rider glance is TEMP-disabled).
  console.log(`  drive: ${states.length - 1} presses`);
  console.log(`  max off-centre reached: ${maxAcross.toFixed(3)}m (road half-width ${(world.segments[world.order[0]].width / 2).toFixed(1)}m — must stay under)`);
  console.log('  max shoulder deceleration per segment (m/press^2, blank = never braked for the shoulder):');
  for (const id of world.order) {
    const d = shoulderDecel[id];
    console.log(`    ${id.padEnd(6)} ${d === undefined ? '—' : d.toFixed(4)}`);
  }

  // BASELINE for the intersection-entry rework: slowest point + hardest brake per segment. (x,y) is the
  // seg-1 reference-frame map point; d2end = metres from that point to the segment's end (the intersection).
  console.log('  baseline per segment — SLOWEST point and HARDEST brake (for the intersection-entry rework):');
  console.log('    seg     slowest_v  along  d2end  across      (x,y)   |  hardest_decel  reason                   along  d2end  across      (x,y)');
  for (const id of world.order) {
    const len = world.segments[id].length;
    const sl = slowest[id], hd = hardest[id];
    const slStr = sl
      ? `${sl.v.toFixed(3).padStart(8)} ${sl.along.toFixed(0).padStart(6)} ${(len - sl.along).toFixed(0).padStart(6)} ${sl.across.toFixed(2).padStart(7)}  (${sl.x.toFixed(0)},${sl.y.toFixed(0)})`.padEnd(40)
      : '—'.padEnd(40);
    const hdStr = hd
      ? `${hd.accel.toFixed(4).padStart(9)}  ${hd.reason.padEnd(22)} ${hd.along.toFixed(0).padStart(6)} ${(len - hd.along).toFixed(0).padStart(6)} ${hd.across.toFixed(2).padStart(7)}  (${hd.x.toFixed(0)},${hd.y.toFixed(0)})`
      : '—';
    console.log(`    ${id.padEnd(6)} ${slStr} | ${hdStr}`);
  }

  // 0) the model's per-segment northHeading matches an independent accumulation
  for (const id of world.order) {
    if (Math.abs(world.segments[id].northHeading - headings[id]) > 1e-9) {
      throw new Error(`northHeading mismatch on ${id}: ${world.segments[id].northHeading} vs ${headings[id]}`);
    }
  }

  // 1) invariants on every state
  for (const st of states) assertInvariants(st, world);

  // 1b) the distracted-rider PIG GAZE (rider_gaze.ts). The rider GAWKS only on the first PIG_NOVELTY_COUNT
  // pig legs (a novelty that wears off): on those legs he eases to the gawk speed, turns his head toward the
  // designated pig up to GAZE_RELEASE_ANGLE, then drifts his eyes back to the road BEFORE the corner (no snap
  // at the seam) and — having seen the pigs — never re-accelerates for the rest of the leg. Everywhere else he
  // keeps his eyes ahead. We build the per-segment gaze/focus profile and pin the whole behaviour to it.
  const segGazePeak: Record<string, number> = {};    // peak |gazeYaw| per segment (degrees)
  const segFocusPeak: Record<string, number> = {};   // peak narrowing per segment (0..1)
  for (const st of states) {
    segGazePeak[st.segment] = Math.max(segGazePeak[st.segment] ?? 0, Math.abs(st.gazeYaw) * 180 / Math.PI);
    segFocusPeak[st.segment] = Math.max(segFocusPeak[st.segment] ?? 0, gazeFocus(st));
  }
  // the gawk legs ARE the first PIG_NOVELTY_COUNT pig-bearing segments in route order.
  const gawkLegs = world.order.filter((id) => world.segments[id].pigs).slice(0, PIG_NOVELTY_COUNT);
  const RELEASE_DEG = GAZE_RELEASE_ANGLE * 180 / Math.PI;
  // (i) the distraction fires on EXACTLY those legs and nowhere else (novelty wears off; pig-less legs never glance).
  const GAZE_FIRES_DEG = 1;
  for (const id of world.order) {
    const fires = segGazePeak[id] > GAZE_FIRES_DEG, shouldFire = gawkLegs.includes(id);
    if (fires !== shouldFire) {
      throw new Error(`pig-gaze fires on ${id} (peak ${segGazePeak[id].toFixed(1)}deg) but it ${shouldFire ? 'should be a gawk leg' : 'should NOT (no pigs, or the novelty has worn off)'}`);
    }
  }
  // (ii)-(v) the shape of the gawk on each of those legs.
  for (const id of gawkLegs) {
    const ss = states.filter((st) => st.segment === id);
    // (ii) the head turns up to JUST UNDER the release angle (it lags the bearing, then releases at the angle).
    const peak = segGazePeak[id];
    if (peak > RELEASE_DEG || peak < RELEASE_DEG - 3) {
      throw new Error(`${id} gaze peaks ${peak.toFixed(1)}deg, expected just under the ${RELEASE_DEG.toFixed(0)}deg release angle`);
    }
    // (iii) the camera focus fully narrows during the gawk.
    if (segFocusPeak[id] < 0.99) throw new Error(`${id} focus only reached ${segFocusPeak[id].toFixed(2)}, expected ~1 at the gaze peak`);
    // (iv) eyes drift back to straight BEFORE he commits to the corner, and are exactly straight at the seam
    // (so the next segment's reset can't snap the head).
    const commit = world.segments[id].alongWhereRiderCommitsToTurn;
    let gazeBackAlong = -Infinity;   // the last along where his head was still off-straight
    for (const st of ss) if (Math.abs(st.gazeYaw) * 180 / Math.PI > 0.01) gazeBackAlong = st.along;
    if (!(gazeBackAlong < commit)) throw new Error(`${id} eyes not back before the turn: head still off-straight at along ${gazeBackAlong.toFixed(0)} >= commit ${commit.toFixed(0)}`);
    if (Math.abs(ss[ss.length - 1].gazeYaw) > 1e-9) throw new Error(`${id} head ${(ss[ss.length - 1].gazeYaw * 180 / Math.PI).toFixed(1)}deg off-straight at the seam — it would snap to 0 at the crossing`);
    // (v) he slows to the gawk speed (he's there by the gaze peak) and NEVER re-accelerates for the rest of the
    // leg — from the peak on, the corner may take him slower, but speed never climbs back above the gawk speed.
    // (The kinematic hold leaves a few-millionths residual above the exact speed, so allow a hair of tolerance.)
    const GAWK_TOL = 1e-3;
    const peakIdx = ss.reduce((best, st, i) => (Math.abs(st.gazeYaw) > Math.abs(ss[best].gazeYaw) ? i : best), 0);
    if (ss[peakIdx].v > PIG_GAZE_SPEED + GAWK_TOL) throw new Error(`${id} still going ${ss[peakIdx].v.toFixed(3)} at the gaze peak — not slowed to the gawk speed ${PIG_GAZE_SPEED}`);
    for (let k = peakIdx; k < ss.length; k++) {
      if (ss[k].v > PIG_GAZE_SPEED + GAWK_TOL) throw new Error(`${id} re-accelerated to ${ss[k].v.toFixed(3)} after the pigs (above the gawk speed ${PIG_GAZE_SPEED})`);
    }
  }
  console.log(`  pig-gaze: gawks on [${gawkLegs.join(', ')}] — peak ~${RELEASE_DEG.toFixed(0)}deg, focus full, slows to ${PIG_GAZE_SPEED} and holds, eyes back before each corner`);

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

  // 2) heading + the LEAN that drives it. The bike turns BECAUSE it's leaned — tilt is free RiderState now —
  // so we read the lean DIRECTLY from state.tilt rather than reconstructing it from the heading change. We
  // watch how DEEP the rider leans to carve the route's sharp turns (maxTilt — a free outcome of YAW_PER_TILT,
  // reported not pinned), and that the lean only ever EASES (maxTiltStep), plus per-press heading continuity.
  let maxHeadingJump = 0, maxTilt = 0, maxTiltStep = 0;
  for (let i = 1; i < states.length; i++) {
    const dh = wrap(heading(states[i], headings) - heading(states[i - 1], headings));
    maxHeadingJump = Math.max(maxHeadingJump, Math.abs(dh));
    maxTilt = Math.max(maxTilt, Math.abs(states[i].tilt));
    maxTiltStep = Math.max(maxTiltStep, Math.abs(states[i].tilt - states[i - 1].tilt));   // frame-to-frame lean change
  }

  // 2c) the lean only EASES: no single press changes the tilt by more than TILT_STEP (1deg). This is a genuine
  // invariant of the prorated tilt update + snap-to-upright (it carries unchanged across the segment seam), and
  // it replaces the old TURN_OMEGA/MAX_LEAN ceilings, which pinned a rotation rate the tilt model no longer has.
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
  console.log(`  max heading jump  : ${maxHeadingJump.toFixed(4)} rad/press`);
  console.log(`  max position jump : ${maxPosJump.toFixed(4)} m (peak speed = ${maxV.toFixed(4)} m/press)`);
  console.log(`  max off-centre    : ${maxAcross.toFixed(3)} m (bulge; road half-width = ${(world.segments[world.order[0]].width / 2).toFixed(1)})`);
  console.log(`  max tilt          : ${(maxTilt * 180 / Math.PI).toFixed(1)} deg (the deepest lean to carve a turn; YAW_PER_TILT-driven, not pinned)`);
  console.log(`  max tilt step     : ${(maxTiltStep * 180 / Math.PI).toFixed(2)} deg/press (limit 1.0)`);
  console.log(`  self-intersect    : none (${world.order.length} segments checked pairwise)`);
}

main();
