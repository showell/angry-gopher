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
const cat = @import("cat.zig");
const mountains = @import("mountains.zig");
const guard_rail = @import("guard_rail.zig");
const sky = @import("sky.zig");
const paint = @import("paint.zig");

const ROAD: u32 = 0x34353c;
const ROAD_CHUNK: f32 = 25.0; // road strips sliced this long so the bend reads smooth
const ENTRY_ROAD_DIST: f32 = 40.0; // metres of approach road a joint paints behind its end edge (covers the joint when it's the one BEHIND the rider). Mirrors intersection.ts.
const RAIL_PATH_CAP: usize = 192; // max points in a corner's rail path (run-up + two legs + run-out); ample for any turn on this route, bounds the fixed buffer
const DETAIL_DIST: f32 = 70.0; // within this, a tree draws 3D near; beyond, 2D far
const MIN_SCENERY_PX: f32 = 2.0; // skip scenery that would project shorter than this
const LOOK_AHEAD: usize = 7; // how many segments ahead we draw
const MAX_CHAIN: usize = 8;
const MAX_VIS_TREES: usize = 640; // fixed-spacing trees across the whole visible chain
const MAX_VIS_TOWERS: usize = 16;
const MAX_VIS_COWS: usize = 128;
const MAX_VIS_CATS: usize = 8; // at most a handful of cat-bearing segments are ever in view at once

// rail polys (bar quads + posts) collected across all visible joints, merged into the
// scenery depth sort so trees occlude rails by honest depth. Static (like paint's
// buffer): frame() runs once per call, single-threaded, so module scratch is fine and
// keeps these large arrays off the wasm stack.
var rails: guard_rail.RailStore = .{};

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

// A frame mapper: how to express a point (a along, x across-from-left) authored in some
// segment's BL frame into the rider's frame. A FORWARD joint maps both its segments
// through the chain (`at` at index d); the joint just BEHIND the rider maps its `from`
// (the previous segment) FORWARD through the join via curToNext, then toRider. Mirrors
// the fromMap/toMap closures view.ts hands intersectionScene (zig has no closures).
const MapKind = enum { chain, prev };
const Mapper = struct {
    kind: MapKind = .chain,
    d: usize = 0, // chain index (chain kind)
    prev_len: f32 = 0, // previous segment's length/turn (prev kind)
    prev_angle: f32 = 0,
    prev_right: bool = false,
    prev_w: f32 = 0,
};

