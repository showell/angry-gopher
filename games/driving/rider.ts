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
import { simulateRiderStep, YAW_PER_TILT } from './bike_physics.ts';
import type { RiderPhysics } from './bike_physics.ts';

// ----------------------------------------------------------------------------
// types
// ----------------------------------------------------------------------------

// Which road edge the rider's projected arc would run off FIRST (NONE = he stays on the road). The rider
// leans AWAY from the danger: LEFT -> tilt right, RIGHT -> tilt left. See simulateRiderPath.
export const DangerSide = { LEFT: 'LEFT', NONE: 'NONE', RIGHT: 'RIGHT' } as const;
export type DangerSide = typeof DangerSide[keyof typeof DangerSide];

// A projected path's outcome: which shoulder it ran off (NONE if it stayed on the road for the whole horizon),
// the FORWARD progress it made, the frame it hit danger (Infinity if none), whether it crossed the centre line,
// and the ACTUAL arc walked (centre-relative along/across, ending where it terminated) — returned so the debug
// overlay renders precisely what was computed, never a drifting mimic. The search scores an on-road path by how
// near its endpoint lands to the aiming point; any danger (off-shoulder or looped) is treated as infinitely far.
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

// The ONLY things the rider decides each frame: a tilt-step (how much to work the lean) and an acceleration
// (throttle/brake). forwardReason explains which constraint set the accel — carried along for the HUD, not a
// separate decision. Everything else (heading, speed, position) is left to the physics in getNextRiderState.
export interface RiderDecision { tiltStep: number; accel: number; forwardReason: ForwardReason }
// Recompute the decision the rider WOULD make FROM `state` this frame — pure, no side effects — so the HUD
// shows the CURRENT frame's numbers, aligned with the danger it also reads fresh (no stale off-by-one).
export function riderDebug(state: RiderState, world: World): RiderDecision {
  return decide(state, world.segments[state.segment], world);
}

