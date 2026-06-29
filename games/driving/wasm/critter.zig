//! critter — a roadside animal as an emoji billboard. Projects the base + top to a
//! pixel height and emits an emoji command (the blitter draws the glyph; it can't be
//! a polygon). Mirrors drawCritter() in critter.ts. The animals themselves (cows /
//! bull) live in world.zig; this only knows how to place a billboard.

const camera = @import("camera.zig");
const paint = @import("paint.zig");

/// draw one critter at rider-relative (right, forward), `height` m tall, as the emoji
/// `codepoint` — a square billboard sized by distance, flipped to face the road.
pub fn draw(right: f32, forward: f32, height: f32, codepoint: u32, face_right: bool, cam_focal: f32) void {
    const base = camera.project(.{ .right = right, .forward = forward, .height = 0 }, cam_focal);
    const top = camera.project(.{ .right = right, .forward = forward, .height = height }, cam_focal);
    const h = base.y - top.y;
    if (h < 1.0) return;
    paint.pushEmoji(codepoint, face_right, base.x, base.y, h);
}
