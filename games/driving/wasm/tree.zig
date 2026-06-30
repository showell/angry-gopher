//! tree — a roadside conifer. One draw() with two independent detail axes the renderer sets
//! per tree (they matter at different ranges):
//!   • TRUNK: a round-shaded cylinder (only the nearest few trees — trunk shading reads only
//!     up close) vs a flat bar.
//!   • CROWN: eight 3D cone tiers (near) vs eight flat triangles (far). A cone is a base
//!     circle of world points (each at its own depth) plus the apex, projected and filled to
//!     its convex-hull silhouette, so the near rim is genuinely nearer and foreshortens. The
//!     crown is SOLID either way — its roundness is the SHAPE, not lighting, which keeps it
//!     uniform (no shaded↔solid pop) across the tree line, since crowns are seen far out.
//! Descends from drawTree / drawTreeNear / tierCone / convexHull in tree.ts.

const std = @import("std");
const camera = @import("camera.zig");
const paint = @import("paint.zig");

const TRUNK: u32 = 0x5a3e22;

// the eight crown tiers as fractions of the foliage span: apex (TOP) + base (BOT)
// height, and base half-width (WIDE). Narrow at top, widest at the bottom.
const TIER_TOP = [_]f32{ 0.0, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70 };
const TIER_BOT = [_]f32{ 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.0 };
const TIER_WIDE = [_]f32{ 0.35, 0.44, 0.53, 0.63, 0.72, 0.81, 0.91, 1.0 };

const VISIBLE_TRUNK: f32 = 0.44; // bare trunk, as a fraction of tree height
const CROWN_H: f32 = 0.648; // crown height, as a fraction of tree height
const CROWN_W: f32 = 0.288; // crown base half-width, as a fraction of tree height
const MIN_CONE_FORWARD: f32 = 0.4; // a cone base nearer than this bails to the flat tier

// the screen-space layout shared by both forms: ground point, pixel height, crown
// apex, foliage span, crown base half-width. Mirrors metrics() in tree.ts.
const Metrics = struct { bx: f32, by: f32, ht: f32, apex_y: f32, foliage: f32, w: f32 };

fn metrics(right: f32, forward: f32, height: f32, cam_focal: f32) Metrics {
    const base = camera.project(.{ .right = right, .forward = forward, .height = 0 }, cam_focal);
    const top = camera.project(.{ .right = right, .forward = forward, .height = height }, cam_focal);
    const ht = base.y - top.y;
    const foliage = ht * CROWN_H;
    const crown_bottom_y = base.y - ht * VISIBLE_TRUNK;
    return .{ .bx = base.x, .by = base.y, .ht = ht, .apex_y = crown_bottom_y - foliage, .foliage = foliage, .w = ht * CROWN_W };
}

fn drawTrunk(m: Metrics, round: bool) void {
    const trunk_w = @max(@as(f32, 1.0), m.ht * 0.08);
    const trunk_h = m.ht * VISIBLE_TRUNK + m.ht * 0.05;
    const tx = m.bx - trunk_w / 2.0;
    const pts = [_]camera.ScreenPt{
        .{ .x = tx, .y = m.by - trunk_h },
        .{ .x = tx + trunk_w, .y = m.by - trunk_h },
        .{ .x = tx + trunk_w, .y = m.by },
        .{ .x = tx, .y = m.by },
    };
    if (round) paint.pushRoundPoly(TRUNK, 1.0, &pts) else paint.pushPoly(TRUNK, &pts);
}

// one flat crown tier (the far / cheap form, and the near form's bail-out for a
// cone too close to project).
fn tierTriangle(m: Metrics, k: usize, color: u32) void {
    const tri = [_]camera.ScreenPt{
        .{ .x = m.bx, .y = m.apex_y + m.foliage * TIER_TOP[k] },
        .{ .x = m.bx + m.w * TIER_WIDE[k], .y = m.apex_y + m.foliage * TIER_BOT[k] },
        .{ .x = m.bx - m.w * TIER_WIDE[k], .y = m.apex_y + m.foliage * TIER_BOT[k] },
    };
    paint.pushPoly(color, &tri);
}

