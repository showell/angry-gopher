//! truck — the dark-blue truck the rider chases down the route. Faithful port of truck.ts.
//!
//! MOTION (a tiny deterministic simulation, advanced one step per rider frame and kept in a history ring
//! alongside the rider's so it scrubs cleanly on pause/reverse): it keeps to a SCHEDULE — its lead over the
//! rider lerps from START_AHEAD down to FINISH_LEAD across the whole course, so the chase tightens toward a
//! photo finish. When BEHIND schedule it floors the throttle (capped) to claw back; approaching a turn it
//! BRAKES to a cautious entry speed, then accelerates out; AHEAD of schedule on a straight it cruises. Its
//! speed is NEVER tied to the rider's speed — only to those rules (the schedule reads the rider's DISTANCE,
//! not his speed). Brake lights show only while it's actually slowing.
//!
//! DRAWING: v1 is a placeholder blue dot (a billboard sized by distance). The real trailer+cab box, tires,
//! brake lights, and headlight wedges come next — see truck.ts buildTruck.

const std = @import("std");
const camera = @import("camera.zig");
const world = @import("world.zig");
const rider = @import("rider.zig");
const paint = @import("paint.zig");

// ---- the chase (truck.ts) ----
const START_AHEAD: f32 = 500; // metres ahead of the rider at the start
const FINISH_LEAD: f32 = 100; // the lead the schedule lerps DOWN to by the course end (not 0 — a photo finish)
const TRUCK_TURN_CAUTION: f32 = 0.8; // takes each corner at this fraction of the rider's safe turn speed
const TRUCK_BRAKE_DISTANCE: f32 = rider.APPROACH_INTERSECTION_DIST; // brakes over the same distance the rider does
const TRUCK_CHASE_ACCEL: f32 = 1.1 * rider.A_ACCEL; // behind-schedule accel — 10% faster than the rider
const TRUCK_MAX_V: f32 = 1.1 * rider.V_MAX; // top speed — 10% over the rider's, but bounded

const HEIGHT: f32 = 3.6; // trailer + cab height (for the billboard size)
const BODY: u32 = 0x1c2e66; // dark blue

// The truck's own state: how far it has driven along the route, its speed, and whether it's slowing this
// frame (brake lights show only then).
pub const State = struct { pos: f32, v: f32, braking: bool };

// The truck at the start: START_AHEAD down the road, idling at the base speed, not braking.
pub fn initial() State {
    return .{ .pos = START_AHEAD, .v = rider.V_BASE, .braking = false };
}

// The next real TURN ahead of `pos`: how far to it, and the rider's safe speed for it. Past the course end
// there is no turn to brake for → {inf, 0}. Mirrors nextTurn in truck.ts (the route's segments are in order).
fn nextTurn(w: *const world.World, pos: f32) struct { dist: f32, v_turn: f32 } {
    var cum: f32 = 0;
    var i: usize = 0;
    while (i < w.n_segments) : (i += 1) {
        cum += w.segments[i].length;
        if (pos < cum) return .{ .dist = cum - pos, .v_turn = rider.turnSpeed(w.segments[i].exit_angle) };
    }
    return .{ .dist = std.math.inf(f32), .v_turn = 0 };
}

// Advance the truck one rider-frame. `rider_dist` is how far the rider has now driven (routeDistance); `l`
// is the course length. Pure. Three rules, nothing else: brake before a turn / accelerate when behind
// schedule / cruise when ahead. Mirrors nextTruck in truck.ts.
pub fn next(truck: State, rider_dist: f32, w: *const world.World, l: f32) State {
    const scheduled = rider_dist + FINISH_LEAD + (START_AHEAD - FINISH_LEAD) * (1.0 - rider_dist / l); // where it "should" be
    const turn = nextTurn(w, truck.pos);
    const turn_target = turn.v_turn * TRUCK_TURN_CAUTION; // the speed it aims to hit the corner at
    var v = truck.v;
    var braking = false;
    if (turn.dist <= TRUCK_BRAKE_DISTANCE) {
        // kinematic brake that arrives at the turn at turn_target (a = (vEnd² - v²)/2d), recomputed each frame.
        const a = if (turn.dist > 1e-6) (turn_target * turn_target - v * v) / (2.0 * turn.dist) else 0;
        v = @max(turn_target, v + a);
        braking = v < truck.v; // lit only while actually slowing
    } else if (truck.pos < scheduled) {
        v = @min(TRUCK_MAX_V, v + TRUCK_CHASE_ACCEL); // behind schedule: accelerate, capped
    } // ahead of schedule, not braking: cruise (hold v)
    return .{ .pos = truck.pos + v, .v = v, .braking = braking };
}

// ---- drawing (v1: a blue dot) ----

// draw the truck as a placeholder billboard at rider-relative (right, forward): a blue square sized by the
// projected truck height, so it sits in the scene at the right depth/scale. The real body replaces this.
pub fn drawDot(right: f32, forward: f32, cam_focal: f32) void {
    const base = camera.project(.{ .right = right, .forward = forward, .height = 0 }, cam_focal);
    const top = camera.project(.{ .right = right, .forward = forward, .height = HEIGHT }, cam_focal);
    const h = base.y - top.y;
    if (h < 1.0) return;
    const half = h / 2.0;
    const cx = base.x;
    const cy = base.y - half; // centre the square on the body
    const pts = [_]camera.ScreenPt{
        .{ .x = cx - half, .y = cy - half },
        .{ .x = cx + half, .y = cy - half },
        .{ .x = cx + half, .y = cy + half },
        .{ .x = cx - half, .y = cy + half },
    };
    paint.pushPoly(BODY, &pts);
}
