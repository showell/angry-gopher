// rider.ts — the RIDER: his state (position, velocity, heading, lean, gaze) and how he decides to move,
// one frame at a time. Pure and node-testable (test/test_model.ts); no canvas, no world coordinates — a
// segment relates to its neighbour only by a turn ANGLE.
//
// WHAT THE RIDER WANTS (his whole personality, in four rules):
//   • Go fast — accelerate at a constant rate whenever the road ahead is clear, up to V_MAX.
//   • Don't run over the cat — while a cat is crossing inside its danger window he HOLDS the throttle
//     (stops accelerating) until it's clear; he never brakes for it, just stops closing on it.
//   • Turn safely but quickly — brake to a tabulated safe entry speed for the corner, then lean into it and
//     let the tilt bring his heading around, straightening back out as he fills the lane to the far edge.
//   • Glance at the pigs — a brief VIEW-ONLY head-turn toward the roadside pigs and back as he nears a
//     turn; it never touches the path or the physics. The gaze is its OWN step, run after the bike moves
//     each frame — the logic lives in rider_gaze.ts (the caller runs bike-then-gaze; see getNextRiderState).
//
// HOW HE MOVES, FRAME BY FRAME: position is relative to the CURRENT segment — along (progress), across
// (lateral offset, + = right), yaw (heading vs the segment), v (speed, m/press), plus the bike's tilt (lean)
// carried in `turn`. Each press getNextRiderState makes a forward decision (getForwardAccelDecel: throttle/
// brake) and a rotational one (the lean): the rider tips the bike a notch further into the corner, and the
// tilt — leading by a frame — yaws his heading by YAW_PER_TILT per unit of tilt. Cruising keeps across/yaw at 0
// (bike upright) and advances along by v. Every turn is a straighten-out (no rigid arcs): the moment he crosses
// the next segment's inner-edge extension he's re-expressed in that segment's frame, still pointed the old way,
// then leans his heading back toward 0 while drifting to the far edge.

import type { World } from './world.ts';
import type { RoadSegment, SegId } from './road_segment.ts';
import { turnSpeed } from './intersection.ts';
import { segmentCatDanger } from './cat_motion.ts';

// ----------------------------------------------------------------------------
// types
// ----------------------------------------------------------------------------

// Which road edge the rider's projected arc would run off FIRST (NONE = he stays on the road). The rider
// leans AWAY from the danger: LEFT -> tilt right, RIGHT -> tilt left. See simulateRiderPath.
export const DangerSide = { LEFT: 'LEFT', NONE: 'NONE', RIGHT: 'RIGHT' } as const;
export type DangerSide = typeof DangerSide[keyof typeof DangerSide];

// A projected path's outcome: which shoulder it ran off (NONE if it stayed on the road through the scoring
// window), the FORWARD progress it made (capped at MIN_FORWARD_PROGRESS so all surviving paths tie exactly),
// whether it crossed the centre line, and the ACTUAL arc walked (centre-relative along/across, ending where it
// terminated) — returned so the debug overlay renders precisely what was computed, never a drifting mimic.
export interface PathSim { side: DangerSide; forward: number; crossed: boolean; endAcross: number; framesUntilDanger: number; path: { along: number; across: number }[] }

// Why the forward (throttle/brake) decision came out the way it did — whichever constraint was BINDING this
// frame. CRUISE = accelerating freely; HOLD_LEAN = throttle shut because he's leaned past TILT_HOLD;
// AVOID_SPEEDING = capped at V_MAX; PREPARE_FOR_INTERSECTION = braking to the corner's entry speed; AVOID_CAT
// = holding for a crossing cat; AVOID_SHOULDER = braking so he doesn't run off the road edge.
export const ForwardReason = {
  CRUISE: 'CRUISE', HOLD_LEAN: 'HOLD_LEAN', AVOID_SPEEDING: 'AVOID_SPEEDING',
  PREPARE_FOR_INTERSECTION: 'PREPARE_FOR_INTERSECTION', AVOID_CAT: 'AVOID_CAT', AVOID_SHOULDER: 'AVOID_SHOULDER',
} as const;
export type ForwardReason = typeof ForwardReason[keyof typeof ForwardReason];

