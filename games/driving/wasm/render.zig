//! render — the orchestrator: turn the world + camera pose into screen-space
//! polygons in the paint buffer, back to front. Walks the segment CHAIN from the
//! rider's current segment, composing each join (geom.nextToCur) so a far segment's
//! points land in the rider's frame — the `at(d, a, x)` of view.ts. Per chain
//! segment it lays the road strip + the corner pavement at its exit join, and
//! collects the trees; then it depth-sorts the trees and draws them near(3D)/far(2D).
//! No drawing — that's the JS blitter.

const geom = @import("geom.zig");
const camera = @import("camera.zig");
const world = @import("world.zig");
const tree = @import("tree.zig");
const tower = @import("tower.zig");
const critter = @import("critter.zig");
const mountains = @import("mountains.zig");
const paint = @import("paint.zig");

const ROAD: u32 = 0x34353c;
const ROAD_CHUNK: f32 = 25.0; // road strips sliced this long so the bend reads smooth
const DETAIL_DIST: f32 = 70.0; // within this, a tree draws 3D near; beyond, 2D far
const MIN_SCENERY_PX: f32 = 2.0; // skip scenery that would project shorter than this
const LOOK_AHEAD: usize = 7; // how many segments ahead we draw
const MAX_CHAIN: usize = 8;
const MAX_VIS_TREES: usize = 640; // fixed-spacing trees across the whole visible chain
const MAX_VIS_TOWERS: usize = 16;
const MAX_VIS_COWS: usize = 128;

// tower placement (intersection.ts): out past the corner, off to the right, yawed.
const TOWER_BEYOND: f32 = 160.0; // metres past the segment end
const TOWER_RIGHT: f32 = 20.0; // metres right of the lane centreline
const TOWER_YAW: f32 = 30.0 * 3.14159265 / 180.0;
const SEG_TOWER_LEFT: f32 = 100.0; // a mid-tower stands this far LEFT of the centreline

const Chain = struct { idx: [MAX_CHAIN]usize, len: usize };

// follow exit_to from `start`, stopping at LOOK_AHEAD or when the loop closes back to
// the start (so the rider's own segment isn't redrawn far ahead).
fn buildChain(w: *const world.World, start: usize) Chain {
    var ch = Chain{ .idx = undefined, .len = 0 };
    var s = start;
    while (ch.len < LOOK_AHEAD and ch.len < MAX_CHAIN) {
        ch.idx[ch.len] = s;
        ch.len += 1;
        const next = w.segments[s].exit_to;
        if (next == start) break;
        s = next;
    }
    return ch;
}

const Pose = struct { along: f32, across: f32, yaw: f32, hw: f32 };

// map (a, x) in chain[d]'s BL frame into the rider frame, composing the joins down to
// chain[0], then the rider transform. For d = 0 this is just toRider.
fn at(w: *const world.World, ch: *const Chain, pose: Pose, d: usize, a: f32, x: f32) geom.RiderPt {
    var pa = a;
    var px = x;
    var k: usize = d;
    while (k > 0) {
        k -= 1; // chain[k] → chain[k+1] is chain[k]'s exit turn
        const seg = w.segments[ch.idx[k]];
        const p = geom.nextToCur(pa, px, seg.length, seg.exit_angle, seg.exit_right, seg.width);
        pa = p.a;
        px = p.x;
    }
    return geom.toRider(pa, px, pose.along, pose.across, pose.yaw, pose.hw);
}

// build ground verts (curvature drop per vertex), near-clip, project, push as ROAD.
fn emitGround(pts: []const geom.RiderPt, cam_focal: f32) void {
    if (pts.len > 8) return;
    var v: [8]geom.Vec3 = undefined;
    for (pts, 0..) |p, i| v[i] = .{ .right = p.right, .forward = p.forward, .height = -geom.groundDrop(p.right, p.forward) };
    var clipped: [16]geom.Vec3 = undefined;
    const m = geom.clipNear(v[0..pts.len], camera.NEAR, &clipped);
    if (m < 3) return;
    var screen: [16]camera.ScreenPt = undefined;
    var j: usize = 0;
    while (j < m) : (j += 1) screen[j] = camera.project(clipped[j], cam_focal);
    paint.pushPoly(ROAD, screen[0..m]);
}

