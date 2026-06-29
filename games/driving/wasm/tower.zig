//! tower — the radio tower beyond each intersection (and mid-way down a long
//! segment): a tall square-base lattice pyramid of metal rods, tapering to an apex
//! with a pink beacon. The owner (render, via the world) places it; this module only
//! renders. Mirrors tower.ts.
//!
//! For now this is the FLAT form only — the four faces projected as a 2D billboard
//! (base corners + apex projected, every ring/brace derived by screen-space lerp),
//! which is exactly what tower.ts draws beyond TOWER_NEAR_DIST. The near 3D-parallax
//! lattice and the step-driven beacon blink are deferred; the beacon is drawn static.
//! Local ground curvature (EARTH_RADIUS) sinks a far tower so its base meets the
//! horizon and its apex pulls down.

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

fn proj(right: f32, forward: f32, h: f32, drop: f32, cam_focal: f32) camera.ScreenPt {
    return camera.project(.{ .right = right, .forward = forward, .height = h - drop }, cam_focal);
}

fn lerp(a: camera.ScreenPt, b: camera.ScreenPt, t: f32) camera.ScreenPt {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

// screen point of corner k at world height h: the cross-section shrinks linearly to
// the apex, so it's just base→apex lerp by h/HEIGHT.
fn ring(base_s: [4]camera.ScreenPt, apex_s: camera.ScreenPt, k: usize, h: f32) camera.ScreenPt {
    return lerp(base_s[k], apex_s, h / TOWER_HEIGHT);
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

/// drawFlat renders a tower given its four base corners + base centre already mapped
/// into the rider frame. Projects the corners + apex, then derives every ring and
/// brace by 2D interpolation. Sinks the tower by the local ground drop.
pub fn drawFlat(base: [4]geom.RiderPt, center: geom.RiderPt, cam_focal: f32) void {
    if (center.forward < camera.NEAR) return;
    const drop = groundDrop(center);
    if (drop >= TOWER_HEIGHT) return; // sunk below the horizon
    const clip_h = drop;

    var base_s: [4]camera.ScreenPt = undefined;
    for (base, 0..) |b, k| base_s[k] = proj(b.right, b.forward, 0, drop, cam_focal);
    const apex_s = proj(center.right, center.forward, TOWER_HEIGHT, drop, cam_focal);

    // rod width in px at this depth (project two ground points 1m apart).
    const px1 = camera.project(.{ .right = 1, .forward = center.forward, .height = 0 }, cam_focal).x;
    const px0 = camera.project(.{ .right = 0, .forward = center.forward, .height = 0 }, cam_focal).x;
    const wpx = ROD_W * (px1 - px0);

    // four legs (from the drop height up to the apex).
    var k: usize = 0;
    while (k < 4) : (k += 1) bar(ring(base_s, apex_s, k, clip_h), apex_s, wpx);

    // cross-beam rings at 20/40/60 (above the drop).
    var h: f32 = STAGE_HEIGHT;
    while (h < TOWER_HEIGHT) : (h += STAGE_HEIGHT) {
        if (h <= clip_h) continue;
        k = 0;
        while (k < 4) : (k += 1) bar(ring(base_s, apex_s, k, h), ring(base_s, apex_s, (k + 1) % 4, h), wpx);
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
            bar(lerp(ring(base_s, apex_s, k, lo), ring(base_s, apex_s, j, hi), f), ring(base_s, apex_s, j, hi), wpx);
            bar(lerp(ring(base_s, apex_s, j, lo), ring(base_s, apex_s, k, hi), f), ring(base_s, apex_s, k, hi), wpx);
        }
    }

    drawBeacon(apex_s, center.forward, cam_focal);
}

// the apex beacon: a pink disc, size scaling with distance. Static for now (the
// step-driven blink + alpha glow ride the deferred animation clock).
fn drawBeacon(apex_s: camera.ScreenPt, forward: f32, cam_focal: f32) void {
    const px1 = camera.project(.{ .right = 1, .forward = forward, .height = 0 }, cam_focal).x;
    const px0 = camera.project(.{ .right = 0, .forward = forward, .height = 0 }, cam_focal).x;
    const r = BEACON_RADIUS * (px1 - px0);
    if (r < 0.5) return;
    var pts: [16]camera.ScreenPt = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / 16.0 * 2.0 * std.math.pi;
        pts[i] = .{ .x = apex_s.x + r * @cos(a), .y = apex_s.y + r * @sin(a) };
    }
    paint.pushPoly(BEACON_COLOR, &pts);
}