// A HUD-only readout of the forward+lean decision — NOT part of the rider's state, just the frame's internal
// choices surfaced for the debug overlay.
export interface RiderDebug { accel: number; forwardReason: ForwardReason; tiltStep: number; headingChange: number; yawFromTarget: number; tiltSnapped: boolean; yawAimed: boolean }
// Recompute the decision the rider WOULD make FROM `state` this frame — pure, no side effects — so the HUD
// shows the CURRENT frame's numbers, aligned with the danger it also reads fresh (no stale off-by-one).
export function riderDebug(state: RiderState, world: World): RiderDebug {
  return decide(state, world.segments[state.segment], world).debug;
}

// The whole game is seen through the RIDER (on a motorcycle, treated as a single POINT, which keeps the
// physics simple). A RiderState is everything we know about him this frame:
//   POSITION : segment + along (progress) + across (lateral offset) + yaw (heading vs the segment)
//   VELOCITY : v (speed along the path, m/press)
//   LEAN     : tilt (the bike's roll — 0 when upright; it's what turns the bike, see getNextRiderState)
// There is no "turning" mode any more: the rider is always just driving, sometimes leaned. `gazeStep` carries
// the glance.
export interface RiderState {
  segment: SegId;
  along: number;
  across: number;
  yaw: number;        // the bike's heading offset from straight down the lane (rad; + = pointed right)
  v: number;          // speed along the path (m/press)
  tilt: number;       // the bike's lean (rad; + = leaned right). Yaws the heading at YAW_PER_TILT per unit.
  gazeStep: number;   // the "distracted rider" glance: -1 = eyes ahead, 0..8 = mid-glance, >=9 = done
}

// ----------------------------------------------------------------------------
// constants — motion is per-press (not metres) unless a comment says otherwise
// ----------------------------------------------------------------------------

export const V_BASE = 0.3;    // speed at the very start of the drive (m/press)
export const A_ACCEL = 0.010; // constant acceleration while the intersection is still far off (m/press^2)
export const V_MAX = 2.5;     // top speed — the bike never accelerates past this (the truck caps off this too)

// the Rider starts slowing once the next intersection is within this distance (metres)
export const APPROACH_INTERSECTION_DIST = 60;

// A reference lean angle the renderer scales its focal pull-in against (camera effects saturate near it).
// No longer a hard cap on the physics: the rider's tilt is now free state (getNextRiderState), and with a
// low YAW_PER_TILT he may lean well past this to carve a sharp turn.
export const MAX_LEAN = 20 * Math.PI / 180;

// straighten-out tuning. Every turn is a straighten-out (no rigid arcs); the geometry requires the turn
// angle to be at most 90deg — beyond that the Rider would enter the next segment pointed backwards.
// test/test_model.ts enforces it on the configured route.
export const MAX_TURN_ANGLE = 90 * Math.PI / 180;   // the largest turn the model allows
const STRAIGHTEN_MARGIN = 0.05;             // hard safety: keep the drift bulge at least this far inside the edge (m)
const TURN_DANGER_STEPS = 2000;            // STEERING look-ahead (a hard cap; the loop almost always ends earlier on danger or crossing MIN_FORWARD_PROGRESS). Big enough that the projection reaches the road's end even when he's crawling.
const MIN_FORWARD_PROGRESS = 25;            // scoring distance (m): a projected lean that survives this far without running off counts as "good enough" — its forward score is pinned here so survivors tie and the cross-centre / least-lean tiebreak decides. Shorter = more leans tie = more averse to hugging a side (but can oscillate)
const TILT_SNAP = 1.5 * Math.PI / 180;      // part of the snap-to-centre window: the lean must be within this of upright
const TILT_HOLD = 2 * Math.PI / 180;        // he only adds throttle while leaned LESS than this — accelerating mid-lean makes the constant-v danger projection lie and reads as jitter
const YAW_EPSILON = 1.5 * Math.PI / 180;    // part of the snap-to-centre window: the heading must be within this of straight
const AIMING_DISTANCE = 100;                // when upright, the rider aims his heading at the lane centre this far ahead (m) — eases him back to the middle
const YAW_PER_TILT = 0.1;                   // the lean's leverage on the bike: every degree of tilt yaws the heading 0.1deg (so a turn demands a DEEP, dramatic lean)
const BRAKE_DECAY = 40;                      // shoulder brake fudge factor (frames): the kinematic decel decays exp(-N/this) as frames-until-danger N grows, so he under-brakes for far-off danger (trusting he'll steer out) and only fully brakes when it's imminent


