//! guard_rail — the metal barrier on the outer edge of a corner: a single horizontal
//! bar on thin upright posts. render.zig builds the PATH the rail follows on the ground
//! (run-up along the outer shoulder, the two legs into and out of the apex, run-out);
//! emit() raises that path into 3D rail polys and COLLECTS them into a RailStore.
//! Mirrors guard_rail.ts.
//!
//! Why collect instead of draw straight to the paint buffer: rails, trees and critters
//! share ONE back-to-front depth pass (main.ts), so a tree standing BEHIND a rail is
//! occluded by it. Each rail poly therefore carries its own mean forward depth and is
//! merged into render's depth sort; drawPoly() does the clip/project/push later, in
//! sorted order. (Drawing rails in a separate pass under all scenery is the exact bug
//! that made a far tree paint over a near rail.)
//!
//! TS draws the bar as ONE long ribbon polygon; we draw it as a quad STRIP (one quad per
//! path segment). Perceptually identical — consecutive quads share an exact edge, no gap
//! — but every poly stays <= 4 verts, so it near-clips and sorts by an honest per-poly
//! depth. Heights are raw (no ground curvature), exactly as in TS: the rail is always
//! close, so the drop is sub-mm.

const geom = @import("geom.zig");
const camera = @import("camera.zig");
const paint = @import("paint.zig");

const RAIL_HEIGHT: f32 = 0.5; // the bar's centre, above the ground (metres)
const RAIL_THICKNESS: f32 = 0.1; // the bar's vertical thickness
const RAIL_POST_WIDTH: f32 = 0.02; // each upright post's width
const RAIL_METAL: u32 = 0xc2c7cf; // the bar (bright metallic)
const RAIL_POST_METAL: u32 = 0x9aa0a8; // the posts (a touch darker)
pub const RAIL_RUNOUT: usize = 10; // metres the rail runs past the corner along each outer edge

// Every visible joint (<= MAX_CHAIN) contributes a bar strip + posts; one path holds at
// most 2*RAIL_PATH_CAP points, so this bounds the store so emit() never silently drops.
pub const MAX_RAIL_POLYS: usize = 3072;

// one raised rail poly in the rider frame (always 4 verts): its corners + fill colour +
// mean forward depth, the key it sorts by in render's unified scenery pass.
pub const RailPoly = struct { v: [4]geom.Vec3, color: u32, fwd: f32 };

pub const RailStore = struct {
    polys: [MAX_RAIL_POLYS]RailPoly = undefined,
    n: usize = 0,

    pub fn reset(self: *RailStore) void {
        self.n = 0;
    }

    fn add(self: *RailStore, v: [4]geom.Vec3, color: u32) void {
        if (self.n >= MAX_RAIL_POLYS) return; // bounded; the cap is sized so this can't fire on this route
        const fwd = (v[0].forward + v[1].forward + v[2].forward + v[3].forward) / 4.0;
        self.polys[self.n] = .{ .v = v, .color = color, .fwd = fwd };
        self.n += 1;
    }
};

/// emit raises the ground path (its centreline in the rider frame, one post per point)
/// into the bar + posts and collects them into `store`. Mirrors buildGuardRail.
pub fn emit(store: *RailStore, path: []const geom.RiderPt) void {
    if (path.len < 2) return;
    const bar_top = RAIL_HEIGHT + RAIL_THICKNESS / 2.0;
    const bar_bot = RAIL_HEIGHT - RAIL_THICKNESS / 2.0;

    // the bar: a quad strip between consecutive path points (bottom edge at bar_bot, top
    // at bar_top); consecutive quads share an edge exactly, so it reads as one band.
    var i: usize = 0;
    while (i + 1 < path.len) : (i += 1) {
        const p = path[i];
        const q = path[i + 1];
        store.add(.{
            .{ .right = p.right, .forward = p.forward, .height = bar_bot },
            .{ .right = q.right, .forward = q.forward, .height = bar_bot },
            .{ .right = q.right, .forward = q.forward, .height = bar_top },
            .{ .right = p.right, .forward = p.forward, .height = bar_top },
        }, RAIL_METAL);
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
        store.add(.{
            .{ .right = p.right - ox, .forward = p.forward - of, .height = 0 },
            .{ .right = p.right + ox, .forward = p.forward + of, .height = 0 },
            .{ .right = p.right + ox, .forward = p.forward + of, .height = bar_top },
            .{ .right = p.right - ox, .forward = p.forward - of, .height = bar_top },
        }, RAIL_POST_METAL);
    }
}

/// drawPoly near-clips one stored rail poly, projects it, and pushes the fill — the same
/// pipeline as a road quad, but the corners carry their own heights so it stands above
/// the pavement. Called by render in depth-sorted order. Mirrors drawGuardRail.
pub fn drawPoly(rp: RailPoly, cam_focal: f32) void {
    var clipped: [8]geom.Vec3 = undefined;
    const m = geom.clipNear(rp.v[0..], camera.NEAR, &clipped);
    if (m < 3) return;
    var screen: [8]camera.ScreenPt = undefined;
    var j: usize = 0;
    while (j < m) : (j += 1) screen[j] = camera.project(clipped[j], cam_focal);
    paint.pushPoly(rp.color, screen[0..m]);
}