fn mapPt(w: *const world.World, ch: *const Chain, pose: Pose, m: Mapper, a: f32, x: f32) geom.RiderPt {
    switch (m.kind) {
        .chain => return at(w, ch, pose, m.d, a, x),
        .prev => {
            const p = geom.curToNext(a, x, m.prev_len, m.prev_angle, m.prev_right, m.prev_w);
            return geom.toRider(p.a, p.x, pose.along, pose.across, pose.yaw, pose.hw);
        },
    }
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

pub fn frame(w: *const world.World, seg_idx: usize, along: f32, across: f32, yaw: f32, heading: f32, step: f32, v: f32) void {
    const cam_focal = camera.FOCAL; // static frame: no lean/focus pull-in yet
    rails.reset();
    const ch = buildChain(w, seg_idx);
    const cur = w.segments[seg_idx];
    const pose = Pose{ .along = along, .across = across, .yaw = yaw, .hw = cur.width / 2.0 };

    // the backdrop, behind everything; drawn from the rider's ABSOLUTE heading (continuous
    // across the loop seam, unlike north_heading + yaw — see RiderState.heading). The sunset
    // clock dims the ranges toward dusk (the sun + dimming sky are drawn JS-side, behind
    // these polys, from the colours/placement safari.zig exports).
    mountains.draw(heading, sky.sunSetFraction(step));

    // trees collected across the whole chain, then depth-sorted as one set.
    var t_right: [MAX_VIS_TREES]f32 = undefined;
    var t_fwd: [MAX_VIS_TREES]f32 = undefined;
    var t_h: [MAX_VIS_TREES]f32 = undefined;
    var t_col: [MAX_VIS_TREES]u32 = undefined;
    var nt: usize = 0;

    // towers collected the same way: how to map their owning frame (a forward chain
    // index, or the behind joint) + base centre/yaw, and the depth of that centre for
    // sorting. A tower is OWNED by its intersection, so the joint just behind contributes
    // its tower too (the one we just passed) — else it pops out the instant we turn.
    var w_map: [MAX_VIS_TOWERS]Mapper = undefined;
    var w_a0: [MAX_VIS_TOWERS]f32 = undefined;
    var w_x0: [MAX_VIS_TOWERS]f32 = undefined;
    var w_yaw: [MAX_VIS_TOWERS]f32 = undefined;
    var w_fwd: [MAX_VIS_TOWERS]f32 = undefined;
    var w_off: [MAX_VIS_TOWERS]f32 = undefined; // this tower's beacon blink-phase offset
    var ntw: usize = 0;

    // cows/bulls, collected as billboards (rider-relative), drawn in the depth sort.
    var c_right: [MAX_VIS_COWS]f32 = undefined;
    var c_fwd: [MAX_VIS_COWS]f32 = undefined;
    var c_h: [MAX_VIS_COWS]f32 = undefined;
    var c_cp: [MAX_VIS_COWS]u32 = undefined;
    var c_face: [MAX_VIS_COWS]bool = undefined;
    var ncow: usize = 0;

    // crossing cats, collected as billboard stills (rider-relative) for the depth sort. The cat's pose +
    // lateral travel + hop come from its crossing clock, keyed off the rider's road-along gap to it.
    var k_right: [MAX_VIS_CATS]f32 = undefined;
    var k_fwd: [MAX_VIS_CATS]f32 = undefined;
    var k_h: [MAX_VIS_CATS]f32 = undefined;
    var k_pose: [MAX_VIS_CATS]usize = undefined;
    var k_lift: [MAX_VIS_CATS]f32 = undefined;
    var ncat: usize = 0;

    // road-along distance from the rider to the START (along = 0) of the chain segment being walked; the
    // cat's gap is this + its `along`. Starts negative (the rider is `along` into his current segment).
    var seg_start_gap: f32 = -along;

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

        // this exit joint's GROUND (approach road + corner pavement), when the next
        // segment is in view. The rail rides on top and is emitted after all ground.
        if (d + 1 < ch.len) {
            const to = w.segments[ch.idx[d + 1]];
            emitJointGround(w, &ch, pose, .{ .d = d }, .{ .d = d + 1 }, seg.length, seg.width, to.width, seg.exit_right, cam_focal);
        }

        // the intersection tower beyond this segment's exit, and the mid-tower on a
        // long segment. Collected (with the depth of the base centre) for sorting.
        if (ntw < MAX_VIS_TOWERS) {
            const c = at(w, &ch, pose, d, seg.length + TOWER_BEYOND, seg.width / 2.0 + TOWER_RIGHT);
            if (c.forward > camera.NEAR) {
                w_map[ntw] = .{ .kind = .chain, .d = d };
                w_a0[ntw] = seg.length + TOWER_BEYOND;
                w_x0[ntw] = seg.width / 2.0 + TOWER_RIGHT;
                w_yaw[ntw] = TOWER_YAW;
                w_fwd[ntw] = c.forward;
                w_off[ntw] = tower.beaconOffsetFor(ch.idx[d]); // exit-intersection tower: keyed off its segment
                ntw += 1;
            }
        }
        if (seg.has_mid_tower and ntw < MAX_VIS_TOWERS) {
            const a0 = seg.length / 2.0;
            const x0 = seg.width / 2.0 - SEG_TOWER_LEFT;
            const c = at(w, &ch, pose, d, a0, x0);
            if (c.forward > camera.NEAR) {
                w_map[ntw] = .{ .kind = .chain, .d = d };
                w_a0[ntw] = a0;
                w_x0[ntw] = x0;
                w_yaw[ntw] = 0;
                w_fwd[ntw] = c.forward;
                w_off[ntw] = tower.beaconOffsetFor(ch.idx[d] + 60); // mid-tower: +60 so it doesn't blink in step with the segment's exit tower
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

        // the crossing cat: its pose + lateral offset + hop from the crossing clock (rider's along-gap to
        // it + speed), placed as a billboard at its current across. Collected for the depth sort.
        if (seg.has_cat and ncat < MAX_VIS_CATS) {
            const st = cat.state(seg.cat, seg_start_gap + seg.cat.along, v);
            const rp = at(w, &ch, pose, d, seg.cat.along, st.across + hw);
            // a billboard at one depth: cull it well before camera.NEAR or the projection flings the still
            // across the screen as the rider passes (see cat.NEAR_CULL — the tower-streak lesson).
            if (rp.forward > cat.NEAR_CULL and seg.cat.height / rp.forward * cam_focal >= MIN_SCENERY_PX) {
                k_right[ncat] = rp.right;
                k_fwd[ncat] = rp.forward;
                k_h[ncat] = seg.cat.height;
                k_pose[ncat] = st.pose_idx;
                k_lift[ncat] = st.lift;
                ncat += 1;
            }
        }

        seg_start_gap += seg.length; // advance to the next chain segment's start
    }

    // the joint just BEHIND the rider: its ground (approach road + pavement) mapped
    // forward through the join keeps the segment he just left from vanishing mid-crossing
    // — the bug where the pavement popped out the instant cur.segment flipped. The route
    // loops, so there is always a previous segment. Mirrors view.ts's behind-joint pass.
    const prev_idx = (seg_idx + w.n_segments - 1) % w.n_segments;
    const prev = w.segments[prev_idx];
    const prev_map = Mapper{ .kind = .prev, .prev_len = prev.length, .prev_angle = prev.exit_angle, .prev_right = prev.exit_right, .prev_w = prev.width };
    const cur_map = Mapper{ .kind = .chain, .d = 0 };
    emitJointGround(w, &ch, pose, prev_map, cur_map, prev.length, prev.width, cur.width, prev.exit_right, cam_focal);

    // the tower the joint we just passed OWNS, mapped forward through the join — without
    // it, the previous intersection's tower vanishes the moment cur.segment flips (the
    // same symptom the pavement had). Position is unchanged: beyond the corner, +RIGHT of
    // prev's lane centreline, yawed — exactly intersectionTower(pIxn, prev, fromPrev).
    if (ntw < MAX_VIS_TOWERS) {
        const a0 = prev.length + TOWER_BEYOND;
        const x0 = prev.width / 2.0 + TOWER_RIGHT;
        const c = mapPt(w, &ch, pose, prev_map, a0, x0);
        if (c.forward > camera.NEAR) {
            w_map[ntw] = prev_map;
            w_a0[ntw] = a0;
            w_x0[ntw] = x0;
            w_yaw[ntw] = TOWER_YAW;
            w_fwd[ntw] = c.forward;
            w_off[ntw] = tower.beaconOffsetFor(prev_idx);
            ntw += 1;
        }
    }

    // guard rails: collect each forward joint's rail and the behind joint's. They are
    // NOT drawn here — they merge into the depth sort below so trees occlude them right.
    var dr: usize = 0;
    while (dr + 1 < ch.len) : (dr += 1) {
        const fseg = w.segments[ch.idx[dr]];
        const tseg = w.segments[ch.idx[dr + 1]];
        emitJointRail(w, &ch, pose, .{ .d = dr }, .{ .d = dr + 1 }, fseg.length, fseg.width, tseg.width, fseg.exit_right);
    }
    emitJointRail(w, &ch, pose, prev_map, cur_map, prev.length, prev.width, cur.width, prev.exit_right);

    // merge trees + towers + cows into one depth order (far → near) so they occlude
    // right.
    const Kind = enum { tree, tower, cow, cat, rail };
    const Item = struct { fwd: f32, kind: Kind, i: usize };
    var items: [MAX_VIS_TREES + MAX_VIS_TOWERS + MAX_VIS_COWS + MAX_VIS_CATS + guard_rail.MAX_RAIL_POLYS]Item = undefined;
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
    i = 0;
    while (i < ncat) : (i += 1) {
        items[ni] = .{ .fwd = k_fwd[i], .kind = .cat, .i = i };
        ni += 1;
    }
    i = 0;
    while (i < rails.n) : (i += 1) {
        items[ni] = .{ .fwd = rails.polys[i].fwd, .kind = .rail, .i = i };
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
                    base[k] = mapPt(w, &ch, pose, w_map[it.i], ax.a, ax.x);
                }
                const center = mapPt(w, &ch, pose, w_map[it.i], w_a0[it.i], w_x0[it.i]);
                tower.drawFlat(base, center, cam_focal, step + w_off[it.i]);
            },
            .cow => critter.draw(c_right[it.i], c_fwd[it.i], c_h[it.i], c_cp[it.i], c_face[it.i], cam_focal),
            .cat => cat.draw(k_right[it.i], k_fwd[it.i], k_h[it.i], k_pose[it.i], k_lift[it.i], cam_focal),
            .rail => guard_rail.drawPoly(rails.polys[it.i], cam_focal),
            .tree => if (t_fwd[it.i] < DETAIL_DIST)
                tree.drawNear(t_right[it.i], t_fwd[it.i], t_h[it.i], t_col[it.i], cam_focal)
            else
                tree.drawFar(t_right[it.i], t_fwd[it.i], t_h[it.i], t_col[it.i], cam_focal),
        }
    }
}