pub fn frame(w: *const world.World, seg_idx: usize, along: f32, across: f32, yaw: f32) void {
    const cam_focal = camera.FOCAL; // static frame: no lean/focus pull-in yet
    const ch = buildChain(w, seg_idx);
    const cur = w.segments[seg_idx];
    const pose = Pose{ .along = along, .across = across, .yaw = yaw, .hw = cur.width / 2.0 };

    // the backdrop, behind everything; absolute look heading = segment heading + yaw.
    mountains.draw(cur.north_heading + yaw);

    // trees collected across the whole chain, then depth-sorted as one set.
    var t_right: [MAX_VIS_TREES]f32 = undefined;
    var t_fwd: [MAX_VIS_TREES]f32 = undefined;
    var t_h: [MAX_VIS_TREES]f32 = undefined;
    var t_col: [MAX_VIS_TREES]u32 = undefined;
    var nt: usize = 0;

    // towers collected the same way: their owning chain index `d` + base centre/yaw,
    // and the depth of that centre for sorting.
    var w_d: [MAX_VIS_TOWERS]usize = undefined;
    var w_a0: [MAX_VIS_TOWERS]f32 = undefined;
    var w_x0: [MAX_VIS_TOWERS]f32 = undefined;
    var w_yaw: [MAX_VIS_TOWERS]f32 = undefined;
    var w_fwd: [MAX_VIS_TOWERS]f32 = undefined;
    var ntw: usize = 0;

    // cows/bulls, collected as billboards (rider-relative), drawn in the depth sort.
    var c_right: [MAX_VIS_COWS]f32 = undefined;
    var c_fwd: [MAX_VIS_COWS]f32 = undefined;
    var c_h: [MAX_VIS_COWS]f32 = undefined;
    var c_cp: [MAX_VIS_COWS]u32 = undefined;
    var c_face: [MAX_VIS_COWS]bool = undefined;
    var ncow: usize = 0;

    var d: usize = 0;
    while (d < ch.len) : (d += 1) {
        const seg = w.segments[ch.idx[d]];
        const hw = seg.width / 2.0;
        const wseg = seg.width;

        // road strip, sliced along its length.
        const chunks_f = @ceil(seg.length / ROAD_CHUNK);
        const chunks: usize = @intFromFloat(@max(@as(f32, 1.0), chunks_f));
        var ci: usize = 0;
        while (ci < chunks) : (ci += 1) {
            const fi: f32 = @floatFromInt(ci);
            const fc: f32 = @floatFromInt(chunks);
            const a0 = seg.length * fi / fc;
            const a1 = seg.length * (fi + 1.0) / fc;
            const quad = [_]geom.RiderPt{
                at(w, &ch, pose, d, a0, 0),
                at(w, &ch, pose, d, a0, wseg),
                at(w, &ch, pose, d, a1, wseg),
                at(w, &ch, pose, d, a1, 0),
            };
            emitGround(quad[0..], cam_focal);
        }

        // corner pavement at this segment's exit join, when the next segment is in view.
        if (d + 1 < ch.len) emitCorner(w, &ch, pose, d, cam_focal);

        // the intersection tower beyond this segment's exit, and the mid-tower on a
        // long segment. Collected (with the depth of the base centre) for sorting.
        if (ntw < MAX_VIS_TOWERS) {
            const c = at(w, &ch, pose, d, seg.length + TOWER_BEYOND, seg.width / 2.0 + TOWER_RIGHT);
            if (c.forward > camera.NEAR) {
                w_d[ntw] = d;
                w_a0[ntw] = seg.length + TOWER_BEYOND;
                w_x0[ntw] = seg.width / 2.0 + TOWER_RIGHT;
                w_yaw[ntw] = TOWER_YAW;
                w_fwd[ntw] = c.forward;
                ntw += 1;
            }
        }
        if (seg.has_mid_tower and ntw < MAX_VIS_TOWERS) {
            const a0 = seg.length / 2.0;
            const x0 = seg.width / 2.0 - SEG_TOWER_LEFT;
            const c = at(w, &ch, pose, d, a0, x0);
            if (c.forward > camera.NEAR) {
                w_d[ntw] = d;
                w_a0[ntw] = a0;
                w_x0[ntw] = x0;
                w_yaw[ntw] = 0;
                w_fwd[ntw] = c.forward;
                ntw += 1;
            }
        }

        // trees (centre-relative across + hw → from-the-left), collected for sorting.
        var ti: usize = 0;
        while (ti < seg.n_trees and nt < MAX_VIS_TREES) : (ti += 1) {
            const tr = seg.trees[ti];
            const rp = at(w, &ch, pose, d, tr.along, tr.across + hw);
            if (rp.forward <= camera.NEAR) continue;
            if (tr.height / rp.forward * cam_focal < MIN_SCENERY_PX) continue;
            t_right[nt] = rp.right;
            t_fwd[nt] = rp.forward;
            t_h[nt] = tr.height;
            t_col[nt] = tr.color;
            nt += 1;
        }

        // cows/bulls (centre-relative across + hw → from-the-left), collected.
        var cti: usize = 0;
        while (cti < seg.n_cows and ncow < MAX_VIS_COWS) : (cti += 1) {
            const cr = seg.cows[cti];
            const rp = at(w, &ch, pose, d, cr.along, cr.across + hw);
            if (rp.forward <= camera.NEAR) continue;
            if (cr.height / rp.forward * cam_focal < MIN_SCENERY_PX) continue;
            c_right[ncow] = rp.right;
            c_fwd[ncow] = rp.forward;
            c_h[ncow] = cr.height;
            c_cp[ncow] = cr.codepoint;
            c_face[ncow] = cr.face_right;
            ncow += 1;
        }
    }

    // merge trees + towers + cows into one depth order (far → near) so they occlude
    // right.
    const Kind = enum { tree, tower, cow };
    const Item = struct { fwd: f32, kind: Kind, i: usize };
    var items: [MAX_VIS_TREES + MAX_VIS_TOWERS + MAX_VIS_COWS]Item = undefined;
    var ni: usize = 0;
    var i: usize = 0;
    while (i < nt) : (i += 1) {
        items[ni] = .{ .fwd = t_fwd[i], .kind = .tree, .i = i };
        ni += 1;
    }
    i = 0;
    while (i < ntw) : (i += 1) {
        items[ni] = .{ .fwd = w_fwd[i], .kind = .tower, .i = i };
        ni += 1;
    }
    i = 0;
    while (i < ncow) : (i += 1) {
        items[ni] = .{ .fwd = c_fwd[i], .kind = .cow, .i = i };
        ni += 1;
    }
    // insertion sort by depth descending (n is small).
    i = 1;
    while (i < ni) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0 and items[j - 1].fwd < key.fwd) : (j -= 1) items[j] = items[j - 1];
        items[j] = key;
    }

    for (items[0..ni]) |it| {
        switch (it.kind) {
            .tower => {
                var base: [4]geom.RiderPt = undefined;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    const ax = tower.baseCornerAX(k, w_a0[it.i], w_x0[it.i], w_yaw[it.i]);
                    base[k] = at(w, &ch, pose, w_d[it.i], ax.a, ax.x);
                }
                const center = at(w, &ch, pose, w_d[it.i], w_a0[it.i], w_x0[it.i]);
                tower.drawFlat(base, center, cam_focal);
            },
            .cow => critter.draw(c_right[it.i], c_fwd[it.i], c_h[it.i], c_cp[it.i], c_face[it.i], cam_focal),
            .tree => if (t_fwd[it.i] < DETAIL_DIST)
                tree.drawNear(t_right[it.i], t_fwd[it.i], t_h[it.i], t_col[it.i], cam_focal)
            else
                tree.drawFar(t_right[it.i], t_fwd[it.i], t_h[it.i], t_col[it.i], cam_focal),
        }
    }
}

