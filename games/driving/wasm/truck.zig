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
const geom = @import("geom.zig");
const world = @import("world.zig");
const rider = @import("rider.zig");
const render = @import("render.zig");
const paint = @import("paint.zig");

// ---- the chase (truck.ts) ----
const START_AHEAD: f32 = 500; // metres ahead of the rider at the start
const FINISH_LEAD: f32 = 100; // the lead the schedule lerps DOWN to by the course end (not 0 — a photo finish)
const TRUCK_TURN_CAUTION: f32 = 0.8; // takes each corner at this fraction of the rider's safe turn speed
const TRUCK_BRAKE_DISTANCE: f32 = rider.APPROACH_INTERSECTION_DIST; // brakes over the same distance the rider does
const TRUCK_CHASE_ACCEL: f32 = 1.1 * rider.A_ACCEL; // behind-schedule accel — 10% faster than the rider
const TRUCK_MAX_V: f32 = 1.1 * rider.V_MAX; // top speed — 10% over the rider's, but bounded

// ---- dimensions (metres) + colours, mirroring truck.ts buildTruck ----
const LENGTH: f32 = 8.4; // trailer length
const WIDTH: f32 = 2.4; // narrower than the 4m lane, so it rounds corners
const HEIGHT: f32 = 3.6; // trailer + cab height
const CAB_LENGTH: f32 = 3.5; // the cab sticks this far out front of the trailer
const CAB_ROOF_FRAC: f32 = 0.3; // the cab roof is this fraction of the cab; the windshield rakes down over the rest
const TIRE_RADIUS: f32 = 0.5;
const TRAILER_BOTTOM: f32 = 2.0 * TIRE_RADIUS + 0.12; // trailer floor, just above the tire tops
const CAB_BOTTOM: f32 = TIRE_RADIUS; // cab floor, at the tire centre line
const TIRE_PAIR_GAP: f32 = 1.2; // centre-to-centre within a tandem pair
const TRAILER_AXLE_INSET: f32 = 1.6; // each trailer tire-pair sits this far in from its end
const CAB_AXLE_FRAC: f32 = 0.55; // the cab's lone tire, this fraction along the cab
const TIRE_SIDES: usize = 16; // polygon approximation of the tire circle

const BODY: u32 = 0x1c2e66; // dark-blue body
const ROOF: u32 = 0x3a52a8; // lighter roof
const SIDE: u32 = 0x152150; // darker sides (so the prism reads as solid)
const BRAKE: u32 = 0xff2a18; // bright-red brake lights, lit only while slowing
const TIRE: u32 = 0x15151a; // near-black

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
        if (pos < cum) {
            if (w.segments[i].terminates) return .{ .dist = std.math.inf(f32), .v_turn = 0 }; // no turn at the finish — cruise in
            return .{ .dist = cum - pos, .v_turn = rider.turnSpeed(w.segments[i].exit_angle) };
        }
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

// ---- drawing: the trailer + cab box and its tires (truck.ts buildTruck) ----
// (Headlight wedges + the brake-light glow halos are DEFERRED — they need alpha/gradient seam tags the
// polygon-only blitter doesn't have yet.)

const Face = struct { color: u32, n: usize, pts: [TIRE_SIDES]geom.Vec3 };

// a body point (segment-local along, x across-from-left, height) mapped into the rider frame and lowered
// onto the curved ground — so the whole box rides the road's fake-horizon curvature. p3 of truck.ts.
fn p3(w: *const world.World, ch: *const render.Chain, pose: render.Pose, d: usize, along: f32, x: f32, h: f32) geom.Vec3 {
    const r = render.at(w, ch, pose, d, along, x);
    return .{ .right = r.right, .forward = r.forward, .height = h - geom.groundDrop(r.right, r.forward) };
}

fn addFace(faces: *[16]Face, nf: *usize, color: u32, pts: []const geom.Vec3) void {
    faces[nf.*].color = color;
    faces[nf.*].n = pts.len;
    for (pts, 0..) |p, i| faces[nf.*].pts[i] = p;
    nf.* += 1;
}

fn avgForward(f: Face) f32 {
    var s: f32 = 0;
    var i: usize = 0;
    while (i < f.n) : (i += 1) s += f.pts[i].forward;
    return s / @as(f32, @floatFromInt(f.n));
}

// near-clip a polygon (rider-frame points carrying height), project it, and push it as a solid fill.
fn fillPoly(color: u32, pts: []const geom.Vec3, cam_focal: f32) void {
    var clipped: [TIRE_SIDES + 2]geom.Vec3 = undefined;
    const m = geom.clipNear(pts, camera.NEAR, &clipped);
    if (m < 3) return;
    var screen: [TIRE_SIDES + 2]camera.ScreenPt = undefined;
    var i: usize = 0;
    while (i < m) : (i += 1) screen[i] = camera.project(clipped[i], cam_focal);
    paint.pushPoly(color, screen[0..m]);
}