/// draw a roadside conifer. Two independent detail axes (they're noticed at different
/// ranges): `round_trunk` shades the trunk as a cylinder vs a flat bar — only the nearest
/// few trees, since trunk shading only reads up close; `near_crown` builds the crown from 3D
/// cone hulls vs flat triangles. Crowns are always SOLID (the roundness is the cone shape,
/// not lighting), so there's no shaded↔solid pop across the tree line.
pub fn draw(right: f32, forward: f32, height: f32, color: u32, cam_focal: f32, round_trunk: bool, near_crown: bool, crown_shade: f32) void {
    const m = metrics(right, forward, height, cam_focal);
    if (m.ht < 1.0) return;
    drawTrunk(m, round_trunk);
    var k: usize = 0;
    if (near_crown) {
        while (k < 8) : (k += 1) tierCone(right, forward, height, color, cam_focal, m, k, crown_shade);
    } else {
        while (k < 8) : (k += 1) tierTriangle(m, k, color);
    }
}

// crown tier `k` as a cone: a base circle of world radius R on the trunk axis rising
// to the tier apex. Project the apex + a ring of base points (each at its own depth)
// and fill their convex hull — exactly the cone's silhouette (a cone is convex).
fn tierCone(r0: f32, f0: f32, height: f32, color: u32, cam_focal: f32, m: Metrics, k: usize, shade: f32) void {
    const R = CROWN_W * TIER_WIDE[k] * height; // base radius (world m)
    if (f0 - R < MIN_CONE_FORWARD) { // too close — bail to the flat tier
        tierTriangle(m, k, color);
        return;
    }
    const h_base = (VISIBLE_TRUNK + CROWN_H * (1.0 - TIER_BOT[k])) * height;
    const h_apex = (VISIBLE_TRUNK + CROWN_H * (1.0 - TIER_TOP[k])) * height;
    const N = 16;
    var ring: [N + 1]camera.ScreenPt = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, N) * 2.0 * std.math.pi;
        ring[i] = camera.project(.{ .right = r0 + R * @cos(a), .forward = f0 + R * @sin(a), .height = h_base }, cam_focal);
    }
    ring[N] = camera.project(.{ .right = r0, .forward = f0, .height = h_apex }, cam_focal); // apex on the axis

    var hull: [N + 1]camera.ScreenPt = undefined;
    const hn = convexHull(ring[0 .. N + 1], hull[0..]);
    if (hn < 3) return;
    // The cone's roundness is mostly its SHAPE (the projected ring+apex hull); the round
    // gradient just adds a touch of light. `shade` (1 near → 0 by distance) fades that light
    // so it's strongest on the closest crowns and reaches 0 (= solid, cheap) smoothly — no
    // abrupt shaded↔solid edge across the tree line, since crowns are seen far out.
    paint.pushRoundPoly(color, shade, hull[0..hn]);
}

// convex hull (Andrew's monotone chain) of screen points — the cone's filled
// silhouette. Sorts a local copy, builds the lower + upper chains, concatenates.
fn convexHull(in: []const camera.ScreenPt, out: []camera.ScreenPt) usize {
    const n = in.len;
    if (n < 3) {
        var i: usize = 0;
        while (i < n) : (i += 1) out[i] = in[i];
        return n;
    }
    var ps: [17]camera.ScreenPt = undefined;
    {
        var i: usize = 0;
        while (i < n) : (i += 1) ps[i] = in[i];
    }
    std.sort.insertion(camera.ScreenPt, ps[0..n], {}, lessXY);

    var lower: [17]camera.ScreenPt = undefined;
    var ln: usize = 0;
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            while (ln >= 2 and cross(lower[ln - 2], lower[ln - 1], ps[i]) <= 0) ln -= 1;
            lower[ln] = ps[i];
            ln += 1;
        }
    }
    var upper: [17]camera.ScreenPt = undefined;
    var un: usize = 0;
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            while (un >= 2 and cross(upper[un - 2], upper[un - 1], ps[i]) <= 0) un -= 1;
            upper[un] = ps[i];
            un += 1;
        }
    }
    var m: usize = 0;
    {
        var i: usize = 0;
        while (i + 1 < ln) : (i += 1) {
            out[m] = lower[i];
            m += 1;
        }
    }
    {
        var i: usize = 0;
        while (i + 1 < un) : (i += 1) {
            out[m] = upper[i];
            m += 1;
        }
    }
    return m;
}

fn cross(o: camera.ScreenPt, a: camera.ScreenPt, b: camera.ScreenPt) f32 {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

fn lessXY(_: void, a: camera.ScreenPt, b: camera.ScreenPt) bool {
    return a.x < b.x or (a.x == b.x and a.y < b.y);
}
