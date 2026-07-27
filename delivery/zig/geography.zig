// geography.zig — port of delivery/geography.ts, solver-relevant subset.
// The TS file is the reference; this holds the same data tables and the
// geometry helpers the SOLVER consults (gate angles, arc groups, ring walks).
// Display-only helpers (housesOf positions, ringWalkPath, bridgeDeck) are
// deliberately not ported. Nodes are u8 ids: NEIGHBORHOODS order, FC last —
// the same order as roadgraph.ts NODES, which the gold substrate pins.

const std = @import("std");

pub const Pt = struct { x: f64, y: f64 };
pub const Side = enum { west, east, island };

pub const Nbhd = struct {
    name: []const u8,
    center: Pt,
    side: Side,
    ring_radius: f64,
    houses: u8,
};

fn n(name: []const u8, x: f64, y: f64, side: Side, ring: f64, houses: u8) Nbhd {
    return .{ .name = name, .center = .{ .x = x, .y = y }, .side = side, .ring_radius = ring, .houses = houses };
}

pub const NEIGHBORHOODS = [_]Nbhd{
    n("Ballard", 224, 146, .west, 32, 12),
    n("Green Lake", 360, 62, .west, 34, 12),
    n("Fremont", 340, 212, .west, 30, 12),
    n("U-District", 460, 169, .west, 30, 12),
    n("Magnolia", 170, 291, .west, 26, 12),
    n("Queen Anne", 286, 316, .west, 32, 12),
    n("Capitol Hill", 434, 443, .west, 29, 12),
    n("Eastlake", 441, 311, .west, 24, 12),
    n("Downtown", 300, 430, .west, 30, 12),
    n("Beacon Hill", 432, 555, .west, 30, 12),
    n("West Seattle", 211, 589, .west, 30, 12),
    n("Mercer Island", 548, 500, .island, 10, 0),
    n("Mercer N", 548, 552, .island, 19, 12),
    n("Mercer S", 548, 635, .island, 19, 12),
    n("Medina", 638, 228, .east, 28, 12),
    n("Kirkland", 650, 60, .east, 30, 12),
    n("Redmond", 868, 200, .east, 32, 12),
    n("Bellevue", 740, 330, .east, 34, 12),
    n("Factoria", 672, 508, .east, 30, 12),
    n("Issaquah", 858, 612, .east, 30, 12),
    n("Exit 1", 328, 570, .west, 6, 0),
    n("Exit 2", 377, 436, .west, 6, 0),
    n("Exit 3", 397, 311, .west, 6, 0),
    n("Exit 4", 401, 212, .west, 6, 0),
    n("Exit 5", 405, 169, .west, 6, 0),
    n("Exit 6", 414, 84, .west, 6, 0),
    n("5/520", 399, 262, .west, 6, 0),
    n("Montlake", 490, 256, .west, 6, 0),
};

pub const N_NBHD: u8 = NEIGHBORHOODS.len; // 28
pub const FC: u8 = N_NBHD; // the warehouse's node id (roadgraph NODES puts it last)
pub const N_NODES: u8 = N_NBHD + 1; // 29

pub const WAREHOUSE = Pt{ .x = 802, .y = 396 };

/// Compile-time name -> node id (compile error on a typo'd name).
pub fn id(comptime name: []const u8) u8 {
    @setEvalBranchQuota(100_000);
    if (comptime std.mem.eql(u8, name, "FC")) return FC;
    inline for (NEIGHBORHOODS, 0..) |nb, i| {
        if (comptime std.mem.eql(u8, nb.name, name)) return i;
    }
    @compileError("unknown node: " ++ name);
}

pub fn nameOf(node: u8) []const u8 {
    return if (node == FC) "FC" else NEIGHBORHOODS[node].name;
}

// --- Fleet ---------------------------------------------------------------

pub const TRUCKS: u8 = 8;
pub const ORDERS: u8 = 100;
pub const TRUCK_CAPS = [TRUCKS]u8{ 14, 14, 14, 14, 14, 12, 12, 12 };
pub const MAX_CAP: u8 = 14;