// A joint's GROUND, in the rider's frame: the approach road (the `from` tail leading
// into the joint) and the corner PAVEMENT quad — the inner fuse-corner out to the outer
// apex Q where the two segments' extended outer shoulders cross. Mirrors the quad half
// of intersectionScene. corner(cu, cv) = fromMap(from_len + cv, cu).
fn emitJointGround(w: *const world.World, ch: *const Chain, pose: Pose, from_map: Mapper, to_map: Mapper, from_len: f32, from_w: f32, to_w: f32, exit_right: bool, cam_focal: f32) void {
    // the approach road: `from`'s tail (end edge back ENTRY_ROAD_DIST).
    const approach = [_]geom.RiderPt{
        mapPt(w, ch, pose, from_map, from_len, 0),
        mapPt(w, ch, pose, from_map, from_len, from_w),
        mapPt(w, ch, pose, from_map, from_len - ENTRY_ROAD_DIST, from_w),
        mapPt(w, ch, pose, from_map, from_len - ENTRY_ROAD_DIST, 0),
    };
    emitGround(approach[0..], cam_focal);

    // the corner pavement quad: inner fuse-corner, `from`'s outer corner, the outer apex
    // Q (the two outer shoulders extended until they cross), `to`'s outer corner.
    const from_outer_cu: f32 = if (exit_right) 0 else from_w;
    const to_outer_x: f32 = if (exit_right) 0 else to_w;
    const inner = mapPt(w, ch, pose, from_map, from_len, if (exit_right) from_w else 0);
    const outer_from = mapPt(w, ch, pose, from_map, from_len, from_outer_cu);
    const outer_to = mapPt(w, ch, pose, to_map, 0, to_outer_x);
    const q = geom.lineMeet(outer_from, mapPt(w, ch, pose, from_map, from_len + 1, from_outer_cu), outer_to, mapPt(w, ch, pose, to_map, 1, to_outer_x));
    const quad = [_]geom.RiderPt{ inner, outer_from, q, outer_to };
    emitGround(quad[0..], cam_focal);
}