// The heading that points the rider at the lane CENTRE, AIMING_DISTANCE ahead, from a lateral offset `across`
// (0 when centred; tilts back toward the middle when off to a side). His straighten-out target — used both to
// snap him clean (getNextRiderState) and to treat OVERSHOOTING it as a danger (simulateRiderPath).
function aimYawFor(across: number): number {
  return Math.atan2(-across, AIMING_DISTANCE);
}

// ----------------------------------------------------------------------------
// functions
// ----------------------------------------------------------------------------

export function initialRiderState(world: World): RiderState {
  return { segment: world.start, along: 0, across: 0, yaw: 0, v: V_BASE, tilt: 0, gazeStep: -1 };
}

// The Rider's heading relative to north (north = seg1's forward direction). This is the one ABSOLUTE
// orientation we expose: far scenery (the horizon) is drawn purely from it, because a mountain at
// infinity depends on which way the Rider faces, not where it is. Continuous across segment crossings.
export function riderHeading(state: RiderState, world: World): number {
  return world.segments[state.segment].northHeading + state.yaw;
}

// The rider's lean (camera roll): the bike's TILT — 0 when upright. The renderer reads it directly as the
// camera roll, the focal pull-in, and a subtle head-yaw into the corner.
export function riderTilt(state: RiderState): number {
  return state.tilt;
}

// Has the rider reached the end of the route — at rest at the end of the final (exit-less) segment?
export function riderFinished(rider: RiderState, world: World): boolean {
  const lastId = world.order[world.order.length - 1];
  return rider.segment === lastId && rider.along >= world.segments[lastId].length - 1e-6;
}

// How far the rider has driven ALONG the route: the lengths of every segment behind his current one
// plus his along on it. Treats each joint as zero-length (segments abut at the inner edge) — monotonic
// and exact enough for chase dynamics (truck.ts reels itself in against this). Not a global position,
// just arc-length along the 1D route.
export function routeDistance(state: RiderState, world: World): number {
  let d = 0;
  for (const id of world.order) {
    if (id === state.segment) return d + state.along;
    d += world.segments[id].length;
  }
  return d;
}

// Advance the BIKE one frame. The rider makes two decisions — a forward one (throttle/brake, getForwardAccelDecel)
// and a rotational one (lean, steered by simulateRiderPath) — which we integrate into the new velocity, heading, and
// position, then resolve where that lands him on the road graph BY POSITION (there is no turning "mode"). Pure;
// the gaze is carried through unchanged and advanced separately (the caller runs nextRiderGaze right after).
// The forward + lean + snap DECISION this frame, as raw post-snap values (no graph transition yet) plus the
// debug readout. Shared by getNextRiderState (which then resolves the road graph) and riderDebug (the HUD).
interface Decision { v: number; tilt: number; yaw: number; along: number; across: number; debug: RiderDebug }
function decide(state: RiderState, seg: RoadSegment, world: World): Decision {
  const prevTilt = state.tilt;

  // The LEAN goes FIRST now. The rider evaluates all 21 leans (bestTiltCorrection) and takes the one whose
  // projected path gets furthest down the road, crosses back to centre, and ends nearest the middle. The lean
  // carried IN from last frame yaws the bike YAW_PER_TILT per unit, so the tilt LEADS the yaw by a frame.
  let tilt = bestTiltCorrection(state, seg);
  const headingChange = YAW_PER_TILT * prevTilt;
  let yaw = state.yaw + headingChange;

  // SNAP-TO-CENTRE — resolved BEFORE the forward decision, so a settled straightaway is fully upright + on-aim
  // by the time the shoulder brake looks at the path. The heading we want is aimYaw: pointed at the lane CENTRE,
  // AIMING_DISTANCE ahead (NOT 0 when off-centre). Only when he's BOTH nearly upright (|tilt| < TILT_SNAP) AND
  // already nearly on that aim (|yaw - aimYaw| < YAW_EPSILON) do we tidy him clean: lean to exactly 0 and heading
  // onto aimYaw. Requiring BOTH means a turn (deep lean OR a heading far off the aim) can never trigger it. (We
  // measure the aim from the CURRENT across — this frame's lateral move is negligible for the snap test.)
  const aimYaw = aimYawFor(state.across);
  const yawFromTarget = yaw - aimYaw;                            // signed: how far the natural heading sits from the aim (abs gates the snap)
  const snapped = Math.abs(tilt) < TILT_SNAP && Math.abs(yawFromTarget) < YAW_EPSILON;
  if (snapped) { tilt = 0; yaw = aimYaw; }

  // The FORWARD decision comes AFTER, seeing the FULLY-resolved tilt AND yaw (snap included) — so a snapped,
  // upright, on-aim straightaway projects a clear path and he accelerates instead of braking for a phantom
  // shoulder. Its shoulder brake simulates the rider at exactly this resolved lean + heading.
  const fwd = getForwardAccelDecel({ ...state, tilt, yaw }, seg, world);
  const v = state.v + fwd.accel;

  const midHeading = state.yaw + headingChange / 2;                            // average heading over the frame -> arc
  const along = state.along + v * Math.cos(midHeading);
  const across = state.across + v * Math.sin(midHeading);

  const debug: RiderDebug = { accel: fwd.accel, forwardReason: fwd.reason, tiltStep: tilt - prevTilt, headingChange, yawFromTarget, tiltSnapped: snapped, yawAimed: snapped };
  return { v, tilt, yaw, along, across, debug };
}

