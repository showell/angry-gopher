//! rider — the RIDER: his state and how he decides to move, one frame at a time. A
//! faithful port of rider.ts + bike_physics.ts: the lean BINARY SEARCH (the held
//! lean whose projected arc stays on the road and ends nearest an asymptotic centre
//! target), the forward throttle/brake (accelerate freely, but brake for the corner's
//! safe entry speed and the road shoulder), and the seam transform that re-expresses
//! him in the next segment's frame as he commits to a turn. Pure; no canvas.
//!
//! Deferred (no-ops here, exactly as their TS guards would be with no cats/pigs): the
//! crossing-cat throttle hold, the pig gawk brake, and the view-only gaze. The debug
//! overlay (probe paths / HUD) is also dropped.

const std = @import("std");
const world = @import("world.zig");
const cat = @import("cat.zig");
const gaze = @import("gaze.zig");

// --- physics + decision constants (per-press; YAW_PER_TILT from bike_physics.ts) ---
const YAW_PER_TILT: f32 = 0.1;
pub const MAX_LEAN: f32 = 20.0 * std.math.pi / 180.0; // the route never banks past this; the focal pull-in normalises the lean by it
pub const V_BASE: f32 = 0.3;
pub const A_ACCEL: f32 = 0.010; // pub: the truck claws its lead back at 1.1× this
pub const V_MAX: f32 = 2.5; // pub: the truck caps its top speed off 1.1× this
pub const APPROACH_INTERSECTION_DIST: f32 = 60.0; // pub: the truck brakes over this same distance
const STRAIGHTEN_MARGIN: f32 = 0.05;
const TURN_DANGER_STEPS: usize = 2000;
const MIN_FORWARD_PROGRESS: f32 = 25.0;
const TILT_HOLD: f32 = 2.0 * std.math.pi / 180.0;
const BRAKE_DECAY: f32 = 20.0;
const ASYMPTOTE_TUNING: f32 = 0.30;
const CENTER_LANE_EPSILON: f32 = 0.04;
const MAX_TILT_CORRECTION: f32 = 1.0 * std.math.pi / 180.0;
const LEAN_SEARCH_ITERS: usize = 12;

pub const RiderState = struct {
    segment: usize,
    along: f32,
    across: f32,
    yaw: f32, // heading vs the CURRENT segment (frame-relative; the road geometry reads this)
    v: f32,
    tilt: f32,
    // the bike's ABSOLUTE world heading, integrated continuously. yaw is reset into each
    // segment's frame at a crossing, and north_heading resets to 0 at the loop seam — so
    // north_heading[seg] + yaw JUMPS ~40deg when seg7 loops back to seg0. The backdrop
    // (mountains + sun) reads this instead, which the crossing leaves untouched, so the
    // horizon turns exactly as much as the bike does. (TS has a terminus, never loops, so
    // it had no seam to cross — this field is a port-specific fix for the looping route.)
    heading: f32,
    // the "distracted rider" (gaze.zig), both VIEW-ONLY: gaze_yaw is an extra camera yaw toward the roadside
    // pigs (0 = eyes ahead); focus is the camera's focus-narrowing progress (0 = normal … 1 = fully narrowed)
    // as he gawks. Updated by nextRiderGaze each frame, AFTER the bike moves.
    gaze_yaw: f32,
    focus: f32,
};

pub fn initialRiderState() RiderState {
    return .{ .segment = 0, .along = 0, .across = 0, .yaw = 0, .v = V_BASE, .tilt = 0, .heading = 0, .gaze_yaw = 0, .focus = 0 };
}

// advance the bike one frame: a lean tip + an acceleration, integrated. The rider
// leans FIRST, then that tilt yaws the heading; the new speed along the mid-heading
// moves the position. Mirrors simulateRiderStep in bike_physics.ts.
fn simulateRiderStep(s: RiderState, tilt_step: f32, accel: f32) RiderState {
    const tilt = s.tilt + tilt_step;
    const v = s.v + accel;
    const heading_change = YAW_PER_TILT * tilt;
    const mid = s.yaw + heading_change / 2.0;
    return .{
        .segment = s.segment,
        .tilt = tilt,
        .yaw = s.yaw + heading_change,
        .heading = s.heading + heading_change, // absolute heading turns by the same delta as yaw
        .v = v,
        .along = s.along + v * @cos(mid),
        .across = s.across + v * @sin(mid),
        .gaze_yaw = s.gaze_yaw, // view-only; the gaze step (nextRiderGaze) advances it after the move
        .focus = s.focus,
    };
}

const Side = enum { left, none, right };
const PathSim = struct { side: Side, forward: f32, crossed: bool, end_across: f32, frames: f32 };

fn signf(x: f32) f32 {
    return if (x > 0) 1.0 else if (x < 0) @as(f32, -1.0) else 0.0;
}

