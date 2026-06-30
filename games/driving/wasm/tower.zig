//! tower — the radio tower beyond each intersection (and mid-way down a long
//! segment): a tall square-base lattice pyramid of metal rods, tapering to an apex
//! with a pink beacon. The owner (render, via the world) places it; this module only
//! renders. Mirrors tower.ts.
//!
//! This is the FLAT form only — the four faces drawn as a billboard lattice, which is
//! what tower.ts draws beyond TOWER_NEAR_DIST. We diverge from TS in ONE way: every rod
//! stays a 3D segment and is near-clipped before projecting (see bar3d), rather than
//! interpolating already-projected screen points. TS could skip this because it only used
//! the flat path for FAR towers, where nothing straddles the eye plane; here the flat path
//! runs at all distances, so a tower you pass close would otherwise streak a rod clear
//! across the viewport. The criss-crossing flat lattice reads as 3D as you pass it, so the
//! near perspective lattice stays deferred. The apex beacon
//! BLINKS on the step clock (a pure function of it, so it freezes on pause and runs
//! backwards on reverse), each tower phase-offset so they don't pulse in unison. Local
//! ground curvature (EARTH_RADIUS) sinks a far tower so its base meets the horizon.

const std = @import("std");
const camera = @import("camera.zig");
const geom = @import("geom.zig");
const paint = @import("paint.zig");

const TOWER_HEIGHT: f32 = 80; // apex height (m)
const TOWER_HALF: f32 = 6; // half the 12m square base edge
const STAGE_HEIGHT: f32 = 20; // a cross-beam ring every this many metres (20/40/60)
const BRACE_STAGES: usize = 2; // X-braces only on the bottom this-many stages
const ROD_HALF: f32 = 0.12;
const ROD_W: f32 = ROD_HALF * 2;
const TOWER_METAL: u32 = 0x9aa0a8;
const EARTH_RADIUS: f32 = 20000; // local ground bulge (towers only — stronger than the road's)
const BEACON_RADIUS: f32 = 3.0;
const BEACON_COLOR: u32 = 0xff2fe6;
const BEACON_PERIOD: f32 = 120; // frames for a full invisible → bright → invisible blink

/// beaconOffsetFor spreads each tower's blink phase so they don't pulse in unison: 37 is
/// coprime to the 120-frame period, so successive owners land on distinct offsets.
/// Mirrors beaconOffsetFor in tower.ts (keyed off the owning segment).
pub fn beaconOffsetFor(n: usize) f32 {
    return @floatFromInt((n * 37) % 120);
}

// the beacon's brightness (0 = invisible at the cycle ends, 1 = full at the middle) for a
// phase = step + the tower's offset. Pure function of the clock. Mirrors beaconBrightness.
fn beaconBrightness(phase: f32) f32 {
    const wrapped = @mod(@mod(phase, BEACON_PERIOD) + BEACON_PERIOD, BEACON_PERIOD);
    return (1.0 - @cos(2.0 * std.math.pi * wrapped / BEACON_PERIOD)) / 2.0;
}

// the square's four base corners, in half-base units, before the yaw.
const CORNERS = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };

/// baseCornerAX returns base corner k's position in the owning segment's BL frame
/// (`a` along, `x` across-from-left), given the tower's base centre + yaw. The caller
/// maps it into the rider frame. (At the apex the square shrinks to a point at the
/// centre, so the apex is just map(a0, x0) at TOWER_HEIGHT — no helper needed.)
pub fn baseCornerAX(k: usize, a0: f32, x0: f32, yaw: f32) geom.AX {
    const du = CORNERS[k][0] * TOWER_HALF;
    const dv = CORNERS[k][1] * TOWER_HALF;
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    const ru = du * cy - dv * sy;
    const rv = du * sy + dv * cy;
    return .{ .a = a0 + rv, .x = x0 + ru };
}

fn groundDrop(p: geom.RiderPt) f32 {
    return (p.right * p.right + p.forward * p.forward) / (2.0 * EARTH_RADIUS);
}

fn lerp3(a: geom.Vec3, b: geom.Vec3, t: f32) geom.Vec3 {
    return .{
        .right = a.right + (b.right - a.right) * t,
        .forward = a.forward + (b.forward - a.forward) * t,
        .height = a.height + (b.height - a.height) * t,
    };
}

// the 3D position of cross-section corner k at world height h, lowered by the ground
// drop: the square shrinks linearly toward the apex at the centre, so it's a base→centre
// lerp by h/HEIGHT. (The corner stays a 3D point so each rod can be near-clipped before
// projecting — see bar3d.)
fn cornerAt(base: [4]geom.RiderPt, center: geom.RiderPt, k: usize, h: f32, drop: f32) geom.Vec3 {
    const t = h / TOWER_HEIGHT;
    return .{
        .right = base[k].right + (center.right - base[k].right) * t,
        .forward = base[k].forward + (center.forward - base[k].forward) * t,
        .height = h - drop,
    };
}

