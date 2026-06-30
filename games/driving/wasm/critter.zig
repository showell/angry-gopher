//! critter — a roadside animal as a baked-polygon billboard. Projects the feet + top to a
//! pixel height, then transforms the critter's baked unit-frame polygons (emoji_frames.zig,
//! feet at y = 0, y up, height 1, facing LEFT) to that screen anchor and emits them as ordinary
//! polygons — the seam is polygon-only, so there is no emoji glyph at runtime. Flipped to face
//! the road. Mirrors how cat.zig draws cat_frames. The animals themselves (cows / bull / safari)
//! live in world.zig / safari_critter.zig; this only knows how to place + flip a billboard.

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
    var screen: [512]camera.ScreenPt = undefined;
    for (polys) |poly| {
        if (poly.pts.len > screen.len) continue;
        for (poly.pts, 0..) |p, i| {
            screen[i] = .{ .x = base.x + sx * p.x * h, .y = base.y - p.y * h };
        }
        paint.pushPoly(poly.color, screen[0..poly.pts.len]);
    }
}
