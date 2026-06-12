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
import { simulateRiderStep } from './bike_physics.ts';
import type { RiderPhysics } from './bike_physics.ts';

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
const TURN_DANGER_STEPS = 2000;            // STEERING look-ahead (a hard cap; the loop almost always ends earlier on danger or crossing MIN_FORWARD_PROGRESS). Big enough that the projection reaches the road's end even when he's crawling.
const MIN_FORWARD_PROGRESS = 25;            // scoring distance (m): a projected lean that survives this far without running off counts as "good enough" — its forward score is pinned here so survivors tie and the cross-centre / least-lean tiebreak decides. Shorter = more leans tie = more averse to hugging a side (but can oscillate)
const TILT_HOLD = 2 * Math.PI / 180;        // he only adds throttle while leaned LESS than this — accelerating mid-lean makes the constant-v danger projection lie and reads as jitter
const BRAKE_DECAY = 40;                    // shoulder brake fudge factor (frames): the kinematic decel decays exp(-N/this) as frames-until-danger N grows, so he under-brakes for far-off danger (trusting he'll steer out) and only fully brakes when it's imminent
const ASYMPTOTE_TUNING = 0.30;              // the lean search aims to END this fraction of his CURRENT offset from centre (0.30 = ~3x closer each lookahead) — an asymptotic glide to the middle instead of overshooting and oscillating
const CENTER_LANE_EPSILON = 0.04;           // once he's THIS close to centre, stop chasing the exact middle — aim for the band EDGE (+/-this) on the side he's on, a stable target he can hold instead of twitching after a zero he can't physically keep (and off the start line, +this, so he pulls away at a slight angle)

