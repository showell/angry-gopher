//! guard_rail — the metal barrier on the outer edge of a corner: a single horizontal
//! bar on thin upright posts. render.zig builds the PATH the rail follows on the ground
//! (run-up along the outer shoulder, the two legs into and out of the apex, run-out);
//! this raises that path into 3D and emits it. Mirrors guard_rail.ts.
//!
//! TS draws the bar as ONE long ribbon polygon; we draw it as a quad STRIP (one quad
//! per path segment). It's perceptually identical — consecutive quads share an exact
//! edge (same right/forward, only height differs), so there's no gap — but every
//! emitted poly stays <= 4 verts, so it near-clips and fits the fixed paint buffers
//! cleanly instead of needing a giant variable-length polygon. Heights are raw (no
//! ground curvature), exactly as in TS: the rail is always close, so the drop is sub-mm.

const geom = @import("geom.zig");
const camera = @import("camera.zig");
const paint = @import("paint.zig");

const RAIL_HEIGHT: f32 = 0.5; // the bar's centre, above the ground (metres)
const RAIL_THICKNESS: f32 = 0.1; // the bar's vertical thickness
const RAIL_POST_WIDTH: f32 = 0.02; // each upright post's width
const RAIL_METAL: u32 = 0xc2c7cf; // the bar (bright metallic)
const RAIL_POST_METAL: u32 = 0x9aa0a8; // the posts (a touch darker)
pub const RAIL_RUNOUT: usize = 10; // metres the rail runs past the corner along each outer edge

// emit one raised rail poly: near-clip its height-carrying verts, project, fill. Same
// pipeline as a road quad, but the corners already carry their own heights, so it stands
// above the pavement (and is emitted after the road for that reason).
fn emitPoly(verts: []const geom.Vec3, color: u32, cam_focal: f32) void {
    if (verts.len > 6) return;
    var clipped: [8]geom.Vec3 = undefined;
    const m = geom.clipNear(verts, camera.NEAR, &clipped);
    if (m < 3) return;
    var screen: [8]camera.ScreenPt = undefined;
    var j: usize = 0;
    while (j < m) : (j += 1) screen[j] = camera.project(clipped[j], cam_focal);
    paint.pushPoly(color, screen[0..m]);
}

/// emit raises the ground path (its centreline in the rider frame, one post per point)
/// into the bar + posts and pushes them. Mirrors buildGuardRail + drawGuardRail.
pub fn emit(path: []const geom.RiderPt, cam_focal: f32) void {
    if (path.len < 2) return;
    const bar_top = RAIL_HEIGHT + RAIL_THICKNESS / 2.0;
    const bar_bot = RAIL_HEIGHT - RAIL_THICKNESS / 2.0;

    // the bar: a quad strip between consecutive path points (bottom edge at bar_bot, top
    // at bar_top); consecutive quads share an edge exactly, so it reads as one band.
    var i: usize = 0;
    while (i + 1 < path.len) : (i += 1) {
        const p = path[i];
        const q = path[i + 1];
        const quad = [_]geom.Vec3{
            .{ .right = p.right, .forward = p.forward, .height = bar_bot },
            .{ .right = q.right, .forward = q.forward, .height = bar_bot },
            .{ .right = q.right, .forward = q.forward, .height = bar_top },
            .{ .right = p.right, .forward = p.forward, .height = bar_top },
        };
        emitPoly(quad[0..], RAIL_METAL, cam_focal);
    }

    // the posts: a slim upright at each path point, its width laid along the local run
    // direction so it reads edge-on from the road.
    const half_post = RAIL_POST_WIDTH / 2.0;
    i = 0;
    while (i < path.len) : (i += 1) {
        const a = path[if (i == 0) 0 else i - 1];
        const b = path[if (i + 1 >= path.len) path.len - 1 else i + 1];
        var len = @sqrt((b.right - a.right) * (b.right - a.right) + (b.forward - a.forward) * (b.forward - a.forward));
        if (len == 0) len = 1;
        const ox = (b.right - a.right) / len * half_post;
        const of = (b.forward - a.forward) / len * half_post;
        const p = path[i];
        const post = [_]geom.Vec3{
            .{ .right = p.right - ox, .forward = p.forward - of, .height = 0 },
            .{ .right = p.right + ox, .forward = p.forward + of, .height = 0 },
            .{ .right = p.right + ox, .forward = p.forward + of, .height = bar_top },
            .{ .right = p.right - ox, .forward = p.forward - of, .height = bar_top },
        };
        emitPoly(post[0..], RAIL_POST_METAL, cam_focal);
    }
}