// the gaze is carried through unchanged and advanced separately (the caller runs nextRiderGaze right after).
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];
  const { v, tilt, yaw, along, across } = decide(state, seg, world);
  const riderState: RiderState = { segment: seg.id, along, across, yaw, v, tilt, gazeStep: state.gazeStep };

  // Resolve the road graph by POSITION (not by any turn flag): on reaching the commit point, cross into the
  // next segment; at a terminus, stop dead at the end.
  const exitIxn = world.intersections[seg.exitIxn];
  if (exitIxn.to !== null && along >= seg.alongWhereRiderCommitsToTurn)
    return riderStateForNextSegment(riderState, world);
  if (exitIxn.to === null && along >= seg.length)
    return { ...riderState, along: seg.length, v: 0 };
  return riderState;
}

// Re-express the rider onto the NEXT segment as he commits to the turn: he keeps his speed AND his lean (the
// bike's roll is physically continuous across the seam) but lands on the new segment's inner edge, now pointed
// the old way relative to the new direction — a touch before its begin line (negative along), the same physical
// point, so motion stays continuous — and straightens out from there, eyes on the road.
function riderStateForNextSegment(riderState: RiderState, world: World): RiderState {
  const seg = world.segments[riderState.segment];
  const exitIxn = world.intersections[seg.exitIxn];
  const next = world.segments[exitIxn.to as string], hw = seg.width / 2, theta = exitIxn.angle, sgn = exitIxn.sign;
  return { segment: next.id, along: -hw / Math.sin(theta), across: sgn * hw, yaw: -sgn * theta,
           v: riderState.v, tilt: riderState.tilt, gazeStep: -1 };
}

