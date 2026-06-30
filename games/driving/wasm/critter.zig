//! critter — a roadside animal as a baked-polygon billboard. Projects the feet + top to a
//! pixel height, then transforms the critter's baked unit-frame polygons (emoji_frames.zig,
//! feet at y = 0, y up, height 1, facing LEFT) to that screen anchor and emits them. Most polys
//! are solid; the bull's are gradient-shaded (the Fluent Color art) — its gradient geometry is
//! transformed by the SAME billboard map as the points, so the shading scales + flips with it.
//! Mirrors how cat.zig draws cat_frames. The animals live in world.zig / safari_critter.zig;
//! this only knows how to place + flip a billboard.

const camera = @import("camera.zig");
const paint = @import("paint.zig");
const frames = @import("emoji_frames.zig");

/// draw one critter at rider-relative (right, forward), `height` m tall, as the baked polygons
/// for `codepoint` — sized by distance, mirrored to face the road.
pub fn draw(right: f32, forward: f32, height: f32, codepoint: u32, face_right: bool, cam_focal: f32) void {
    const base = camera.project(.{ .right = right, .forward = forward, .height = 0 }, cam_focal);
    const top = camera.project(.{ .right = right, .forward = forward, .height = height }, cam_focal);
    const h = base.y - top.y;
    if (h < 1.0) return;
    const polys = frames.polysFor(codepoint) orelse return;
    const sx: f32 = if (face_right) -1.0 else 1.0; // baked facing LEFT; mirror to face right

    // unit frame → screen. A POINT translates to the feet anchor; a VECTOR (gradient axis) only scales/flips.
    const mapP = struct {
        fn f(b: camera.ScreenPt, s: f32, ht: f32, x: f32, y: f32) camera.ScreenPt {
            return .{ .x = b.x + s * x * ht, .y = b.y - y * ht };
        }
    }.f;
    const mapV = struct {
        fn f(s: f32, ht: f32, x: f32, y: f32) camera.ScreenPt {
            return .{ .x = s * x * ht, .y = -y * ht };
        }
    }.f;

    var screen: [512]camera.ScreenPt = undefined;
    for (polys) |poly| {
        if (poly.pts.len > screen.len) continue;
        for (poly.pts, 0..) |p, i| screen[i] = mapP(base, sx, h, p.x, p.y);
        const pts = screen[0..poly.pts.len];
        if (poly.grad) |g| {
            if (g.kind == 1) {
                const a = mapP(base, sx, h, g.ax, g.ay);
                const b = mapP(base, sx, h, g.bx, g.by);
                paint.pushLinearGradPoly(g.s0.rgba, g.s1.rgba, g.s0.off, g.s1.off, a.x, a.y, b.x, b.y, pts);
            } else {
                const c = mapP(base, sx, h, g.cx, g.cy);
                const u = mapV(sx, h, g.ux, g.uy);
                const v = mapV(sx, h, g.vx, g.vy);
                paint.pushRadialGradPoly(g.s0.rgba, g.s1.rgba, g.s0.off, g.s1.off, c.x, c.y, u.x, u.y, v.x, v.y, pts);
            }
        } else {
            paint.pushPoly(poly.color, pts);
        }
    }
}
