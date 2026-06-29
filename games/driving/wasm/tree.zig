//! tree — a roadside conifer as flat-shaded polygons: the FAR / 2D form (a trunk
//! bar + eight stacked crown tiers, narrow apex to wide base). The near 3D-cone form
//! (real cones + round shading) is drawn only up close and is deferred — it needs a
//! gradient primitive the flat-polygon seam doesn't carry yet. Builds screen-space
//! polygons from the tree's rider-relative position and pushes them to paint.
//! Mirrors drawTree() + metrics() in tree.ts.

const camera = @import("camera.zig");
const paint = @import("paint.zig");

const TRUNK: u32 = 0x5a3e22;

// the eight crown tiers as fractions of the foliage span: each tier's apex (TOP) and
// base (BOT) height and its base half-width (WIDE). Narrow at top, widest at bottom.
const TIER_TOP = [_]f32{ 0.0, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70 };
const TIER_BOT = [_]f32{ 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.0 };
const TIER_WIDE = [_]f32{ 0.35, 0.44, 0.53, 0.63, 0.72, 0.81, 0.91, 1.0 };

const VISIBLE_TRUNK: f32 = 0.44; // bare trunk, as a fraction of tree height
const CROWN_H: f32 = 0.648; // crown height, as a fraction of tree height
const CROWN_W: f32 = 0.288; // crown base half-width, as a fraction of tree height

/// draw the far-form tree at rider-relative (right, forward), `height` m tall, in
/// `color`. Projects the base + apex to get the pixel height, then lays the trunk +
/// tiers out in screen space (a billboard — the screen-space layout of tree.ts).
pub fn draw(right: f32, forward: f32, height: f32, color: u32, cam_focal: f32) void {
    const base = camera.project(.{ .right = right, .forward = forward, .height = 0 }, cam_focal);
    const top = camera.project(.{ .right = right, .forward = forward, .height = height }, cam_focal);
    const ht = base.y - top.y; // pixel height
    if (ht < 1.0) return;

    const foliage = ht * CROWN_H;
    const crown_bottom_y = base.y - ht * VISIBLE_TRUNK;
    const apex_y = crown_bottom_y - foliage;
    const w = ht * CROWN_W;
    const bx = base.x;
    const by = base.y;

    // trunk: a vertical bar (4-point polygon), up into the crown a touch (no gap).
    const trunk_w = @max(@as(f32, 1.0), ht * 0.08);
    const trunk_h = ht * VISIBLE_TRUNK + ht * 0.05;
    const tx = bx - trunk_w / 2.0;
    const trunk_pts = [_]camera.ScreenPt{
        .{ .x = tx, .y = by - trunk_h },
        .{ .x = tx + trunk_w, .y = by - trunk_h },
        .{ .x = tx + trunk_w, .y = by },
        .{ .x = tx, .y = by },
    };
    paint.pushPoly(TRUNK, &trunk_pts);

    // eight crown tiers, each a flat triangle in the tree colour.
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const tri = [_]camera.ScreenPt{
            .{ .x = bx, .y = apex_y + foliage * TIER_TOP[k] },
            .{ .x = bx + w * TIER_WIDE[k], .y = apex_y + foliage * TIER_BOT[k] },
            .{ .x = bx - w * TIER_WIDE[k], .y = apex_y + foliage * TIER_BOT[k] },
        };
        paint.pushPoly(color, &tri);
    }
}