// THE FORWARD DECISION — throttle/brake — returns the change in speed this frame AND the binding reason (see
// ForwardReason). One obstacle-reactive rule, no cruising/turning phases: he WANTS to accelerate, but takes the
// most restrictive (minimum) of three brakes — the upcoming corner (reach its safe entry speed by the commit
// point), a crossing cat (hold the throttle), and the road edge/shoulder (kinematic-brake to arrive at it at
// v=0). When approaching the corner he won't crawl below its entry speed. He only opens the throttle while
// near-upright (|tilt| < TILT_HOLD): accelerating mid-lean would make the constant-v danger projection
// underestimate where he ends up. Braking always applies, leaned or not. The `reason` is whichever term ends up
// binding — surfaced in the HUD and collected as a baseline metric (max shoulder decel per segment).
function getForwardAccelDecel(state: RiderState, seg: RoadSegment, world: World): { accel: number; reason: ForwardReason } {
  const leaned = Math.abs(state.tilt) >= TILT_HOLD;
  let a = leaned ? 0 : A_ACCEL;                              // throttle only when near-upright; brakes below still fire
  let reason: ForwardReason = leaned ? ForwardReason.HOLD_LEAN : ForwardReason.CRUISE;

  // brake for the upcoming corner: the constant decel (v^2 = vEnd^2 + 2*a*d) that lands him at the corner's
  // safe entry speed right at the commit point, recomputed each press so it self-corrects integration drift.
  const vEnd = turnSpeed(world.intersections[seg.exitIxn]);   // safe entry speed (0 at a terminus)
  const near = nearIntersection(state, seg);
  if (near) {
    const d = seg.alongWhereRiderCommitsToTurn - state.along;
    const cornerA = d <= 1e-6 ? 0 : (vEnd * vEnd - state.v * state.v) / (2 * d);
    if (cornerA < a) { a = cornerA; reason = ForwardReason.PREPARE_FOR_INTERSECTION; }
  }
  if (segmentCatDanger(seg.cats, state.along, state.v) && a > 0) { a = 0; reason = ForwardReason.AVOID_CAT; }  // hold throttle for a crossing cat

  // Brake for the road edge using the rider's ACTUAL simulated path at his just-chosen lean (state.tilt/yaw
  // already hold this frame's lean + heading) — so the brake has FAITH the bike will turn, instead of the old
  // straight-line shoulderDistance. If the path runs off a shoulder in N frames, kinematically slow to arrive
  // there at v=0 (a = -v / 2N — stop within the distance he'd cover in N frames). If the path is clear, no brake.
  const sim = simulateRiderPath(state, seg);
  if (sim.side !== DangerSide.NONE) {
    // Kinematic stop-before-the-edge (a = -v/2N), then DECAYED: the rider fudges it — he doesn't fully brake for
    // danger that's still many frames off (he trusts he'll steer out), so the decel decays exp(-N/BRAKE_DECAY)
    // away from the full kinematic value as the frames-until-danger N grows. Imminent danger (N~0) still gets the
    // full brake. (A simple decay, NOT a re-projection with changing tilt — the rider fudges, so we fudge.)
    const N = sim.framesUntilDanger;
    const shoulderA = -state.v / (2 * Math.max(N, 1)) * Math.exp(-N / BRAKE_DECAY);
    if (shoulderA < a) { a = shoulderA; reason = ForwardReason.AVOID_SHOULDER; }
  }

  let v = state.v + a;
  if (v > V_MAX) { v = V_MAX; reason = ForwardReason.AVOID_SPEEDING; }      // capped at top speed
  if (v < 0) v = 0;
  if (near && v < vEnd) v = vEnd;   // don't crawl below the corner's entry speed approaching it
  return { accel: v - state.v, reason };
}

// Is the Rider close enough to the upcoming intersection to start slowing for it? Every segment exits
// through an intersection (a turn, or the terminus), so this is just "within braking distance of the end".
function nearIntersection(state: RiderState, seg: RoadSegment): boolean {
  return seg.length - state.along <= APPROACH_INTERSECTION_DIST;
}


// Project his ARC forward (tilt held constant -> a constant heading-change per step, speed held constant) and
// score how that lean PLAYS OUT. The projection runs until one of:
//   • it runs off a shoulder           -> { side: LEFT|RIGHT, forward = progress at the hit }   (a bad lean)
//   • it goes net-BACKWARD (forward<0) -> the disaster case; the negative forward sinks it in the ranking
//   • it clears MIN_FORWARD_PROGRESS   -> { side: NONE, forward = MIN_FORWARD_PROGRESS exactly }  (a good lean)
// `forward` is the score (more is better) and is pinned to EXACTLY MIN_FORWARD_PROGRESS for every surviving
// path so they tie cleanly and the caller can tiebreak. `crossed` = did the arc cross the centre line. The
// shoulder boundary on each side is the WORSE of the inset edge (STRAIGHTEN_MARGIN inside the real shoulder)
// and where the rider ALREADY sits, so a path is only "off" if it pushes him FURTHER toward a shoulder than he
// already is — not for merely starting near the edge.
export function simulateRiderPath(state: RiderState, seg: RoadSegment): PathSim {
  const insetHw = seg.width / 2 - STRAIGHTEN_MARGIN;
  const rightBound = Math.max(insetHw, state.across);
  const leftBound = Math.min(-insetHw, state.across);
  const headingStep = YAW_PER_TILT * state.tilt;                            // constant per step (tilt held fixed)
  let yaw = state.yaw, across = state.across, forward = 0, crossed = false;
  const startSide = Math.sign(across);                                      // which side of centre he starts on
  const path: { along: number; across: number }[] = [];                    // the arc actually walked — returned so the overlay matches exactly
  for (let i = 0; i < TURN_DANGER_STEPS; i++) {
    const mid = yaw + headingStep / 2;                                      // midpoint heading over the step
    forward += state.v * Math.cos(mid);
    across += state.v * Math.sin(mid);                                      // arc step
    yaw += headingStep;
    path.push({ along: state.along + forward, across });                    // record this projected point (last one IS the exit point)
    if (across * startSide < 0) crossed = true;                            // the arc has made it across centre
    if (across < leftBound) return { side: DangerSide.LEFT, forward, crossed, endAcross: across, framesUntilDanger: i, path };       // ran off the left shoulder in i frames
    if (across > rightBound) return { side: DangerSide.RIGHT, forward, crossed, endAcross: across, framesUntilDanger: i, path };     // ran off the right shoulder in i frames
    if (forward < 0) return { side: DangerSide.NONE, forward, crossed, endAcross: across, framesUntilDanger: Infinity, path };       // spun net-backward — disaster (no shoulder danger)
    if (forward >= MIN_FORWARD_PROGRESS) return { side: DangerSide.NONE, forward: MIN_FORWARD_PROGRESS, crossed, endAcross: across, framesUntilDanger: Infinity, path };  // cleared (no shoulder danger)
  }
  return { side: DangerSide.NONE, forward, crossed, endAcross: across, framesUntilDanger: Infinity, path };
}

