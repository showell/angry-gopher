//! render — the orchestrator: turn the world + camera pose into screen-space
//! polygons in the paint buffer, in back-to-front paint order. Collects the road
//! strip and the trees, projects + near-clips each, and pushes. This is the
//! buildScene + render split of the TS, FUSED here while there is a single straight
//! segment; scene.zig splits back out when turns (the segment chain + joins) arrive.
//! No drawing — that is the JS blitter's only job.

const geom = @import("geom.zig");
const camera = @import("camera.zig");
const world = @import("world.zig");
const tree = @import("tree.zig");
const mountains = @import("mountains.zig");
const paint = @import("paint.zig");

const ROAD: u32 = 0x34353c;
const ROAD_CHUNK: f32 = 25.0; // road strips sliced this long so the bend reads smooth
const DETAIL_DIST: f32 = 70.0; // within this, a tree draws its 3D near form; beyond, 2D far
const MIN_SCENERY_PX: f32 = 2.0; // skip scenery that would project shorter than this

pub fn frame(seg: world.Segment, cam_along: f32, cam_across: f32, cam_yaw: f32) void {
    const cam_focal = camera.FOCAL; // static frame: no lean/focus pull-in yet
    const hw = seg.width / 2.0;

    // ---- the far backdrop, drawn FIRST (behind everything). The absolute look
    // heading is the segment's north heading + the look yaw; seg1's north heading is
    // 0, so for now it's just cam_yaw (the chain carries real headings once turns
    // arrive). ----
    mountains.draw(cam_yaw);

    // ---- road strip (the ground plane): x = 0..width, sliced along
    // its length so the per-vertex curvature drop reads as a smooth bend. ----
    const chunks_f = @ceil(seg.length / ROAD_CHUNK);
    const chunks: usize = @intFromFloat(@max(@as(f32, 1.0), chunks_f));
    var i: usize = 0;
    while (i < chunks) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const fc: f32 = @floatFromInt(chunks);
        const a0 = seg.length * fi / fc;
        const a1 = seg.length * (fi + 1.0) / fc;
        emitGroundQuad(a0, a1, seg.width, cam_along, cam_across, cam_yaw, hw, cam_focal);
    }

    // ---- trees, sorted far → near so nearer ones paint over farther ones. ----
    var fwd: [world.MAX_TREES]f32 = undefined;
    var idx: [world.MAX_TREES]usize = undefined;
    var t: usize = 0;
    while (t < seg.n_trees) : (t += 1) {
        const tr = seg.trees[t];
        const rp = geom.toRider(tr.along, tr.across + hw, cam_along, cam_across, cam_yaw, hw);
        fwd[t] = rp.forward;
        idx[t] = t;
    }
    sortByForwardDesc(idx[0..seg.n_trees], fwd[0..]);
    for (idx[0..seg.n_trees]) |ti| {
        const tr = seg.trees[ti];
        const rp = geom.toRider(tr.along, tr.across + hw, cam_along, cam_across, cam_yaw, hw);
        if (rp.forward <= camera.NEAR) continue;
        if (tr.height / rp.forward * cam_focal < MIN_SCENERY_PX) continue; // too small/far to bother
        if (rp.forward < DETAIL_DIST)
            tree.drawNear(rp.right, rp.forward, tr.height, tr.color, cam_focal)
        else
            tree.drawFar(rp.right, rp.forward, tr.height, tr.color, cam_focal);
    }
}

/// emitGroundQuad builds one road-strip quad (x 0..width, along a0..a1), lowers each
/// vertex by the ground curvature, near-clips, projects, and pushes it as ROAD.
fn emitGroundQuad(a0: f32, a1: f32, width: f32, cam_along: f32, cam_across: f32, cam_yaw: f32, hw: f32, cam_focal: f32) void {
    const ax = [_]f32{ a0, a0, a1, a1 };
    const xx = [_]f32{ 0.0, width, width, 0.0 };
    var v: [4]geom.Vec3 = undefined;
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        const rp = geom.toRider(ax[n], xx[n], cam_along, cam_across, cam_yaw, hw);
        v[n] = .{ .right = rp.right, .forward = rp.forward, .height = -geom.groundDrop(rp.right, rp.forward) };
    }
    var clipped: [8]geom.Vec3 = undefined;
    const m = geom.clipNear(&v, camera.NEAR, &clipped);
    if (m < 3) return;
    var screen: [8]camera.ScreenPt = undefined;
    var j: usize = 0;
    while (j < m) : (j += 1) screen[j] = camera.project(clipped[j], cam_focal);
    paint.pushPoly(ROAD, screen[0..m]);
}

/// insertion sort of `idx` by `fwd[idx]` descending (n is tiny — a few dozen trees).
fn sortByForwardDesc(idx: []usize, fwd: []const f32) void {
    var i: usize = 1;
    while (i < idx.len) : (i += 1) {
        const key = idx[i];
        var j: usize = i;
        while (j > 0 and fwd[idx[j - 1]] < fwd[key]) : (j -= 1) idx[j] = idx[j - 1];
        idx[j] = key;
    }
}