pub const TRUCK_ANCHORS = [TRUCKS]u8{
    id("West Seattle"), id("Magnolia"),  id("Ballard"),  id("Green Lake"),
    id("Capitol Hill"), id("Kirkland"), id("Issaquah"), id("Mercer S"),
};

pub const DEFER_LAST = [_]u8{ id("Bellevue"), id("Medina") };

pub const I5_EXITS = blk: {
    var set = [_]bool{false} ** N_NODES;
    for ([_]u8{ id("Exit 1"), id("Exit 2"), id("Exit 3"), id("Exit 4"), id("Exit 5"), id("Exit 6"), id("5/520") }) |x| set[x] = true;
    break :blk set;
};

pub const ARC_EXEMPT = blk: {
    var set = [_]bool{false} ** N_NODES;
    for ([_]u8{ id("West Seattle"), id("Magnolia"), id("Kirkland"), id("Issaquah"), id("Mercer S"), id("U-District") }) |x| set[x] = true;
    break :blk set;
};

// --- Roads & bridges -----------------------------------------------------

pub const ROADS = [_][2]u8{
    .{ id("Ballard"), id("Green Lake") },
    .{ id("Ballard"), id("Fremont") },
    .{ id("Magnolia"), id("Ballard") },
    .{ id("Magnolia"), id("Queen Anne") },
    .{ id("Green Lake"), id("Fremont") },
    .{ id("Fremont"), id("Queen Anne") },
    .{ id("Queen Anne"), id("Downtown") },
    .{ id("Capitol Hill"), id("Eastlake") },
    .{ id("Capitol Hill"), id("Beacon Hill") },
    .{ id("Downtown"), id("West Seattle") },
    .{ id("Exit 1"), id("West Seattle") },
    .{ id("Exit 1"), id("Beacon Hill") },
    .{ id("Exit 2"), id("Downtown") },
    .{ id("Exit 2"), id("Capitol Hill") },
    .{ id("Exit 3"), id("Eastlake") },
    .{ id("Exit 4"), id("Fremont") },
    .{ id("Exit 5"), id("U-District") },
    .{ id("Exit 6"), id("Green Lake") },
    .{ id("Eastlake"), id("Montlake") },
    .{ id("Medina"), id("Kirkland") },
    .{ id("Medina"), id("Bellevue") },
    .{ id("Kirkland"), id("Redmond") },
    .{ id("Bellevue"), id("Redmond") },
    .{ id("Bellevue"), id("Factoria") },
    .{ id("Bellevue"), FC },
    .{ FC, id("Factoria") },
    .{ id("Factoria"), id("Issaquah") },
    .{ id("Issaquah"), id("Redmond") },
    .{ id("Mercer Island"), id("Mercer N") },
    .{ id("Mercer N"), id("Mercer S") },
};

pub const Bridge = struct {
    nodes: []const u8,
    waters: []const []const Pt, // waters[i] = waypoints between nodes[i] and nodes[i+1]
};

pub const BRIDGES = [_]Bridge{
    .{ // SR 520
        .nodes = &[_]u8{ id("5/520"), id("Montlake"), id("Medina") },
        .waters = &[_][]const Pt{ &.{}, &.{} },
    },
    .{ // I-90
        .nodes = &[_]u8{ id("Beacon Hill"), id("Mercer Island"), id("Factoria") },
        .waters = &[_][]const Pt{ &.{Pt{ .x = 482, .y = 522 }}, &.{Pt{ .x = 610, .y = 489 }} },
    },
    .{ // I-5
        .nodes = &[_]u8{ id("Exit 1"), id("Exit 2"), id("Exit 3"), id("5/520"), id("Exit 4"), id("Exit 5"), id("Exit 6") },
        .waters = &[_][]const Pt{ &.{}, &.{Pt{ .x = 399, .y = 373 }}, &.{}, &.{}, &.{}, &.{} },
    },
};