const TILT_SEARCH_STEPS = 10;                     // +/- this many 0.1deg steps -> 21 lean options spanning [-MAX, +MAX]
const MAX_TILT_CORRECTION = 1 * Math.PI / 180;    // the most the rider can work his lean over in a single frame (he has to fight the bike's mass)

// the lean the rider would hold at search option j (0..2*TILT_SEARCH_STEPS): delta runs -MAX (lean hard left)
// through 0 (hold) to +MAX (lean hard right).
function leanAtOption(state: RiderState, j: number): number {
  return state.tilt + MAX_TILT_CORRECTION * (j - TILT_SEARCH_STEPS) / TILT_SEARCH_STEPS;
}

// THE LEAN SEARCH (shared by the real decision and the debug overlay). Evaluate ALL 21 leans and rank by how
// the projected path plays out (simulateRiderPath): pick the path that makes the MOST forward progress (surviving
// paths all tie at exactly MIN_FORWARD_PROGRESS); among that tie prefer the one that CROSSES the centre line,
// then — among those — the one that ENDS CLOSEST TO CENTRE. So he commits the lean that gets him cleanly down
// the road, back across the middle, and settled nearest the lane centre. Returns the chosen option index.
function leanBetter(a: PathSim, b: PathSim): boolean {
  if (a.forward !== b.forward) return a.forward > b.forward;             // primary: furthest forward (capped, so survivors tie exactly)
  if (a.crossed !== b.crossed) return a.crossed;                         // tiebreak: cross the centre line
  return Math.abs(a.endAcross) < Math.abs(b.endAcross);                  // tiebreak: end closest to centre
}
function chosenLeanOption(state: RiderState, seg: RoadSegment): number {
  let bestJ = 0, bestD = simulateRiderPath({ ...state, tilt: leanAtOption(state, 0) }, seg);
  for (let j = 1; j <= 2 * TILT_SEARCH_STEPS; j++) {
    const d = simulateRiderPath({ ...state, tilt: leanAtOption(state, j) }, seg);
    if (leanBetter(d, bestD)) { bestJ = j; bestD = d; }
  }
  return bestJ;
}

function bestTiltCorrection(state: RiderState, seg: RoadSegment): number {
  return leanAtOption(state, chosenLeanOption(state, seg));
}

// The debug overlay's data: the ACTUAL arc simulateRiderPath walked for EVERY one of the 21 lean options WITH the
// shoulder it ran off (NONE if it survived), and which index the rider chose. The chosen index comes from
// chosenLeanOption, the SAME ranking the real decision uses, so the yellow path can't disagree with what he does.
export interface LeanCandidate { path: { along: number; across: number }[]; side: DangerSide }
export interface LeanCandidates { candidates: LeanCandidate[]; chosen: number }
export function leanCandidates(state: RiderState, seg: RoadSegment): LeanCandidates {
  const chosen = chosenLeanOption(state, seg);
  const candidates: LeanCandidate[] = [];
  for (let j = 0; j <= 2 * TILT_SEARCH_STEPS; j++) {
    const cd = simulateRiderPath({ ...state, tilt: leanAtOption(state, j) }, seg);
    candidates.push({ path: cd.path, side: cd.side });
  }
  return { candidates, chosen };
}