// (The snap-to-centre constants TILT_SNAP / YAW_EPSILON were removed with the snaps. AIMING_DISTANCE / aimYawFor
// are BACK — not as a snap, but as the heading the PATH PROJECTION straightens toward: the rider aims his heading
// at the lane centre and flips his lean the moment he reaches that aim, so the projected arc self-arrests instead
// of leaning ever harder.)
const AIMING_DISTANCE = 100;   // the rider aims his heading at the lane centre this far ahead (m)
function aimYawFor(across: number): number {
  return Math.atan2(-across, AIMING_DISTANCE);   // heading that points at the lane centre from lateral offset `across` (0 when centred)
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

// DECIDE — purely the rider's brain: it picks his two controls for the frame and NOTHING else (no physics, no
// new position). The LEAN: he BINARY-SEARCHES the lean (bestTiltCorrection) for the one whose projected path
// stays on the road and ends nearest the asymptotic target — the tilt-step is the change from his current lean.
// The FORWARD: with that chosen lean, getForwardAccelDecel reads off his accel.
// (Snaps are OFF for now — we tolerate the resulting oscillation until the decision/physics break is clean.)
// getNextRiderState EXECUTES these controls through the physics; riderDebug reads them for the HUD.
function decide(state: RiderState, seg: RoadSegment, world: World): RiderDecision {
  const tiltStep = searchLean(state, seg).step;
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

  // Brake for the road edge using the rider's ACTUAL simulated path: project from his current state RE-APPLYING
  // the tilt-step he just chose, so the first projected frame IS his real next move and the rest assume he keeps
  // working the lean the same way — the brake has FAITH the bike will turn (and keep turning), instead of the old
  // straight-line shoulderDistance. If the path runs off a shoulder in N frames, kinematically slow to arrive
  // there at v=0 (a = -v / 2N — stop within the distance he'd cover in N frames). If the path is clear, no brake.
  const sim = simulateRiderPath(state, seg, tiltStep);
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


// Project his ARC forward working the lean over by a constant-MAGNITUDE tiltStep each frame — its sign FLIPS EVERY
// time his heading crosses the lane-centre aim, so instead of leaning ever harder (which oversteered and ran every
// probe off the road) he leans IN, straightens, overshoots, leans back... the projected path can oscillate wildly,
// but he NEVER actually drives it — only scores it. Speed held constant. Score how it PLAYS OUT; runs until one of:
//   • it runs off a shoulder           -> { side: LEFT|RIGHT, forward = progress at the hit }   (a bad lean)
//   • it goes net-BACKWARD (forward<0) -> the disaster case; the negative forward sinks it in the ranking
//   • it clears MIN_FORWARD_PROGRESS   -> { side: NONE, forward = MIN_FORWARD_PROGRESS exactly }  (a good lean)
// `forward` is the score (more is better) and is pinned to EXACTLY MIN_FORWARD_PROGRESS for every surviving
// path so they tie cleanly and the caller can tiebreak. `crossed` = did the arc cross the centre line. The
// shoulder boundary on each side is the WORSE of the inset edge (STRAIGHTEN_MARGIN inside the real shoulder)
// and where the rider ALREADY sits, so a path is only "off" if it pushes him FURTHER toward a shoulder than he
// already is — not for merely starting near the edge.
export function simulateRiderPath(state: RiderState, seg: RoadSegment, tiltStep: number): PathSim {
  const insetHw = seg.width / 2 - STRAIGHTEN_MARGIN;
  const rightBound = Math.max(insetHw, state.across);
  const leftBound = Math.min(-insetHw, state.across);
  const startSide = Math.sign(state.across);                                // which side of centre he starts on
  const path: { along: number; across: number }[] = [];                    // the arc actually walked — returned so the overlay matches exactly
  let phys: RiderPhysics = state, crossed = false;                          // step the SAME dumb physics forward, speed held
  let step = tiltStep;                                                      // constant MAGNITUDE; its sign flips EACH time he crosses the aim
  let prevToAim = state.yaw - aimYawFor(state.across);                      // signed gap from the centre-aim heading; a sign change = he crossed it
  for (let i = 0; i < TURN_DANGER_STEPS; i++) {
    phys = simulateRiderStep(phys, step, 0);                               // work the lean over by step each frame; zero acceleration
    // flip the lean EACH time his heading OVERSHOOTS the lane-centre aim in the step's OWN turn direction (sign of
    // toAim at the crossing == sign of step). Gating on the step's direction is what stops a residual lean — one
    // opposite to the commanded step — from driving the heading across the aim and triggering a premature flip
    // (which turned every "lean left" probe into a "lean right" path). The path then oscillates (never driven).
    const toAim = phys.yaw - aimYawFor(phys.across);
    if (prevToAim !== 0 && Math.sign(toAim) !== Math.sign(prevToAim) && Math.sign(toAim) === Math.sign(step)) step = -step;
    prevToAim = toAim;
    const across = phys.across, forward = phys.along - state.along;
    path.push({ along: phys.along, across });                               // record this projected point (last one IS the exit point)
    if (across * startSide < 0) crossed = true;                            // the arc has made it across centre
    if (across < leftBound) return { side: DangerSide.LEFT, forward: Math.min(forward, MIN_FORWARD_PROGRESS), crossed, endAcross: across, framesUntilDanger: i, path };       // ran off the left shoulder in i frames (forward CAPPED — a path off the road must never out-score one that cleared)
    if (across > rightBound) return { side: DangerSide.RIGHT, forward: Math.min(forward, MIN_FORWARD_PROGRESS), crossed, endAcross: across, framesUntilDanger: i, path };     // ran off the right shoulder in i frames (forward CAPPED)
    if (forward < 0) return { side: phys.yaw < 0 ? DangerSide.LEFT : DangerSide.RIGHT, forward, crossed, endAcross: across, framesUntilDanger: i, path };       // looped net-BACKWARD — report it as danger on the side he curled toward (yaw<0 = left), so the search treats the loop as the hazard it is (forward<0 keeps it ranked a disaster)
    if (forward >= MIN_FORWARD_PROGRESS) return { side: DangerSide.NONE, forward: MIN_FORWARD_PROGRESS, crossed, endAcross: across, framesUntilDanger: Infinity, path };  // cleared (no shoulder danger)
  }
  return { side: DangerSide.NONE, forward: phys.along - state.along, crossed, endAcross: phys.across, framesUntilDanger: Infinity, path };
}

const MAX_TILT_CORRECTION = 1 * Math.PI / 180;    // the most the rider can work his lean over in a single frame (he has to fight the bike's mass)
const LEAN_SEARCH_ITERS = 12;                     // binary-search probes over [-MAX, +MAX]: each halves the interval, so 12 -> 2*MAX/2^12 ~= 0.0005deg precision in 12 path sims

// Should the best tilt-STEP be MORE to the RIGHT than the one that produced this path? YES if the path runs off
// the LEFT (he needs to lean righter to get back on the road) or stays on-road but ends LEFT of the target (lean
// right to reach it); NO if it runs off the RIGHT or ends right of the target. As the step sweeps left->right the
// projected (ramping-lean) path sweeps monotonically (off-LEFT -> a band that stays ON THE ROAD with its end
// sliding rightward -> off-RIGHT), so this answer flips exactly ONCE across the range — all the bisection needs.
function wantMoreRight(sim: PathSim, target: number): boolean {
  if (sim.side === DangerSide.LEFT) return true;
  if (sim.side === DangerSide.RIGHT) return false;
  return sim.endAcross < target;                  // on-road: lean further right only if it still ends short of the target
}

// THE LEAN SEARCH — a binary search for the per-frame tilt-STEP whose projected path (that step re-applied every
// frame, so the lean ramps) stays on the road and ENDS CLOSEST to the ASYMPTOTIC TARGET (`target` = a fraction of
// his current offset, so he glides toward centre instead of overshooting). The single flip of wantMoreRight is the
// pivot: keep the half that still wants more right lean. We record EVERY probe so the debug overlay can draw the
// exact paths the search evaluated — no parallel re-sampling.
interface LeanSearch { step: number; probes: PathSim[] }
function searchLean(state: RiderState, seg: RoadSegment): LeanSearch {
  const target = Math.abs(state.across) < CENTER_LANE_EPSILON
    ? (state.across >= 0 ? CENTER_LANE_EPSILON : -CENTER_LANE_EPSILON)   // near centre: aim for the band edge on his side (a stable target), not the exact zero
    : state.across * ASYMPTOTE_TUNING;
  let lo = -MAX_TILT_CORRECTION;                   // ramp the lean LEFT  as hard as one frame allows (-> off the left shoulder)
  let hi = MAX_TILT_CORRECTION;                    // ramp the lean RIGHT as hard as one frame allows (-> off the right shoulder)
  const probes: PathSim[] = [];
  for (let i = 0; i < LEAN_SEARCH_ITERS; i++) {
    const mid = (lo + hi) / 2;
    const sim = simulateRiderPath(state, seg, mid);
    probes.push(sim);                              // the actual path this probe walked
    if (wantMoreRight(sim, target)) lo = mid; else hi = mid;
  }
  return { step: (lo + hi) / 2, probes };
}

// The debug overlay's data: the ACTUAL arcs the binary search probed — each coloured by the shoulder it ran off
// (RED left / GREEN right / BLUE on-road), narrowing in as the bisection converges — PLUS the tilt-step it finally
// settled on as the last, highlighted candidate. Every path here is one simulateRiderPath the search really ran,
// so the picture can't disagree with the algorithm.
export interface LeanCandidate { path: { along: number; across: number }[]; side: DangerSide }
export interface LeanCandidates { candidates: LeanCandidate[]; chosen: number }
export function leanCandidates(state: RiderState, seg: RoadSegment): LeanCandidates {
  const search = searchLean(state, seg);
  const candidates: LeanCandidate[] = search.probes.map((p) => ({ path: p.path, side: p.side }));
  const chosen = simulateRiderPath(state, seg, search.step);   // the tilt-step it settled on (the final midpoint)
  candidates.push({ path: chosen.path, side: chosen.side });
  return { candidates, chosen: candidates.length - 1 };
}