// project the held-lean, constant-speed arc forward and score how it plays out: off a
// shoulder (a bad lean), net-backward (disaster), or clearing MIN_FORWARD_PROGRESS (a
// good lean, all pinned to the same forward so survivors tie). Mirrors simulateRiderPath.
fn simulateRiderPath(state: RiderState, seg: world.Segment) PathSim {
    const inset_hw = seg.width / 2.0 - STRAIGHTEN_MARGIN;
    const right_bound = @max(inset_hw, state.across);
    const left_bound = @min(-inset_hw, state.across);
    const start_side = signf(state.across);
    var phys = state;
    var crossed = false;
    var i: usize = 0;
    while (i < TURN_DANGER_STEPS) : (i += 1) {
        phys = simulateRiderStep(phys, 0, 0);
        const across = phys.across;
        const forward = phys.along - state.along;
        if (across * start_side < 0) crossed = true;
        if (across < left_bound) return .{ .side = .left, .forward = @min(forward, MIN_FORWARD_PROGRESS), .crossed = crossed, .end_across = across, .frames = @floatFromInt(i) };
        if (across > right_bound) return .{ .side = .right, .forward = @min(forward, MIN_FORWARD_PROGRESS), .crossed = crossed, .end_across = across, .frames = @floatFromInt(i) };
        if (forward < 0) return .{ .side = .none, .forward = forward, .crossed = crossed, .end_across = across, .frames = 1e9 };
        if (forward >= MIN_FORWARD_PROGRESS) return .{ .side = .none, .forward = MIN_FORWARD_PROGRESS, .crossed = crossed, .end_across = across, .frames = 1e9 };
    }
    return .{ .side = .none, .forward = phys.along - state.along, .crossed = crossed, .end_across = phys.across, .frames = 1e9 };
}

fn wantMoreRight(sim: PathSim, target: f32) bool {
    if (sim.side == .left) return true;
    if (sim.side == .right) return false;
    return sim.end_across < target;
}

// binary-search the held lean whose arc stays on the road and ends closest to the
// asymptotic centre target. Mirrors searchLean/bestTiltCorrection.
fn bestTiltCorrection(state: RiderState, seg: world.Segment) f32 {
    const target = if (@abs(state.across) < CENTER_LANE_EPSILON)
        (if (state.across >= 0) CENTER_LANE_EPSILON else -CENTER_LANE_EPSILON)
    else
        state.across * ASYMPTOTE_TUNING;
    var lo = state.tilt - MAX_TILT_CORRECTION;
    var hi = state.tilt + MAX_TILT_CORRECTION;
    var i: usize = 0;
    while (i < LEAN_SEARCH_ITERS) : (i += 1) {
        const mid = (lo + hi) / 2.0;
        var probe = state;
        probe.tilt = mid;
        if (wantMoreRight(simulateRiderPath(probe, seg), target)) lo = mid else hi = mid;
    }
    return (lo + hi) / 2.0;
}

// the safe entry speed for a turn angle (the SAFE_TURN_SPEED table in intersection.ts;
// every angle on our route is tabulated). pub: the truck aims for a fraction of it.
pub fn turnSpeed(angle_rad: f32) f32 {
    const deg = @round(angle_rad * 180.0 / std.math.pi);
    if (deg == 15) return 1.297;
    if (deg == 20) return 0.840;
    if (deg == 30) return 0.461;
    if (deg == 50) return 0.222;
    if (deg == 70) return 0.139;
    if (deg == 80) return 0.117;
    return 0.222; // not reached on this route
}

// the forward throttle/brake: accelerate (only while near-upright), but take the most
// restrictive brake — reach the corner's entry speed by the commit point, and don't
// run off the shoulder (decayed kinematic stop). Cat/pig brakes deferred. Mirrors
// getForwardAccelDecel.
fn getForwardAccelDecel(state: RiderState, seg: world.Segment) f32 {
    const leaned = @abs(state.tilt) >= TILT_HOLD;
    var a: f32 = if (leaned) 0 else A_ACCEL;

    const v_end: f32 = if (seg.terminates) 0 else turnSpeed(seg.exit_angle); // brake to a STOP at the finish
    const near = (seg.length - state.along) <= APPROACH_INTERSECTION_DIST;
    if (near) {
        const d = seg.commit_along - state.along;
        const corner_a = if (d <= 1e-6) 0 else (v_end * v_end - state.v * state.v) / (2.0 * d);
        if (corner_a < a) a = corner_a;
    }

    // hold the throttle for a crossing cat: while it's in its danger window he stops CLOSING on it (a→0),
    // but never brakes — he just doesn't accelerate into it. Coasting in slows his approach, so he reaches
    // the long final segment later (more time for the sunset). Mirrors the AVOID_CAT gate. Placed after the
    // corner brake, before the shoulder brake — exactly rider.ts's order.
    if (seg.has_cat and a > 0 and cat.inDanger(seg.cat.along - state.along, state.v)) a = 0;

    // ease down to a slow gawking speed for the roadside pigs (the gaze distraction's one reach into the
    // motion); gaze.pigGazeBrake owns the trigger + the slow speed — fold it into the min-of-brakes.
    if (gaze.pigGazeBrake(state, seg)) |pig_a| {
        if (pig_a < a) a = pig_a;
    }

    const sim = simulateRiderPath(state, seg);
    if (sim.side != .none) {
        const n = sim.frames;
        const shoulder_a = -state.v / (2.0 * @max(n, 1.0)) * @exp(-n / BRAKE_DECAY);
        if (shoulder_a < a) a = shoulder_a;
    }

    var v = state.v + a;
    if (v > V_MAX) v = V_MAX;
    if (v < 0) v = 0;
    // don't crawl below the corner's entry speed approaching it — UNLESS he's gawking at the pigs, where
    // staying at the slow gawk speed (taking the corner slow) beats snapping back up (he never re-accelerates).
    if (near and v < v_end and !gaze.gawkEngaged(state, seg)) v = v_end;
    return v - state.v;
}