// Build the truck box in the frame of chain[d] (centre line x = hw), centred at `center_along`, and draw it
// back-to-front: a TRAILER box hovering over its tires + a lower CAB in front (windshield raking down the
// nose), with round tires at the sides. Faces are painter-sorted by depth so the body occludes itself and
// its far-side tires. Brake-light panels land on the (nearest) rear face when it's slowing.
pub fn drawBody(w: *const world.World, ch: *const render.Chain, pose: render.Pose, d: usize, center_along: f32, hw: f32, braking: bool, cam_focal: f32) void {
    const a0 = center_along - LENGTH / 2.0; // trailer rear (toward us)
    const a1 = center_along + LENGTH / 2.0; // trailer front
    const a2 = a1 + CAB_LENGTH; // cab nose
    const a_roof = a1 + CAB_LENGTH * CAB_ROOF_FRAC; // windshield top
    const xl = hw - WIDTH / 2.0;
    const xr = hw + WIDTH / 2.0;

    var faces: [16]Face = undefined;
    var nf: usize = 0;

    // each SIDE is one silhouette: up the rear, along the roof, down the windshield + nose, back along the
    // lower cab floor, up the step to the higher trailer floor.
    inline for (.{ xl, xr }) |x| {
        const side = [_]geom.Vec3{
            p3(w, ch, pose, d, a0, x, TRAILER_BOTTOM),  p3(w, ch, pose, d, a0, x, HEIGHT),
            p3(w, ch, pose, d, a_roof, x, HEIGHT),      p3(w, ch, pose, d, a2, x, HEIGHT / 2.0),
            p3(w, ch, pose, d, a2, x, CAB_BOTTOM),      p3(w, ch, pose, d, a1, x, CAB_BOTTOM),
            p3(w, ch, pose, d, a1, x, TRAILER_BOTTOM),
        };
        addFace(&faces, &nf, SIDE, &side);
    }
    addFace(&faces, &nf, BODY, &[_]geom.Vec3{ // trailer rear (the face we chase)
        p3(w, ch, pose, d, a0, xl, TRAILER_BOTTOM), p3(w, ch, pose, d, a0, xr, TRAILER_BOTTOM),
        p3(w, ch, pose, d, a0, xr, HEIGHT),         p3(w, ch, pose, d, a0, xl, HEIGHT),
    });
    addFace(&faces, &nf, ROOF, &[_]geom.Vec3{ // flush roof
        p3(w, ch, pose, d, a0, xl, HEIGHT),    p3(w, ch, pose, d, a0, xr, HEIGHT),
        p3(w, ch, pose, d, a_roof, xr, HEIGHT), p3(w, ch, pose, d, a_roof, xl, HEIGHT),
    });
    addFace(&faces, &nf, BODY, &[_]geom.Vec3{ // windshield
        p3(w, ch, pose, d, a_roof, xl, HEIGHT),     p3(w, ch, pose, d, a_roof, xr, HEIGHT),
        p3(w, ch, pose, d, a2, xr, HEIGHT / 2.0),   p3(w, ch, pose, d, a2, xl, HEIGHT / 2.0),
    });
    addFace(&faces, &nf, BODY, &[_]geom.Vec3{ // cab nose
        p3(w, ch, pose, d, a2, xl, HEIGHT / 2.0), p3(w, ch, pose, d, a2, xr, HEIGHT / 2.0),
        p3(w, ch, pose, d, a2, xr, CAB_BOTTOM),   p3(w, ch, pose, d, a2, xl, CAB_BOTTOM),
    });

    // tires: a flat circle in each side plane (no depth). A tandem pair inset from each trailer end + one
    // under the cab, on both sides. They join the face sort so the body occludes their tops.
    const rear_axle = a0 + TRAILER_AXLE_INSET;
    const front_axle = a1 - TRAILER_AXLE_INSET;
    const cab_axle = a1 + CAB_LENGTH * CAB_AXLE_FRAC;
    const axles = [_]f32{ rear_axle - TIRE_PAIR_GAP / 2.0, rear_axle + TIRE_PAIR_GAP / 2.0, front_axle - TIRE_PAIR_GAP / 2.0, front_axle + TIRE_PAIR_GAP / 2.0, cab_axle };
    inline for (.{ xl, xr }) |x| {
        for (axles) |ac| {
            var pts: [TIRE_SIDES]geom.Vec3 = undefined;
            var i: usize = 0;
            while (i < TIRE_SIDES) : (i += 1) {
                const th = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(TIRE_SIDES)) * 2.0 * std.math.pi;
                pts[i] = p3(w, ch, pose, d, ac + TIRE_RADIUS * @cos(th), x, TIRE_RADIUS + TIRE_RADIUS * @sin(th));
            }
            addFace(&faces, &nf, TIRE, &pts);
        }
    }

    // painter's sort: farthest faces first (insertion sort; nf is small).
    var i: usize = 1;
    while (i < nf) : (i += 1) {
        const key = faces[i];
        const kf = avgForward(key);
        var j: usize = i;
        while (j > 0 and avgForward(faces[j - 1]) < kf) : (j -= 1) faces[j] = faces[j - 1];
        faces[j] = key;
    }
    for (faces[0..nf]) |f| fillPoly(f.color, f.pts[0..f.n], cam_focal);

    // the two brake lights: a panel low on the trailer rear, drawn AFTER the body so they land on the
    // (nearest) rear face. Solid red — the soft glow halo is deferred (needs a gradient/alpha seam tag).
    if (braking) {
        const bl = TRAILER_BOTTOM + 0.20 * (HEIGHT - TRAILER_BOTTOM);
        const bh = TRAILER_BOTTOM + 0.50 * (HEIGHT - TRAILER_BOTTOM);
        const lights = [_][2]f32{ .{ xl + 0.10 * WIDTH, xl + 0.36 * WIDTH }, .{ xr - 0.36 * WIDTH, xr - 0.10 * WIDTH } };
        for (lights) |lr| {
            const panel = [_]geom.Vec3{
                p3(w, ch, pose, d, a0, lr[0], bl), p3(w, ch, pose, d, a0, lr[1], bl),
                p3(w, ch, pose, d, a0, lr[1], bh), p3(w, ch, pose, d, a0, lr[0], bh),
            };
            fillPoly(BRAKE, &panel, cam_focal);
        }
    }
}