// Append points from `from` (EXCLUSIVE) to `to` (inclusive) at ~1m spacing — one
// guard-rail post per metre along a straight leg of the corner. Mirrors pushLeg.
fn pushLeg(path: *[RAIL_PATH_CAP]geom.RiderPt, n0: usize, from: geom.RiderPt, to: geom.RiderPt) usize {
    var n = n0;
    const dr = to.right - from.right;
    const df = to.forward - from.forward;
    const dist = @sqrt(dr * dr + df * df);
    const steps: usize = @intFromFloat(@max(1.0, @round(dist)));
    var i: usize = 1;
    while (i <= steps and n < RAIL_PATH_CAP) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        path[n] = .{ .right = from.right + dr * t, .forward = from.forward + df * t };
        n += 1;
    }
    return n;
}

// A joint's guard RAIL: the run-up along `from`'s outer shoulder, the two legs into and
// out of the apex Q, and the run-out along `to`'s outer shoulder — then guard_rail.emit
// raises that path to the bar + posts and collects them for the depth sort. Mirrors the
// rail half of intersectionScene.
fn emitJointRail(w: *const world.World, ch: *const Chain, pose: Pose, from_map: Mapper, to_map: Mapper, from_len: f32, from_w: f32, to_w: f32, exit_right: bool) void {
    const from_outer_cu: f32 = if (exit_right) 0 else from_w;
    const to_outer_x: f32 = if (exit_right) 0 else to_w;
    const outer_from = mapPt(w, ch, pose, from_map, from_len, from_outer_cu);
    const outer_to = mapPt(w, ch, pose, to_map, 0, to_outer_x);
    const q = geom.lineMeet(outer_from, mapPt(w, ch, pose, from_map, from_len + 1, from_outer_cu), outer_to, mapPt(w, ch, pose, to_map, 1, to_outer_x));

    var path: [RAIL_PATH_CAP]geom.RiderPt = undefined;
    var n: usize = 0;
    // run-up along `from`'s outer edge to the end edge (m = RUNOUT .. 0; m = 0 = outer_from).
    var m: usize = guard_rail.RAIL_RUNOUT;
    while (true) : (m -= 1) {
        const mm: f32 = @floatFromInt(m);
        if (n < RAIL_PATH_CAP) {
            path[n] = mapPt(w, ch, pose, from_map, from_len - mm, from_outer_cu);
            n += 1;
        }
        if (m == 0) break;
    }
    n = pushLeg(&path, n, outer_from, q); // leg into the apex
    n = pushLeg(&path, n, q, outer_to); // leg out of the apex
    // run-out along `to`'s outer edge.
    var mo: usize = 1;
    while (mo <= guard_rail.RAIL_RUNOUT and n < RAIL_PATH_CAP) : (mo += 1) {
        const mm: f32 = @floatFromInt(mo);
        path[n] = mapPt(w, ch, pose, to_map, mm, to_outer_x);
        n += 1;
    }
    guard_rail.emit(&rails, path[0..n]);
}