// The whole game is seen through the RIDER (on a motorcycle, treated as a single POINT, which keeps the
// physics simple). A RiderState is his PHYSICS (RiderPhysics: tilt/yaw/v/along/across — see bike_physics.ts)
// plus the non-physical context the rider carries: which segment he's on and his gaze glance. There is no
// "turning" mode — he's always just driving, sometimes leaned.
export interface RiderState extends RiderPhysics {
  segment: SegId;     // which road segment he's on (the RiderPhysics fields are relative to it)
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
const TURN_DANGER_STEPS = 2000;            // default projection cap (frames) when no horizon is given; the search uses its own danger-scaled MAX_LOOKAHEAD. Big enough that the projection reaches the road's end even when he's crawling.
const TILT_HOLD = 2 * Math.PI / 180;        // he only adds throttle while leaned LESS than this — accelerating mid-lean makes the constant-v danger projection lie and reads as jitter
const BRAKE_DECAY = 40;                    // shoulder brake fudge factor (frames): the kinematic decel decays exp(-N/this) as frames-until-danger N grows, so he under-brakes for far-off danger (trusting he'll steer out) and only fully brakes when it's imminent
const CENTER_LANE_EPSILON = 0.04;           // once he's THIS close to centre, stop chasing the exact middle — aim for the band EDGE (+/-this) on the side he's on, a stable target he can hold instead of twitching after a zero he can't physically keep (and off the start line, +this, so he pulls away at a slight angle)

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

// DECIDE — purely the rider's brain: it picks his two controls for the frame and NOTHING else (no physics, no
// new position). The LEAN: steerTiltStep is an O(1) saturated-linear regulator on the lateral triple integrator
// (no projection or search). The FORWARD: with that chosen lean, getForwardAccelDecel reads off his accel.
// getNextRiderState EXECUTES these controls through the physics; riderDebug reads them for the HUD.
function decide(state: RiderState, seg: RoadSegment, world: World): RiderDecision {
  const tiltStep = steerTiltStep(state);
  const fwd = getForwardAccelDecel(state, seg, world, tiltStep);
  return { tiltStep, accel: fwd.accel, forwardReason: fwd.reason };
}

// Advance the BIKE one frame: get the rider's CONTROLS (decide), EXECUTE them through the shared physics
// (simulateRiderStep applies the tilt-step + accel and integrates heading/speed/position), then resolve where
// that lands him on the road graph BY POSITION. Pure; the gaze is advanced separately (the caller runs
// nextRiderGaze right after).
export function getNextRiderState(state: RiderState, world: World): RiderState {
  const seg = world.segments[state.segment];
  const { tiltStep, accel } = decide(state, seg, world);
  const moved = simulateRiderStep(state, tiltStep, accel);
  const riderState: RiderState = { ...moved, segment: seg.id, gazeStep: state.gazeStep };

  // Resolve the road graph by POSITION (not by any turn flag): toward a turn, re-express him in the NEXT
  // segment's frame EVERY frame and commit the moment his real position is actually within that road
  // (|across| < half-width); at a terminus, stop dead at the end. No precomputed cutoff — that assumed he
  // was centred, so it committed a hair early and let him clip past the inner edge. Doing it live also frees
  // him to cut the corner later without the seam lying about where he is.
  const exitIxn = world.intersections[seg.exitIxn];
  if (exitIxn.to !== null) {
    const onNext = riderStateForNextSegment(riderState, world);
    if (Math.abs(onNext.across) < world.segments[exitIxn.to].width / 2) return onNext;
  } else if (moved.along >= seg.length) {
    return { ...riderState, along: seg.length, v: 0 };
  }
  return riderState;
}

// Re-express the rider onto the NEXT segment as he commits to the turn: he keeps his speed AND his lean (the
// bike's roll is physically continuous across the seam). His position is the SAME physical point, just read in
// the next segment's frame — we translate his ACTUAL (along, across) through the joint geometry rather than
// snapping him to an idealized inner-edge point. (The old code pinned him to (-hw/sin, sgn*hw, -sgn*theta),
// which is what this transform yields ONLY in the ideal case across=0, yaw=0 at along = L - hw*cos/sin = the
// commit point; it threw away how off-centre / overshot he really was, a small lie at the seam.) The map below
// is the exact INVERSE of the seg-B -> seg-A transform the continuity check composes (test_model localToRef),
// so the seam is now position-continuous by construction. The heading rotates by the turn: yaw_B = yaw_A -
// sgn*theta. Eyes back on the road (gazeStep -1).
function riderStateForNextSegment(riderState: RiderState, world: World): RiderState {
  const seg = world.segments[riderState.segment];
  const exitIxn = world.intersections[seg.exitIxn];
  const next = world.segments[exitIxn.to as string], hw = seg.width / 2, theta = exitIxn.angle, sgn = exitIxn.sign;
  const cos = Math.cos(theta), sin = Math.sin(theta);
  const da = riderState.along - (seg.length + hw * sin);   // his offset from the joint, in seg A's frame
  const dx = riderState.across - sgn * hw * (1 - cos);
  const along = cos * da + sgn * sin * dx;                  // rotate into seg B's frame (inverse of localToRef)
  const across = -sgn * sin * da + cos * dx;
  return { segment: next.id, along, across, yaw: riderState.yaw - sgn * theta,
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
function getForwardAccelDecel(state: RiderState, seg: RoadSegment, world: World, tiltStep: number): { accel: number; reason: ForwardReason } {
  const leaned = Math.abs(state.tilt + tiltStep) >= TILT_HOLD;   // gate on the lean he's COMMITTING to this frame
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

  // Brake for the road edge by SPEED: project his real closed-loop steering and see the worst lateral excursion it
  // reaches. That excursion scales ~linearly with speed (faster -> a heading error costs more metres to undo), so
  // if it would breach the road, slow toward the speed that brings the excursion back inside the edge. Recomputed
  // every frame, so it eases to the equilibrium speed where his steering just fits the road — fast on straights
  // (tiny excursion), slowing into corners (big excursion) on its own, no offline speed table.
  const room = seg.width / 2 - STRAIGHTEN_MARGIN;
  const proj = regulatorProjection(state, BRAKE_HORIZON);
  // slow for whichever is more violated: running off the road (maxAbs vs room) OR weaving past centre (overshoot
  // vs budget). Both scale ~linearly with speed, so target the speed that brings the worse one back in bounds.
  const overLimit = Math.max(proj.maxAbs / room, proj.overshoot / OVERSHOOT_BUDGET);
  if (overLimit > 1) {
    const vSafe = state.v / overLimit;
    const shoulderA = Math.max(vSafe - state.v, -BRAKE_MAX);        // slow toward vSafe, firm but bounded
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


// Project his ARC forward re-applying the SAME tiltStep every frame (the lean RAMPS at that rate; speed held), for
// up to `maxFrames`. Returns where it ENDS and whether it hit trouble first:
//   • off a shoulder            -> { side: LEFT|RIGHT, framesUntilDanger = the frame it hit }
//   • net-BACKWARD (forward<0)  -> a looped/spun path; reported as danger on the side it curled toward
//   • survived all maxFrames    -> { side: NONE }, and the path ENDPOINT is what the caller scores
// The caller scores an on-road (NONE) path by how near its endpoint lands to the aiming point; any danger is taken
// as infinitely far. The shoulder boundary on each side is the WORSE of the inset edge (STRAIGHTEN_MARGIN inside
// the real shoulder) and where the rider ALREADY sits, so a path is "off" only if it pushes him FURTHER toward a
// shoulder than he already is — not for merely starting near the edge.
export function simulateRiderPath(state: RiderState, seg: RoadSegment, tiltStep: number, maxFrames: number = TURN_DANGER_STEPS): PathSim {
  const insetHw = seg.width / 2 - STRAIGHTEN_MARGIN;
  const rightBound = Math.max(insetHw, state.across);
  const leftBound = Math.min(-insetHw, state.across);
  const startSide = Math.sign(state.across);                                // which side of centre he starts on
  const path: { along: number; across: number }[] = [];                    // the arc actually walked — returned so the overlay matches exactly
  let phys: RiderPhysics = state, crossed = false;                          // step the SAME dumb physics forward, speed held — re-applying tiltStep every frame (the lean RAMPS, no flip)
  for (let i = 0; i < maxFrames; i++) {
    phys = simulateRiderStep(phys, tiltStep, 0);                           // keep working the lean over by tiltStep each frame; zero acceleration
    const across = phys.across, forward = phys.along - state.along;
    path.push({ along: phys.along, across });                               // record this projected point (last one IS the exit point)
    if (across * startSide < 0) crossed = true;                            // the arc has made it across centre
    if (across < leftBound) return { side: DangerSide.LEFT, forward, crossed, endAcross: across, framesUntilDanger: i, path };       // ran off the left shoulder in i frames
    if (across > rightBound) return { side: DangerSide.RIGHT, forward, crossed, endAcross: across, framesUntilDanger: i, path };     // ran off the right shoulder in i frames
    if (forward < 0) return { side: phys.yaw < 0 ? DangerSide.LEFT : DangerSide.RIGHT, forward, crossed, endAcross: across, framesUntilDanger: i, path };       // looped net-BACKWARD — danger on the side he curled toward (yaw<0 = left)
  }
  return { side: DangerSide.NONE, forward: phys.along - state.along, crossed, endAcross: phys.across, framesUntilDanger: Infinity, path };  // survived the whole horizon on-road
}

const MAX_TILT_CORRECTION = 1 * Math.PI / 180;    // the most the rider can work his lean over in a single frame (he has to fight the bike's mass)
const MAX_LOOKAHEAD = 240;                        // how far (frames) the debug overlay projects the chosen lean
const REGULATOR_OMEGA = 0.10;                     // the lateral regulator's pole (per frame): bigger = snappier centring, smaller = gentler
const BRAKE_HORIZON = 150;                        // frames the shoulder brake projects the regulator's closed loop to find the worst excursion
const BRAKE_MAX = 0.08;                           // most the shoulder brake slows him in one frame (m/press^2), so braking is firm but not a jolt
const OVERSHOOT_BUDGET = 0.4;                     // how far past centre the projected steering may weave before we slow — keeps turn-exits from swinging the full road width

// THE STEER DECISION — an O(1) SATURATED-LINEAR REGULATOR, no projection or search. The lateral state is a triple
// integrator (across <- yaw <- tilt <- tilt-step), so we place all three poles at -REGULATOR_OMEGA and clamp the
// tilt-step to +/-MAX_TILT_CORRECTION. He eases toward x* = barely off centre on his OWN side (a stable lane-keeping
// aim). Far off it saturates toward the edge; near the aim it glides in smoothly — no bang-bang chatter, no
// 17k-sim/frame scan. Working it out: with p=across-x*, q=v*yaw, r=v*c*tilt and jerk = -(w^3 p + 3w^2 q + 3w r),
// the tilt-step is jerk/(v*c) = -(3w*tilt + 3w^2*yaw/c + w^3*(across-x*)/(v*c)).
function steerTiltStep(state: RiderPhysics): number {
  const w = REGULATOR_OMEGA, c = YAW_PER_TILT;
  const xStar = state.across >= 0 ? CENTER_LANE_EPSILON : -CENTER_LANE_EPSILON;   // barely off centre, his side
  const vEff = Math.max(state.v, 0.05);                                           // floor v so the position term can't blow up at a near-stop
  const u = -(3 * w * state.tilt + 3 * w * w * state.yaw / c + w * w * w * (state.across - xStar) / (vEff * c));
  return Math.max(-MAX_TILT_CORRECTION, Math.min(MAX_TILT_CORRECTION, u));
}

// Project the rider's REAL closed-loop steering (the regulator, recomputed every frame) at his current speed and
// return: the worst lateral excursion |across| (for road safety) and how far it WEAVES past centre to the side
// opposite where he sits now (for smoothness — this is what blows up coming out of a turn). Honest: same regulator
// + simulateRiderStep he actually runs, not a single held lean.
function regulatorProjection(state: RiderState, horizon: number): { maxAbs: number; overshoot: number } {
  const startSign = state.across >= 0 ? 1 : -1;
  let phys: RiderPhysics = state, maxAbs = Math.abs(state.across), overshoot = 0;
  for (let i = 0; i < horizon; i++) {
    phys = simulateRiderStep(phys, steerTiltStep(phys), 0);   // closed-loop regulator, speed held
    maxAbs = Math.max(maxAbs, Math.abs(phys.across));
    overshoot = Math.max(overshoot, -startSign * phys.across); // crossing to the far side of centre
  }
  return { maxAbs, overshoot };
}

// The debug overlay's data: the arc the rider's CHOSEN lean would trace if held — coloured by the shoulder it would
// run off (RED left / GREEN right / BLUE on-road). The regulator re-decides every frame, so this is a "what if I
// held this step" preview, not his exact future path, but it's the same simulateRiderStep so it can't lie about the
// immediate trajectory.
export interface LeanCandidate { path: { along: number; across: number }[]; side: DangerSide }
export interface LeanCandidates { candidates: LeanCandidate[]; chosen: number }
export function leanCandidates(state: RiderState, seg: RoadSegment): LeanCandidates {
  const sim = simulateRiderPath(state, seg, steerTiltStep(state), MAX_LOOKAHEAD);
  return { candidates: [{ path: sim.path, side: sim.side }], chosen: 0 };
}