// the corner pavement: a quad from the inner fuse-corner out to the outer apex Q where
// the two segments' extended outer shoulders meet. Mirrors intersectionScene's main
// quad. corner(cu, cv) = at(d, from.length + cv, cu).
fn emitCorner(w: *const world.World, ch: *const Chain, pose: Pose, d: usize, cam_focal: f32) void {
    const from = w.segments[ch.idx[d]];
    const to = w.segments[ch.idx[d + 1]];
    const right = from.exit_right;
    const wf = from.width;
    const from_outer_cu: f32 = if (right) 0 else wf;
    const to_outer_x: f32 = if (right) 0 else to.width;
    const inner = at(w, ch, pose, d, from.length, if (right) wf else 0);
    const outer_from = at(w, ch, pose, d, from.length, from_outer_cu);
    const outer_from1 = at(w, ch, pose, d, from.length + 1, from_outer_cu);
    const outer_to = at(w, ch, pose, d + 1, 0, to_outer_x);
    const outer_to1 = at(w, ch, pose, d + 1, 1, to_outer_x);
    const q = geom.lineMeet(outer_from, outer_from1, outer_to, outer_to1);
    const quad = [_]geom.RiderPt{ inner, outer_from, q, outer_to };
    emitGround(quad[0..], cam_focal);
}