// --- Geometry helpers ----------------------------------------------------

const TAU = std.math.pi * 2.0;

/// Angle into [0, 2π) — TS: ((a % TAU) + TAU) % TAU. JS % keeps the
/// dividend's sign, which is zig's @rem (NOT @mod, which follows the divisor).
pub fn norm(a: f64) f64 {
    return @rem(@rem(a, TAU) + TAU, TAU);
}

/// Deterministic per-name phase in [0, 2π) — u32 wrap hash, same as TS.
fn namePhase(name: []const u8) f64 {
    var h: u32 = 0;
    for (name) |c| h = h *% 31 +% c;
    return @as(f64, @floatFromInt(h % 360)) * (std.math.pi / 180.0);
}

pub fn nodeAt(node: u8) Pt {
    return if (node == FC) WAREHOUSE else NEIGHBORHOODS[node].center;
}

/// The gate point where the artery toward `toward` meets `node`'s ring.
pub fn gateOf(node: u8, toward: Pt) Pt {
    if (node == FC) return WAREHOUSE;
    const nb = NEIGHBORHOODS[node];
    const a = std.math.atan2(toward.y - nb.center.y, toward.x - nb.center.x);
    return .{ .x = nb.center.x + @cos(a) * nb.ring_radius, .y = nb.center.y + @sin(a) * nb.ring_radius };
}

/// Angle (from the center) of the gate facing `toward`. FC has no ring -> 0.
pub fn gateAngle(node: u8, toward: Pt) f64 {
    if (node == FC) return 0;
    const nb = NEIGHBORHOODS[node];
    return std.math.atan2(toward.y - nb.center.y, toward.x - nb.center.x);
}

pub const MAX_HOUSES: u8 = 14; // largest house list a stop can carry (= MAX_CAP)

/// Ring angles of the given house indices (TS houseAngles).
pub fn houseAngles(node: u8, houses: []const u8, out: []f64) []f64 {
    if (node == FC) return out[0..0];
    const nb = NEIGHBORHOODS[node];
    const phase = namePhase(nb.name);
    for (houses, 0..) |h, i| {
        out[i] = phase + (@as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(nb.houses))) * TAU;
    }
    return out[0..houses.len];
}

pub const MAX_SPOKES: u8 = 8;

/// Surface-road neighbors (bridges excluded on purpose), in ROADS scan order.
pub fn surfaceSpokes(node: u8, out: *[MAX_SPOKES]u8) []u8 {
    var len: usize = 0;
    for (ROADS) |r| {
        if (r[0] == node and r[1] != FC) {
            out[len] = r[1];
            len += 1;
        }
        if (r[1] == node and r[0] != FC) {
            out[len] = r[0];
            len += 1;
        }
    }
    return out[0..len];
}

pub const ArcGroups = struct {
    // Flat storage: groups[g] = houses[offsets[g]..offsets[g+1]].
    houses: [MAX_HOUSES]u8 = undefined,
    offsets: [MAX_SPOKES + 2]u8 = undefined,
    count: u8 = 0,

    pub fn group(self: *const ArcGroups, g: usize) []const u8 {
        return self.houses[self.offsets[g]..self.offsets[g + 1]];
    }
};