// a thick screen-space line as a filled quad of width wpx.
fn bar(a: camera.ScreenPt, b: camera.ScreenPt, wpx: f32) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    var len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-4) len = 1;
    const ox = -dy / len * wpx / 2.0;
    const oy = dx / len * wpx / 2.0;
    const pts = [_]camera.ScreenPt{
        .{ .x = a.x + ox, .y = a.y + oy },
        .{ .x = b.x + ox, .y = b.y + oy },
        .{ .x = b.x - ox, .y = b.y - oy },
        .{ .x = a.x - ox, .y = a.y - oy },
    };
    paint.pushPoly(TOWER_METAL, &pts);
}

// one rod, near-clipped: a 3D segment a→b clipped to forward >= NEAR before projecting,
// so a rod straddling the eye plane (a tower you're passing close) can't fling a quad
// clear across the viewport. Both ends behind → skip; one behind → pull it to the near
// plane. (The flat path is used at ALL distances here — TS reserved it for far towers,
// where nothing straddles NEAR, so it never needed this.)
fn bar3d(a: geom.Vec3, b: geom.Vec3, wpx: f32, cam_focal: f32) void {
    var pa = a;
    var pb = b;
    const a_in = pa.forward >= camera.NEAR;
    const b_in = pb.forward >= camera.NEAR;
    if (!a_in and !b_in) return;
    if (a_in != b_in) {
        const f = (camera.NEAR - pa.forward) / (pb.forward - pa.forward);
        const mid = lerp3(pa, pb, f);
        if (a_in) pb = mid else pa = mid;
    }
    bar(camera.project(pa, cam_focal), camera.project(pb, cam_focal), wpx);
}

/// drawFlat renders a tower given its four base corners + base centre already mapped
/// into the rider frame. Each rod is a 3D segment (cross-section corners shrinking to the
/// apex) that bar3d near-clips before projecting and drawing as a thick screen line — so a
/// tower you pass close can't streak a rod across the screen. Sinks the tower by the local
/// ground drop. `beacon_phase` is step + this tower's offset — the apex beacon blinks on it.
pub fn drawFlat(base: [4]geom.RiderPt, center: geom.RiderPt, cam_focal: f32, beacon_phase: f32) void {
    if (center.forward < camera.NEAR) return;
    const drop = groundDrop(center);
    if (drop >= TOWER_HEIGHT) return; // sunk below the horizon
    const clip_h = drop;

    const apex = geom.Vec3{ .right = center.right, .forward = center.forward, .height = TOWER_HEIGHT - drop };

    // rod width in px at this depth (project two ground points 1m apart).
    const px1 = camera.project(.{ .right = 1, .forward = center.forward, .height = 0 }, cam_focal).x;
    const px0 = camera.project(.{ .right = 0, .forward = center.forward, .height = 0 }, cam_focal).x;
    const wpx = ROD_W * (px1 - px0);

    // four legs (from the drop height up to the apex).
    var k: usize = 0;
    while (k < 4) : (k += 1) bar3d(cornerAt(base, center, k, clip_h, drop), apex, wpx, cam_focal);

    // cross-beam rings at 20/40/60 (above the drop).
    var h: f32 = STAGE_HEIGHT;
    while (h < TOWER_HEIGHT) : (h += STAGE_HEIGHT) {
        if (h <= clip_h) continue;
        k = 0;
        while (k < 4) : (k += 1) bar3d(cornerAt(base, center, k, h, drop), cornerAt(base, center, (k + 1) % 4, h, drop), wpx, cam_focal);
    }

    // X-braces on the bottom stages, each diagonal clipped at the drop height.
    var stage: usize = 0;
    while (stage < BRACE_STAGES) : (stage += 1) {
        const lo = @as(f32, @floatFromInt(stage)) * STAGE_HEIGHT;
        const hi = lo + STAGE_HEIGHT;
        if (hi <= clip_h) continue;
        const f = (@max(lo, clip_h) - lo) / STAGE_HEIGHT;
        k = 0;
        while (k < 4) : (k += 1) {
            const j = (k + 1) % 4;
            bar3d(lerp3(cornerAt(base, center, k, lo, drop), cornerAt(base, center, j, hi, drop), f), cornerAt(base, center, j, hi, drop), wpx, cam_focal);
            bar3d(lerp3(cornerAt(base, center, j, lo, drop), cornerAt(base, center, k, hi, drop), f), cornerAt(base, center, k, hi, drop), wpx, cam_focal);
        }
    }

    // the apex is in front (center.forward >= NEAR, checked above), so project it directly.
    drawBeacon(camera.project(apex, cam_focal), center.forward, cam_focal, beaconBrightness(beacon_phase));
}

// the apex beacon: a pink disc whose SIZE scales with distance but whose BRIGHTNESS is
// the blink alpha — a depthless glow composited over whatever's behind. Skips the
// invisible part of the cycle (and a sub-pixel disc). Mirrors drawBeacon in tower.ts.
fn drawBeacon(apex_s: camera.ScreenPt, forward: f32, cam_focal: f32, bright: f32) void {
    if (bright < 0.02) return;
    const px1 = camera.project(.{ .right = 1, .forward = forward, .height = 0 }, cam_focal).x;
    const px0 = camera.project(.{ .right = 0, .forward = forward, .height = 0 }, cam_focal).x;
    const r = BEACON_RADIUS * (px1 - px0);
    if (r < 0.5) return;
    paint.pushBeacon(BEACON_COLOR, apex_s.x, apex_s.y, r, bright);
}