const Decision = struct { tilt_step: f32, accel: f32 };

fn decide(state: RiderState, seg: world.Segment) Decision {
    const tilt_step = bestTiltCorrection(state, seg) - state.tilt;
    var leaned = state;
    leaned.tilt = state.tilt + tilt_step;
    return .{ .tilt_step = tilt_step, .accel = getForwardAccelDecel(leaned, seg) };
}

// re-express the rider onto the next segment as he commits to the turn: same physical
// point, read in the next frame; keeps speed + lean; heading rotates by the turn.
// Mirrors riderStateForNextSegment.
fn riderStateForNextSegment(rs: RiderState, w: *const world.World) RiderState {
    const seg = w.segments[rs.segment];
    const hw = seg.width / 2.0;
    const theta = seg.exit_angle;
    const sgn: f32 = if (seg.exit_right) 1.0 else -1.0;
    const c = @cos(theta);
    const s = @sin(theta);
    const da = rs.along - (seg.length + hw * s);
    const dx = rs.across - sgn * hw * (1.0 - c);
    return .{
        .segment = seg.exit_to,
        .along = c * da + sgn * s * dx,
        .across = -sgn * s * da + c * dx,
        .yaw = rs.yaw - sgn * theta,
        .heading = rs.heading, // unchanged: the crossing only re-expresses the SAME bearing in the next frame
        .v = rs.v,
        .tilt = rs.tilt,
        // eyes back on the road across the seam (the next frame's gaze step re-derives the turn from the new
        // segment); the focus CARRIES, so its slow re-widen keeps easing out smoothly instead of snapping open.
        .gaze_yaw = 0,
        .focus = rs.focus,
    };
}

/// getNextRiderState advances the bike one frame: decide the controls, run them
/// through the physics, then resolve the road graph by POSITION — commit to the next
/// segment the moment his real (along, across) is within it. The route loops, so
/// there is no terminus stop. Mirrors getNextRiderState.
pub fn getNextRiderState(state: RiderState, w: *const world.World) RiderState {
    const seg = w.segments[state.segment];
    const dec = decide(state, seg);
    const moved = simulateRiderStep(state, dec.tilt_step, dec.accel);
    var resolved = moved;
    if (seg.terminates) {
        // the finish line: no segment leads out, so don't re-express him forward — clamp him to the end and
        // stop. He brakes toward v=0 at the line (v_end=0); snap him there once he's crept to the end OR
        // slowed to a crawl in the braking zone, so the kinematic brake can't Zeno-stall him a hair short
        // (leaving him stopped forever, never "finished"). Mirrors riderFinished in rider.ts.
        const in_finish_zone = (seg.length - resolved.along) < APPROACH_INTERSECTION_DIST;
        if (resolved.along >= seg.length or (in_finish_zone and resolved.v < 0.1)) {
            resolved.along = seg.length;
            resolved.v = 0;
        }
    } else {
        const on_next = riderStateForNextSegment(moved, w);
        if (@abs(on_next.across) < w.segments[seg.exit_to].width / 2.0) resolved = on_next;
    }
    // the gaze is its own step, run AFTER the bike has moved (it reads the resolved segment + position):
    // swivel his head toward the pigs / back to the road and advance the focus. Mirrors the caller running
    // nextRiderGaze right after getNextRiderState in main.ts.
    return gaze.nextRiderGaze(resolved, w);
}

/// isFinished: the rider has reached the terminus end and stopped — the journey is over (the screensaver
/// resets to the start). Mirrors riderFinished in rider.ts.
pub fn isFinished(s: RiderState, w: *const world.World) bool {
    return w.segments[s.segment].terminates and s.along >= w.segments[s.segment].length;
}