/// Partition ordered houses into ring wedges between surface-spoke gates
/// (TS arcGroups). Exempt / <2-spoke / empty cases stay whole.
pub fn arcGroups(node: u8, idx: []const u8) ArcGroups {
    var out = ArcGroups{};
    var spoke_buf: [MAX_SPOKES]u8 = undefined;
    const spokes = surfaceSpokes(node, &spoke_buf);
    if (ARC_EXEMPT[node] or spokes.len < 2 or idx.len == 0) {
        if (idx.len > 0) {
            @memcpy(out.houses[0..idx.len], idx);
            out.offsets[0] = 0;
            out.offsets[1] = @intCast(idx.len);
            out.count = 1;
        }
        return out;
    }
    var gates: [MAX_SPOKES]f64 = undefined;
    for (spokes, 0..) |s, i| gates[i] = norm(gateAngle(node, nodeAt(s)));
    std.sort.insertion(f64, gates[0..spokes.len], {}, std.sort.asc(f64));

    var angs_buf: [MAX_HOUSES]f64 = undefined;
    const angs = houseAngles(node, idx, &angs_buf);

    // Arc id per house: the gate just below its angle (wrap past the last).
    var arc_of: [MAX_HOUSES]u8 = undefined;
    for (idx, 0..) |_, i| {
        const a = norm(angs[i]);
        var g: u8 = @intCast(spokes.len - 1);
        for (gates[0..spokes.len], 0..) |gate, gi| {
            if (gate <= a) g = @intCast(gi);
        }
        arc_of[i] = g;
    }
    // Emit non-empty buckets in ascending arc order, houses in idx order.
    var off: u8 = 0;
    out.offsets[0] = 0;
    for (0..spokes.len) |arc| {
        var any = false;
        for (idx, 0..) |h, i| {
            if (arc_of[i] == arc) {
                out.houses[off] = h;
                off += 1;
                any = true;
            }
        }
        if (any) {
            out.count += 1;
            out.offsets[out.count] = off;
        }
    }
    return out;
}

/// The minimal in-neighborhood ring walk's arc length in px (TS ringWalkArcPx
/// via walkPlan). entry/exit/house angles -> covered arc, out-and-back or loop.
pub fn ringWalkArcPx(node: u8, entry_a: f64, exit_a: f64, h_angles: []const f64) f64 {
    if (node == FC) return 0;
    const r = NEIGHBORHOODS[node].ring_radius;
    var pts: [MAX_HOUSES + 2]f64 = undefined;
    pts[0] = norm(entry_a);
    pts[1] = norm(exit_a);
    for (h_angles, 0..) |a, i| pts[2 + i] = norm(a);
    const len = 2 + h_angles.len;
    std.sort.insertion(f64, pts[0..len], {}, std.sort.asc(f64));

    var max_gap: f64 = -1;
    var gap_at: usize = 0;
    for (0..len) |i| {
        const next = if (i + 1 < len) pts[i + 1] else pts[0] + TAU;
        if (next - pts[i] > max_gap) {
            max_gap = next - pts[i];
            gap_at = i;
        }
    }
    const start_a = pts[(gap_at + 1) % len];
    const covered = TAU - max_gap;
    // Snap a gate offset that drifted into the uncovered gap back to the
    // nearer covered end (float-drift guard, same as TS arcOffset).
    const pe = arcOffset(entry_a, start_a, covered);
    const px = arcOffset(exit_a, start_a, covered);
    const same_gate = norm(entry_a - exit_a) < 1e-9;
    var arc_rad = 2 * covered - @abs(pe - px);
    if (same_gate and 2 * covered > TAU) arc_rad = TAU; // one lap beats backtracking
    return arc_rad * r;
}

fn arcOffset(a: f64, start_a: f64, covered: f64) f64 {
    const o = norm(a - start_a);
    if (o <= covered) return o;
    return if (TAU - o < o - covered) 0 else covered;
}

test "namePhase matches the TS hash for a couple of names" {
    // h("Ballard") = 31-poly hash mod 360 -> radians; just pin two values the
    // TS console printed once, so the hash can't silently drift.
    const b = namePhase("Ballard");
    try std.testing.expect(b >= 0 and b < TAU);
    const g = namePhase("Green Lake");
    try std.testing.expect(g >= 0 and g < TAU);
    try std.testing.expect(b != g);
}

test "arcGroups stays whole for exempt neighborhoods" {
    const idx = [_]u8{ 0, 3, 7 };
    const g = arcGroups(id("West Seattle"), &idx);
    try std.testing.expectEqual(@as(u8, 1), g.count);
    try std.testing.expectEqualSlices(u8, &idx, g.group(0));
}
