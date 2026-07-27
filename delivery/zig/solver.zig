// solver.zig — port of delivery/solver.ts, the routing brain. The reference
// is the TS file; this port must reproduce its output BIT-FOR-BIT (the gold
// corpus delivery/solver_gold.json is the contract, checked by gold_check.zig).
//
// Faithfulness notes (the things that are semantics, not style):
//   - Pain is integer, so the TS's float epsilons collapse: `> 1e-9`/`> 1e-6`
//     on an integer gain mean `>= 1`, `<= 1e-9` means `<= 0`, and rebalance's
//     |dTotal| > 0.75 TIE means "only dTotal == 0 passes".
//   - Ties resolve to the FIRST candidate in scan order everywhere (strict
//     comparisons), so loop order is load-bearing and mirrors the TS exactly.
//   - cheapestInsert seeds with the APPEND candidate (ties prefer append);
//     insertBest/reinsert scan positions 0..len (ties prefer the earliest).
//   - JS removes stops by object identity; here by index — every filter site
//     in the TS removes exactly one occurrence, so the two agree.
//   - JS Map/Set insertion-order iteration is preserved structurally (demand
//     order, threaded-node order, split-neighborhood discovery order).
//   - No log/frames: they feed the browser animation, never a decision.
//
// Everything runs on fixed-capacity value types — no allocator. Routes are
// tiny (≤ 8 trucks, ≤ 16 stops, ≤ 14 houses each); asserts guard the caps.

const std = @import("std");
const geo = @import("geography.zig");
const rg = @import("roadgraph.zig");

pub const Substrate = rg.Substrate;

const EMPTY_PAIN: i64 = 10;
const TOTE_PAIN: i64 = 2;
const RING_UNIT: i64 = 1;
const ANCHOR_PIN: u8 = 2; // anchor seed size (houses frozen to the slot)
pub const NO_PIN: u8 = 0xff;

pub const MAX_STOPS = 16;
pub const MAX_ROUTES = 40;

pub const Stop = struct {
    nbhd: u8,
    nh: u8 = 0, // orders == houses.len in the TS, kept as one field
    houses: [geo.MAX_HOUSES]u8 = undefined,
    pin: u8 = NO_PIN,

    pub fn init(nbhd: u8, houses: []const u8, pin: u8) Stop {
        var s = Stop{ .nbhd = nbhd, .nh = @intCast(houses.len), .pin = pin };
        @memcpy(s.houses[0..houses.len], houses);
        return s;
    }

    pub fn hs(self: *const Stop) []const u8 {
        return self.houses[0..self.nh];
    }
};

pub const Route = struct {
    stops: [MAX_STOPS]Stop = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Route) []const Stop {
        return self.stops[0..self.len];
    }

    pub fn push(self: *Route, s: Stop) void {
        std.debug.assert(self.len < MAX_STOPS);
        self.stops[self.len] = s;
        self.len += 1;
    }

    pub fn insertAt(self: *Route, pos: usize, s: Stop) void {
        std.debug.assert(self.len < MAX_STOPS);
        var i: usize = self.len;
        while (i > pos) : (i -= 1) self.stops[i] = self.stops[i - 1];
        self.stops[pos] = s;
        self.len += 1;
    }

    pub fn removeAt(self: *Route, pos: usize) void {
        for (pos..self.len - 1) |i| self.stops[i] = self.stops[i + 1];
        self.len -= 1;
    }

    pub fn fromSlice(stops: []const Stop) Route {
        var r = Route{};
        for (stops) |s| r.push(s);
        return r;
    }
};

pub const Routes = struct {
    r: [MAX_ROUTES]Route = undefined,
    len: u8 = 0,

    pub fn push(self: *Routes, route: Route) void {
        std.debug.assert(self.len < MAX_ROUTES);
        self.r[self.len] = route;
        self.len += 1;
    }

    pub fn removeAt(self: *Routes, pos: usize) void {
        for (pos..self.len - 1) |i| self.r[i] = self.r[i + 1];
        self.len -= 1;
    }

    fn dropEmpties(self: *Routes) void {
        var w: u8 = 0;
        for (0..self.len) |i| {
            if (self.r[i].len > 0) {
                self.r[w] = self.r[i];
                w += 1;
            }
        }
        self.len = w;
    }
};

fn loadOf(stops: []const Stop) i32 {
    var s: i32 = 0;
    for (stops) |st| s += st.nh;
    return s;
}

fn hasAnchor(stops: []const Stop) bool {
    for (stops) |s| {
        if (s.pin != NO_PIN) return true;
    }
    return false;
}

/// Capacity available to a route: its anchor's slot cap, else MAX_CAP.
fn capOf(stops: []const Stop) i32 {
    for (stops) |s| {
        if (s.pin != NO_PIN) return geo.TRUCK_CAPS[s.pin];
    }
    return geo.MAX_CAP;
}

// --- The pain model ------------------------------------------------------

const MAX_PATH_NODES = 256;

/// The nodes a route drives, FC -> stops -> FC, shortest paths expanded,
/// consecutive duplicates collapsed (TS pathNodes).
fn pathNodes(sub: *const Substrate, stops: []const Stop, out: *[MAX_PATH_NODES]u8) []u8 {
    var way: [MAX_STOPS + 2]u8 = undefined;
    way[0] = geo.FC;
    for (stops, 0..) |s, i| way[1 + i] = s.nbhd;
    way[1 + stops.len] = geo.FC;
    const wlen = stops.len + 2;

    var len: usize = 0;
    for (1..wlen) |i| {
        const p = sub.path(way[i - 1], way[i]);
        for (p) |node| {
            if (len == 0 or out[len - 1] != node) {
                std.debug.assert(len < MAX_PATH_NODES);
                out[len] = node;
                len += 1;
            }
        }
    }
    return out[0..len];
}

/// Integer pain of a stop sequence — the ONLY cost the solver compares.
pub fn painOf(sub: *const Substrate, stops: []const Stop) i64 {
    if (stops.len == 0) return 0;
    var buf: [MAX_PATH_NODES]u8 = undefined;
    const nodes = pathNodes(sub, stops, &buf);

    var counts = [_]i32{0} ** geo.N_NODES;
    for (stops) |s| counts[s.nbhd] += s.nh;

    var delivered = [_]bool{false} ** geo.N_NODES;
    var pain: i64 = 0;
    var aboard: i64 = loadOf(stops);
    for (1..nodes.len) |i| {
        pain += sub.time(nodes[i - 1], nodes[i]) * (EMPTY_PAIN + TOTE_PAIN * aboard);
        const node = nodes[i];
        if (node == geo.FC or i >= nodes.len - 1) continue;
        if (counts[node] > 0 and !delivered[node]) {
            pain += RING_UNIT * (EMPTY_PAIN + TOTE_PAIN * aboard);
            delivered[node] = true;
            aboard -= counts[node];
        }
    }
    return pain;
}

fn costOf(sub: *const Substrate, stops: []const Stop) i64 {
    return painOf(sub, stops);
}

// --- Display breakdown (TS breakdown) -------------------------------------
// The REAL minutes for the playback clock: integer artery travel + float
// ring-arc geometry + per-order service. Never consulted by a solver
// decision; ported because the browser's Plan carries it.

pub const Breakdown = struct { travel: i64 = 0, local: f64 = 0, service: i64 = 0, time: f64 = 0 };

pub fn breakdown(sub: *const Substrate, stops: []const Stop) Breakdown {
    if (stops.len == 0) return .{};
    var buf: [MAX_PATH_NODES]u8 = undefined;
    const nodes = pathNodes(sub, stops, &buf);

    // Houses per neighborhood, concatenated in stop order (TS housesByNbhd).
    var houses: [geo.N_NODES][geo.MAX_HOUSES]u8 = undefined;
    var counts = [_]u8{0} ** geo.N_NODES;
    for (stops) |s| {
        @memcpy(houses[s.nbhd][counts[s.nbhd] .. counts[s.nbhd] + s.nh], s.hs());
        counts[s.nbhd] += s.nh;
    }

    var delivered = [_]bool{false} ** geo.N_NODES;
    var travel: i64 = 0;
    var local: f64 = 0;
    for (1..nodes.len) |i| {
        travel += sub.time(nodes[i - 1], nodes[i]);
        const node = nodes[i];
        if (node == geo.FC or i >= nodes.len - 1) continue;
        const visit: []const u8 = if (counts[node] > 0 and !delivered[node]) houses[node][0..counts[node]] else &.{};
        const entry = geo.gateAngle(node, geo.nodeAt(nodes[i - 1]));
        const exit = geo.gateAngle(node, geo.nodeAt(nodes[i + 1]));
        var ang_buf: [geo.MAX_HOUSES]f64 = undefined;
        local += rg.localMinutes(node, entry, exit, geo.houseAngles(node, visit, &ang_buf));
        if (visit.len > 0) delivered[node] = true;
    }
    const service: i64 = @as(i64, loadOf(stops)) * rg.SERVICE;
    return .{
        .travel = travel,
        .local = local,
        .service = service,
        .time = @as(f64, @floatFromInt(travel)) + local + @as(f64, @floatFromInt(service)),
    };
}

// --- The move recorder (TS log/frames) ------------------------------------
// Only frame-bearing moves are recorded (2-opt reorders carry no frame and
// never appear in the replay). Snapshot TIMING mirrors each TS log.push site:
// construct snapshots BEFORE applying its merge; forcePlace snapshots the
// ORIGINAL routes list (whose kept entries alias the mutated routes in TS);
// every other site snapshots after applying, before any empty-route filter.

pub const MoveKind = enum { merge, or_opt, swap, balance, corridor };

pub const HouseKey = struct { nbhd: u8, h: u8 };

pub const MAX_TOUCHED = 32;
pub const MAX_DETAIL = 256;
pub const MAX_MOVES = 128;

pub const Move = struct {
    kind: MoveKind,
    saved: i64,
    detail: [MAX_DETAIL]u8,
    detail_len: u16,
    frame: Routes,
    touched: [MAX_TOUCHED]HouseKey,
    touched_len: u8,

    pub fn detailStr(self: *const Move) []const u8 {
        return self.detail[0..self.detail_len];
    }

    pub fn touchedKeys(self: *const Move) []const HouseKey {
        return self.touched[0..self.touched_len];
    }
};

pub const Recorder = struct {
    moves: [MAX_MOVES]Move,
    len: usize,
    start_frame: Routes, // the seeded clusters, pre-construction
    end_frame: Routes, // the final slotted routes

    pub fn reset(self: *Recorder) void {
        self.len = 0;
        self.start_frame = .{};
        self.end_frame = .{};
    }

    fn rec(self: *Recorder, kind: MoveKind, saved: i64, comptime fmt: []const u8, args: anytype, frame: *const Routes, touched: []const HouseKey) void {
        std.debug.assert(self.len < MAX_MOVES);
        const m = &self.moves[self.len];
        m.kind = kind;
        m.saved = saved;
        const d = std.fmt.bufPrint(&m.detail, fmt, args) catch unreachable;
        m.detail_len = @intCast(d.len);
        m.frame = frame.*;
        std.debug.assert(touched.len <= MAX_TOUCHED);
        @memcpy(m.touched[0..touched.len], touched);
        m.touched_len = @intCast(touched.len);
        self.len += 1;
    }

    pub fn slice(self: *const Recorder) []const Move {
        return self.moves[0..self.len];
    }
};

/// House keys of a run of stops (TS keysOf) — stop order, house order.
fn keysOf(stops: []const Stop, out: *[MAX_TOUCHED]HouseKey) []HouseKey {
    var n: usize = 0;
    for (stops) |s| {
        for (s.hs()) |h| {
            out[n] = .{ .nbhd = s.nbhd, .h = h };
            n += 1;
        }
    }
    return out[0..n];
}

/// House keys of one neighborhood's houses (TS keys).
fn keysFor(nbhd: u8, houses: []const u8, out: *[MAX_TOUCHED]HouseKey) []HouseKey {
    for (houses, 0..) |h, i| out[i] = .{ .nbhd = nbhd, .h = h };
    return out[0..houses.len];
}

/// The frame caption (TS captionOf): `{tag} · {detail}` plus a pain suffix
/// when the move saved anything (integer gains, so `> 0.5` means `>= 1`).
pub fn captionOf(m: *const Move, buf: []u8) []const u8 {
    const tag = switch (m.kind) {
        .merge => "merge",
        .or_opt => "relocate",
        .swap => "swap",
        .balance => "settle",
        .corridor => "consolidate",
    };
    if (m.saved >= 1) {
        return std.fmt.bufPrint(buf, "{s} · {s}  −{d} pain", .{ tag, m.detailStr(), m.saved }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ tag, m.detailStr() }) catch unreachable;
}

// --- Construction --------------------------------------------------------

/// Lay a and b end-to-end the cheapest of four ways (TS bestJoin) — option
/// order is the tie-break: [a b], [a rb], [ra b], [ra rb], strict <.
fn bestJoin(sub: *const Substrate, a: []const Stop, b: []const Stop) Route {
    var best: Route = undefined;
    var best_t: i64 = std.math.maxInt(i64);
    for (0..4) |opt| {
        var cand = Route{};
        if (opt < 2) {
            for (a) |s| cand.push(s);
        } else {
            var i = a.len;
            while (i > 0) : (i -= 1) cand.push(a[i - 1]);
        }
        if (opt % 2 == 0) {
            for (b) |s| cand.push(s);
        } else {
            var i = b.len;
            while (i > 0) : (i -= 1) cand.push(b[i - 1]);
        }
        const t = costOf(sub, cand.slice());
        if (t < best_t) {
            best_t = t;
            best = cand;
        }
    }
    return best;
}

const ANCHOR_SLOT = blk: {
    var slots = [_]u8{NO_PIN} ** geo.N_NODES;
    for (geo.TRUCK_ANCHORS, 0..) |a, slot| slots[a] = slot;
    break :blk slots;
};

/// Demand -> customer stops (TS customers, arcSplit permanently false: the
/// arc-construction race axis was pruned). Anchors split into a pinned seed
/// plus free overflow; everything else is one free cluster per neighborhood
/// (chunked at MAX_CAP, which no neighborhood exceeds).
fn customers(demand: *const @import("orders.zig").Demand, out: *Routes) void {
    for (0..demand.len) |di| {
        const nbhd = demand.nbhds[di];
        const idx = demand.housesOf(di);
        const slot = ANCHOR_SLOT[nbhd];
        if (slot == NO_PIN) {
            freeClusters(nbhd, idx, out);
            continue;
        }
        const seed_n = @min(idx.len, ANCHOR_PIN);
        var r = Route{};
        r.push(Stop.init(nbhd, idx[0..seed_n], slot));
        out.push(r);
        freeClusters(nbhd, idx[seed_n..], out);
    }
}

fn freeClusters(nbhd: u8, idx: []const u8, out: *Routes) void {
    var i: usize = 0;
    while (i < idx.len) : (i += geo.MAX_CAP) {
        const end = @min(idx.len, i + geo.MAX_CAP);
        var r = Route{};
        r.push(Stop.init(nbhd, idx[i..end], NO_PIN));
        out.push(r);
    }
}

/// Greedy Clarke–Wright (TS construct): repeatedly apply the best merge.
fn construct(sub: *const Substrate, routes: *Routes, force: bool, rec: ?*Recorder) void {
    while (true) {
        // Routes are unchanged during a scan; costing each once per scan is
        // value-identical to the TS's per-pair recomputation.
        var costs: [MAX_ROUTES]i64 = undefined;
        for (0..routes.len) |i| costs[i] = costOf(sub, routes.r[i].slice());
        var found = false;
        var best_saved: i64 = undefined;
        var best_i: usize = undefined;
        var best_j: usize = undefined;
        var best_merged: Route = undefined;
        for (0..routes.len) |i| {
            for (i + 1..routes.len) |j| {
                const ri = routes.r[i].slice();
                const rj = routes.r[j].slice();
                const cap = if (hasAnchor(ri)) capOf(ri) else capOf(rj);
                if (loadOf(ri) + loadOf(rj) > cap) continue;
                if (hasAnchor(ri) and hasAnchor(rj)) continue;
                const merged = bestJoin(sub, ri, rj);
                const saved = costs[i] + costs[j] - costOf(sub, merged.slice());
                if (!found or saved > best_saved) {
                    found = true;
                    best_saved = saved;
                    best_i = i;
                    best_j = j;
                    best_merged = merged;
                }
            }
        }
        if (!found) break;
        if (!force and best_saved <= 0) break;
        if (force and routes.len <= geo.TRUCKS) break;
        if (rec) |r| {
            // TS pushes the merge move BEFORE applying it — frame = pre-merge.
            var dbuf: [MAX_DETAIL]u8 = undefined;
            var dlen: usize = 0;
            for (best_merged.slice(), 0..) |s, si| {
                const name = geo.nameOf(s.nbhd);
                if (si > 0) {
                    const sep = " \xc2\xb7 "; // " · " (U+00B7), 4 bytes
                    @memcpy(dbuf[dlen .. dlen + sep.len], sep);
                    dlen += sep.len;
                }
                @memcpy(dbuf[dlen .. dlen + name.len], name);
                dlen += name.len;
            }
            var tbuf: [MAX_TOUCHED]HouseKey = undefined;
            r.rec(.merge, best_saved, "{s}", .{dbuf[0..dlen]}, routes, keysOf(best_merged.slice(), &tbuf));
        }
        routes.r[best_i] = best_merged;
        routes.removeAt(best_j);
    }
}

/// Last-resort packing when merges can't reach fleet size (TS forcePlace).
fn forcePlace(sub: *const Substrate, routes: *Routes, cost_aware: bool, rec: ?*Recorder) void {
    var kept = Routes{};
    var surplus = Routes{};
    // In the TS, kept routes ALIAS entries of the original routes array, so
    // snapshot(routes) at a log site reflects kept's mutations in the
    // original order (surplus untouched). kept_orig maps kept index -> the
    // original slot so frames can rebuild that aliased view.
    var kept_orig: [MAX_ROUTES]u8 = undefined;
    // anchored (in order) ...
    for (0..routes.len) |i| {
        if (hasAnchor(routes.r[i].slice())) {
            kept_orig[kept.len] = @intCast(i);
            kept.push(routes.r[i]);
        }
    }
    // ... plus the biggest few free clusters (stable sort by load desc,
    // original index carried through the sort).
    var clusters = Routes{};
    var cluster_orig: [MAX_ROUTES]u8 = undefined;
    for (0..routes.len) |i| {
        const r = routes.r[i];
        if (!hasAnchor(r.slice()) and r.len > 0) {
            cluster_orig[clusters.len] = @intCast(i);
            clusters.push(r);
        }
    }
    {
        var i: usize = 1;
        while (i < clusters.len) : (i += 1) {
            const key = clusters.r[i];
            const key_orig = cluster_orig[i];
            const key_load = loadOf(key.slice());
            var j = i;
            while (j > 0 and loadOf(clusters.r[j - 1].slice()) < key_load) : (j -= 1) {
                clusters.r[j] = clusters.r[j - 1];
                cluster_orig[j] = cluster_orig[j - 1];
            }
            clusters.r[j] = key;
            cluster_orig[j] = key_orig;
        }
    }
    const keep: usize = if (kept.len < geo.TRUCKS) geo.TRUCKS - kept.len else 0;
    for (0..clusters.len) |i| {
        if (i < keep) {
            kept_orig[kept.len] = cluster_orig[i];
            kept.push(clusters.r[i]);
        } else surplus.push(clusters.r[i]);
    }
    const alias_view = struct {
        fn make(orig: *const Routes, k: *const Routes, ko: *const [MAX_ROUTES]u8) Routes {
            var v = orig.*;
            for (0..k.len) |ki| v.r[ko[ki]] = k.r[ki];
            return v;
        }
    }.make;

    for (0..surplus.len) |si| {
        for (surplus.r[si].slice()) |stop| {
            var remaining = stop.hs();
            while (remaining.len > 0) {
                // Cheapest truck that can take the whole remaining piece.
                var whole: ?usize = null;
                var best_cost: i64 = std.math.maxInt(i64);
                for (0..kept.len) |k| {
                    const ks = kept.r[k].slice();
                    if (capOf(ks) - loadOf(ks) < @as(i32, @intCast(remaining.len))) continue;
                    const c = appendCost(sub, ks, stop.nbhd, remaining);
                    if (c < best_cost) {
                        best_cost = c;
                        whole = k;
                    }
                }
                if (whole) |k| {
                    kept.r[k].push(Stop.init(stop.nbhd, remaining, NO_PIN));
                    if (rec) |r| {
                        const view = alias_view(routes, &kept, &kept_orig);
                        var tbuf: [MAX_TOUCHED]HouseKey = undefined;
                        r.rec(.or_opt, 0, "capacity placement: {s} ({d}) onto a truck with room", .{ geo.nameOf(stop.nbhd), remaining.len }, &view, keysFor(stop.nbhd, remaining, &tbuf));
                    }
                    break;
                }
                // No fit: place a chunk (roomiest vs cost-aware, raced).
                var into: ?usize = null;
                var take_n: usize = 0;
                if (cost_aware) {
                    var bestc: i64 = std.math.maxInt(i64);
                    for (0..kept.len) |k| {
                        const ks = kept.r[k].slice();
                        const free = capOf(ks) - loadOf(ks);
                        if (free <= 0) continue;
                        const n: usize = @min(@as(usize, @intCast(free)), remaining.len);
                        const c = appendCost(sub, ks, stop.nbhd, remaining[0..n]);
                        if (c < bestc) {
                            bestc = c;
                            into = k;
                            take_n = n;
                        }
                    }
                } else {
                    var room: i32 = 0;
                    for (0..kept.len) |k| {
                        const ks = kept.r[k].slice();
                        const free = capOf(ks) - loadOf(ks);
                        if (free > room) {
                            room = free;
                            into = k;
                            take_n = @min(@as(usize, @intCast(free)), remaining.len);
                        }
                    }
                }
                if (into == null or take_n == 0) std.debug.panic("forcePlace: no truck has room", .{});
                const take = remaining[0..take_n];
                remaining = remaining[take_n..];
                kept.r[into.?].push(Stop.init(stop.nbhd, take, NO_PIN));
                if (rec) |r| {
                    const view = alias_view(routes, &kept, &kept_orig);
                    var tbuf: [MAX_TOUCHED]HouseKey = undefined;
                    r.rec(.or_opt, 0, "capacity split: {s} {d} tote(s) onto a truck with room", .{ geo.nameOf(stop.nbhd), take.len }, &view, keysFor(stop.nbhd, take, &tbuf));
                }
            }
        }
    }
    routes.* = kept;
}

fn appendCost(sub: *const Substrate, route: []const Stop, nbhd: u8, houses: []const u8) i64 {
    var cand = Route.fromSlice(route);
    cand.push(Stop.init(nbhd, houses, NO_PIN));
    return costOf(sub, cand.slice()) - costOf(sub, route);
}

/// Stable sort by load, descending (JS Array.sort is stable).
fn sortRoutesByLoadDesc(rs: *Routes) void {
    // Insertion sort: stable, tiny n.
    var i: usize = 1;
    while (i < rs.len) : (i += 1) {
        const key = rs.r[i];
        const key_load = loadOf(key.slice());
        var j = i;
        while (j > 0 and loadOf(rs.r[j - 1].slice()) < key_load) : (j -= 1) {
            rs.r[j] = rs.r[j - 1];
        }
        rs.r[j] = key;
    }
}

/// Insert `stop` at its cheapest position, ties -> earliest (TS insertBest).
fn insertBest(sub: *const Substrate, route: []const Stop, stop: Stop) Route {
    var best: Route = undefined;
    var best_cost: i64 = std.math.maxInt(i64);
    for (0..route.len + 1) |p| {
        var cand = Route.fromSlice(route[0..p]);
        cand.push(stop);
        for (route[p..]) |s| cand.push(s);
        const c = costOf(sub, cand.slice());
        if (c < best_cost) {
            best_cost = c;
            best = cand;
        }
    }
    return best;
}

/// Place the deferred FC-adjacent clusters into leftover slack (TS placeDeferred).
fn placeDeferred(sub: *const Substrate, routes: *Routes, deferred: *const Routes, cost_aware: bool, rec: ?*Recorder) void {
    // Stable sort by orders desc — deferred entries are single-stop routes.
    var ordered = deferred.*;
    var i: usize = 1;
    while (i < ordered.len) : (i += 1) {
        const key = ordered.r[i];
        var j = i;
        while (j > 0 and ordered.r[j - 1].stops[0].nh < key.stops[0].nh) : (j -= 1) {
            ordered.r[j] = ordered.r[j - 1];
        }
        ordered.r[j] = key;
    }

    for (0..ordered.len) |di| {
        const stop = ordered.r[di].stops[0];
        var remaining = stop.hs();
        while (remaining.len > 0) {
            var best_ri: ?usize = null;
            var best_route: Route = undefined;
            var best_delta: i64 = std.math.maxInt(i64);
            for (0..routes.len) |ri| {
                const rs = routes.r[ri].slice();
                if (capOf(rs) - loadOf(rs) < @as(i32, @intCast(remaining.len))) continue;
                const cand = insertBest(sub, rs, Stop.init(stop.nbhd, remaining, NO_PIN));
                const delta = costOf(sub, cand.slice()) - costOf(sub, rs);
                if (delta < best_delta) {
                    best_delta = delta;
                    best_ri = ri;
                    best_route = cand;
                }
            }
            if (best_ri) |ri| {
                routes.r[ri] = best_route;
                if (rec) |r| {
                    var tbuf: [MAX_TOUCHED]HouseKey = undefined;
                    r.rec(.or_opt, 0, "deferred fill: {s} ({d}) into slack", .{ geo.nameOf(stop.nbhd), remaining.len }, routes, keysFor(stop.nbhd, remaining, &tbuf));
                }
                break;
            }
            // No single truck fits it whole — chunk (same race as forcePlace).
            var ri: ?usize = null;
            var take_n: usize = 0;
            if (cost_aware) {
                var bestc: i64 = std.math.maxInt(i64);
                for (0..routes.len) |k| {
                    const ks = routes.r[k].slice();
                    const free = capOf(ks) - loadOf(ks);
                    if (free <= 0) continue;
                    const n: usize = @min(@as(usize, @intCast(free)), remaining.len);
                    const cand = insertBest(sub, ks, Stop.init(stop.nbhd, remaining[0..n], NO_PIN));
                    const delta = costOf(sub, cand.slice()) - costOf(sub, ks);
                    if (delta < bestc) {
                        bestc = delta;
                        ri = k;
                        take_n = n;
                    }
                }
            } else {
                var room: i32 = 0;
                for (0..routes.len) |k| {
                    const ks = routes.r[k].slice();
                    const free = capOf(ks) - loadOf(ks);
                    if (free > room) {
                        room = free;
                        ri = k;
                        take_n = @min(@as(usize, @intCast(free)), remaining.len);
                    }
                }
            }
            if (ri == null or take_n == 0) std.debug.panic("placeDeferred: no truck has room", .{});
            const take = remaining[0..take_n];
            remaining = remaining[take_n..];
            routes.r[ri.?] = insertBest(sub, routes.r[ri.?].slice(), Stop.init(stop.nbhd, take, NO_PIN));
            if (rec) |r| {
                var tbuf: [MAX_TOUCHED]HouseKey = undefined;
                r.rec(.or_opt, 0, "deferred split: {s} {d} tote(s) into slack", .{ geo.nameOf(stop.nbhd), take.len }, routes, keysFor(stop.nbhd, take, &tbuf));
            }
        }
    }
}

// --- Local search --------------------------------------------------------

/// 2-opt: reverse sub-segments while it cuts cost (TS twoOpt). Applies each
/// winning reversal immediately and keeps scanning.
fn twoOpt(sub: *const Substrate, route: *Route) void {
    var improved = true;
    // `before` is always the CURRENT route's cost (the TS recomputes it per
    // candidate pair; caching + updating on accept is value-identical).
    var before = costOf(sub, route.slice());
    while (improved) {
        improved = false;
        var i: usize = 0;
        while (i + 1 < route.len) : (i += 1) {
            var k = i + 1;
            while (k < route.len) : (k += 1) {
                var cand = route.*;
                std.mem.reverse(Stop, cand.stops[i .. k + 1]);
                const cand_cost = costOf(sub, cand.slice());
                if (before - cand_cost >= 1) {
                    route.* = cand;
                    before = cand_cost;
                    improved = true;
                }
            }
        }
    }
}

/// Or-opt: relocate one stop to the best slot in any route (TS orOpt).
fn orOpt(sub: *const Substrate, routes: *Routes, rec: ?*Recorder) void {
    var improved = true;
    while (improved) {
        improved = false;
        var r: usize = 0;
        while (r < routes.len) : (r += 1) {
            var s: usize = 0;
            while (s < routes.r[r].len) : (s += 1) {
                const stop = routes.r[r].stops[s];
                if (stop.pin != NO_PIN) continue;
                var without = routes.r[r];
                without.removeAt(s);
                const drop = costOf(sub, routes.r[r].slice()) - costOf(sub, without.slice());

                var found = false;
                var best_gain: i64 = undefined;
                var best_t: usize = undefined;
                var best_pos: usize = undefined;
                for (0..routes.len) |t| {
                    if (t == r) continue;
                    const ts = routes.r[t].slice();
                    if (loadOf(ts) + stop.nh > capOf(ts)) continue;
                    const base_t = costOf(sub, ts);
                    for (0..ts.len + 1) |pos| {
                        var into = routes.r[t];
                        into.insertAt(pos, stop);
                        const gain = drop - (costOf(sub, into.slice()) - base_t);
                        if (gain >= 1 and (!found or gain > best_gain)) {
                            found = true;
                            best_gain = gain;
                            best_t = t;
                            best_pos = pos;
                        }
                    }
                }
                if (found) {
                    routes.r[r] = without;
                    routes.r[best_t].insertAt(best_pos, stop);
                    if (rec) |rr| {
                        var tbuf: [MAX_TOUCHED]HouseKey = undefined;
                        rr.rec(.or_opt, best_gain, "moved {s} to another truck", .{geo.nameOf(stop.nbhd)}, routes, keysOf(&.{stop}, &tbuf));
                    }
                    improved = true;
                }
            }
        }
        if (improved) routes.dropEmpties();
    }
}

/// Remove stop `rm`, reinsert `add` at its cheapest slot, ties -> earliest
/// (TS reinsert).
fn reinsert(sub: *const Substrate, route: []const Stop, rm: usize, add: Stop) Route {
    var base = Route.fromSlice(route);
    base.removeAt(rm);
    return insertBest(sub, base.slice(), add);
}

/// Inter-route exchange: trade one stop between two trucks (TS exchange).
fn exchange(sub: *const Substrate, routes: *Routes, rec: ?*Recorder) void {
    var guard: usize = 0;
    while (guard < 200) : (guard += 1) {
        var costs: [MAX_ROUTES]i64 = undefined;
        for (0..routes.len) |i| costs[i] = costOf(sub, routes.r[i].slice());
        var found = false;
        var best_gain: i64 = undefined;
        var best_a: usize = undefined;
        var best_b: usize = undefined;
        var best_ra: Route = undefined;
        var best_rb: Route = undefined;
        var best_sa: Stop = undefined;
        var best_sb: Stop = undefined;
        for (0..routes.len) |a| {
            for (a + 1..routes.len) |b| {
                const ras = routes.r[a].slice();
                const rbs = routes.r[b].slice();
                const base = costs[a] + costs[b];
                for (0..ras.len) |i| {
                    const sa = ras[i];
                    if (sa.pin != NO_PIN) continue;
                    for (0..rbs.len) |j| {
                        const sb = rbs[j];
                        if (sb.pin != NO_PIN or sa.nbhd == sb.nbhd) continue;
                        if (loadOf(ras) - sa.nh + sb.nh > capOf(ras)) continue;
                        if (loadOf(rbs) - sb.nh + sa.nh > capOf(rbs)) continue;
                        const ra = coalesceStops(reinsert(sub, ras, i, sb).slice());
                        const rb = coalesceStops(reinsert(sub, rbs, j, sa).slice());
                        const gain = base - (costOf(sub, ra.slice()) + costOf(sub, rb.slice()));
                        if (gain >= 1 and (!found or gain > best_gain)) {
                            found = true;
                            best_gain = gain;
                            best_a = a;
                            best_b = b;
                            best_ra = ra;
                            best_rb = rb;
                            best_sa = sa;
                            best_sb = sb;
                        }
                    }
                }
            }
        }
        if (!found) break;
        routes.r[best_a] = best_ra;
        routes.r[best_b] = best_rb;
        if (rec) |rr| {
            var tbuf: [MAX_TOUCHED]HouseKey = undefined;
            rr.rec(.swap, best_gain, "traded a stop between two trucks", .{}, routes, keysOf(&.{ best_sa, best_sb }, &tbuf));
        }
    }
}

/// Insert coalescing against every position, ties -> the APPEND candidate
/// (TS cheapestInsert — it seeds with the append and scans p < route.length).
fn cheapestInsert(sub: *const Substrate, route: []const Stop, add: Stop) Route {
    var best = Route.fromSlice(route);
    best.push(add);
    best = coalesceStops(best.slice());
    var best_cost = costOf(sub, best.slice());
    for (0..route.len) |p| {
        var cand = Route.fromSlice(route[0..p]);
        cand.push(add);
        for (route[p..]) |s| cand.push(s);
        const co = coalesceStops(cand.slice());
        const c = costOf(sub, co.slice());
        if (c < best_cost) {
            best_cost = c;
            best = co;
        }
    }
    return best;
}

/// One stop per neighborhood, first occurrence keeps the slot (TS coalesceStops).
fn coalesceStops(route: []const Stop) Route {
    var out = Route{};
    var at = [_]u8{0xff} ** geo.N_NODES;
    for (route) |s| {
        if (at[s.nbhd] != 0xff) {
            const e = &out.stops[at[s.nbhd]];
            @memcpy(e.houses[e.nh .. e.nh + s.nh], s.hs());
            e.nh += s.nh;
            if (s.pin != NO_PIN) e.pin = s.pin;
        } else {
            at[s.nbhd] = out.len;
            out.push(Stop.init(s.nbhd, s.hs(), s.pin));
        }
    }
    return out;
}

/// Cost of a route as the pipeline will leave it — after a twoOpt tidy
/// (TS tidiedCost).
fn tidiedCost(sub: *const Substrate, stops: []const Stop) i64 {
    var copy = Route.fromSlice(stops);
    twoOpt(sub, &copy);
    return costOf(sub, copy.slice());
}

// --- Post-slot passes ----------------------------------------------------

const N_SLOTS = geo.TRUCKS;

/// The 8 slots as a Routes snapshot (empty slots included — TS snapshot(bySlot)).
fn slotsFrame(by_slot: *const [N_SLOTS]Route) Routes {
    var out = Routes{};
    for (by_slot) |r| out.push(r);
    return out;
}

/// Corridor repair (TS corridorRepair): consolidate a threaded-through
/// neighborhood onto the truck already passing it — absorb, trade, or
/// split-swap. `shackle` = capacity-neutral splits only (the conservative
/// half of the corridor race).
fn corridorRepair(sub: *const Substrate, by_slot: *[N_SLOTS]Route, shackle: bool, rec: ?*Recorder) void {
    var guard: usize = 0;
    while (guard < 50) : (guard += 1) {
        var tidied: [N_SLOTS]i64 = undefined;
        for (0..N_SLOTS) |i| tidied[i] = tidiedCost(sub, by_slot[i].slice());
        var found = false;
        var best_gain: i64 = undefined;
        var best_t: usize = undefined;
        var best_tp: usize = undefined;
        var best_nt: Route = undefined;
        var best_ntp: Route = undefined;
        var best_b: u8 = undefined;
        var best_via: [64]u8 = undefined;
        var best_via_len: usize = undefined;
        var best_touched: [MAX_TOUCHED]HouseKey = undefined;
        var best_touched_len: usize = undefined;

        for (0..N_SLOTS) |t| {
            if (by_slot[t].len == 0) continue;
            var delivered = [_]bool{false} ** geo.N_NODES;
            for (by_slot[t].slice()) |s| delivered[s.nbhd] = true;
            var pbuf: [MAX_PATH_NODES]u8 = undefined;
            const nodes = pathNodes(sub, by_slot[t].slice(), &pbuf);
            // threaded = insertion-order set of pass-through neighborhoods.
            var threaded: [MAX_PATH_NODES]u8 = undefined;
            var tlen: usize = 0;
            var seen = [_]bool{false} ** geo.N_NODES;
            for (nodes) |node| {
                if (node != geo.FC and !delivered[node] and !seen[node]) {
                    seen[node] = true;
                    threaded[tlen] = node;
                    tlen += 1;
                }
            }
            for (threaded[0..tlen]) |B| {
                var tp: ?usize = null;
                for (0..N_SLOTS) |ri| {
                    for (by_slot[ri].slice()) |s| {
                        if (s.nbhd == B) {
                            tp = ri;
                            break;
                        }
                    }
                    if (tp != null) break;
                }
                if (tp == null or tp.? == t) continue;
                const tpi = tp.?;
                var b_stop: Stop = undefined;
                for (by_slot[tpi].slice()) |s| {
                    if (s.nbhd == B) {
                        b_stop = s;
                        break;
                    }
                }
                if (b_stop.pin != NO_PIN) continue;
                const base = tidied[t] + tidied[tpi];
                var without = Route{};
                for (by_slot[tpi].slice()) |s| {
                    if (s.nbhd != B) without.push(s);
                }
                // (a) absorb the middle, if there's room.
                if (loadOf(by_slot[t].slice()) + b_stop.nh <= geo.TRUCK_CAPS[t]) {
                    const nt = cheapestInsert(sub, by_slot[t].slice(), b_stop);
                    const gain = base - (tidiedCost(sub, nt.slice()) + tidiedCost(sub, without.slice()));
                    if (gain >= 1 and (!found or gain > best_gain)) {
                        found = true;
                        best_gain = gain;
                        best_t = t;
                        best_tp = tpi;
                        best_nt = nt;
                        best_ntp = without;
                        best_b = B;
                        best_via_len = (std.fmt.bufPrint(&best_via, "absorbed", .{}) catch unreachable).len;
                        var tb: [MAX_TOUCHED]HouseKey = undefined;
                        const tk = keysOf(&.{b_stop}, &tb);
                        @memcpy(best_touched[0..tk.len], tk);
                        best_touched_len = tk.len;
                    }
                }
                // (b) full: trade one of t's stops to B's truck, take B instead.
                for (0..by_slot[t].len) |si| {
                    const S = by_slot[t].stops[si];
                    if (S.pin != NO_PIN) continue;
                    if (loadOf(by_slot[t].slice()) - S.nh + b_stop.nh > geo.TRUCK_CAPS[t]) continue;
                    if (loadOf(by_slot[tpi].slice()) - b_stop.nh + S.nh > geo.TRUCK_CAPS[tpi]) continue;
                    var t_without = by_slot[t];
                    removeByNbhd(&t_without, S.nbhd);
                    const nt = cheapestInsert(sub, t_without.slice(), b_stop);
                    const ntp = cheapestInsert(sub, without.slice(), S);
                    const gain = base - (tidiedCost(sub, nt.slice()) + tidiedCost(sub, ntp.slice()));
                    if (gain >= 1 and (!found or gain > best_gain)) {
                        found = true;
                        best_gain = gain;
                        best_t = t;
                        best_tp = tpi;
                        best_nt = nt;
                        best_ntp = ntp;
                        best_b = B;
                        best_via_len = (std.fmt.bufPrint(&best_via, "trading {s}", .{geo.nameOf(S.nbhd)}) catch unreachable).len;
                        var tb: [MAX_TOUCHED]HouseKey = undefined;
                        const tk = keysOf(&.{ b_stop, S }, &tb);
                        @memcpy(best_touched[0..tk.len], tk);
                        best_touched_len = tk.len;
                    }
                }
                // (c) split-swap: trade X away and carve a slice of B onto t.
                for (0..by_slot[t].len) |xi| {
                    const X = by_slot[t].stops[xi];
                    if (X.pin != NO_PIN) continue;
                    const k_min: i32 = @max(1, loadOf(by_slot[tpi].slice()) - geo.TRUCK_CAPS[tpi] + X.nh);
                    const k_max: i32 = @min(@as(i32, b_stop.nh) - 1, geo.TRUCK_CAPS[t] - loadOf(by_slot[t].slice()) + X.nh);
                    const lo: i32 = if (shackle) @max(k_min, @as(i32, X.nh)) else k_min;
                    const hi: i32 = if (shackle) @min(k_max, @as(i32, X.nh)) else k_max;
                    var k = lo;
                    while (k <= hi) : (k += 1) {
                        const ku: usize = @intCast(k);
                        const take = Stop.init(b_stop.nbhd, b_stop.hs()[0..ku], NO_PIN);
                        const rest = Stop.init(b_stop.nbhd, b_stop.hs()[ku..], NO_PIN);
                        var t_less_x = Route{};
                        for (by_slot[t].slice(), 0..) |s, i| {
                            if (i != xi) t_less_x.push(s);
                        }
                        const nt = cheapestInsert(sub, t_less_x.slice(), take);
                        var tp_swapped = by_slot[tpi];
                        for (0..tp_swapped.len) |i| {
                            if (tp_swapped.stops[i].nbhd == B) tp_swapped.stops[i] = rest;
                        }
                        const ntp = cheapestInsert(sub, tp_swapped.slice(), X);
                        const gain = base - (tidiedCost(sub, nt.slice()) + tidiedCost(sub, ntp.slice()));
                        if (gain >= 1 and (!found or gain > best_gain)) {
                            found = true;
                            best_gain = gain;
                            best_t = t;
                            best_tp = tpi;
                            best_nt = nt;
                            best_ntp = ntp;
                            best_b = B;
                            best_via_len = (std.fmt.bufPrint(&best_via, "split {d}/{d}, trading {s}", .{ ku, b_stop.nh - ku, geo.nameOf(X.nbhd) }) catch unreachable).len;
                            var tb: [MAX_TOUCHED]HouseKey = undefined;
                            const tk = keysOf(&.{ X, take }, &tb);
                            @memcpy(best_touched[0..tk.len], tk);
                            best_touched_len = tk.len;
                        }
                    }
                }
            }
        }
        if (!found) break;
        by_slot[best_t] = best_nt;
        by_slot[best_tp] = best_ntp;
        if (rec) |rr| {
            const frame = slotsFrame(by_slot);
            rr.rec(.corridor, best_gain, "consolidated {s} onto the truck passing through ({s})", .{ geo.nameOf(best_b), best_via[0..best_via_len] }, &frame, best_touched[0..best_touched_len]);
        }
    }
}

/// Remove the (single) stop with this neighborhood — the TS filter-by-identity
/// sites all remove exactly one stop; asserts keep that assumption honest.
fn removeByNbhd(route: *Route, nbhd: u8) void {
    var w: u8 = 0;
    for (0..route.len) |i| {
        if (route.stops[i].nbhd != nbhd) {
            route.stops[w] = route.stops[i];
            w += 1;
        }
    }
    std.debug.assert(w == route.len - 1);
    route.len = w;
}

/// Post-slot relocate + swap with exact slot caps (TS postSlotLocalSearch).
fn postSlotLocalSearch(sub: *const Substrate, by_slot: *[N_SLOTS]Route, rec: ?*Recorder) void {
    var guard: usize = 0;
    while (guard < 200) : (guard += 1) {
        var cur: [N_SLOTS]i64 = undefined;
        for (0..N_SLOTS) |i| cur[i] = tidiedCost(sub, by_slot[i].slice());
        var found = false;
        var best_gain: i64 = undefined;
        var best_a: usize = undefined;
        var best_b: usize = undefined;
        var best_ra: Route = undefined;
        var best_rb: Route = undefined;
        var best_is_swap: bool = undefined;
        var best_touched: [MAX_TOUCHED]HouseKey = undefined;
        var best_touched_len: usize = undefined;

        // Relocate a -> b.
        for (0..N_SLOTS) |a| {
            if (by_slot[a].len == 0) continue;
            for (0..by_slot[a].len) |si| {
                const stop = by_slot[a].stops[si];
                if (stop.pin != NO_PIN) continue;
                for (0..N_SLOTS) |b| {
                    if (b == a) continue;
                    if (loadOf(by_slot[b].slice()) + stop.nh > geo.TRUCK_CAPS[b]) continue;
                    var ra = Route{};
                    for (by_slot[a].slice(), 0..) |s, i| {
                        if (i != si) ra.push(s);
                    }
                    const rb = cheapestInsert(sub, by_slot[b].slice(), stop);
                    const gain = cur[a] + cur[b] -
                        (tidiedCost(sub, ra.slice()) + tidiedCost(sub, rb.slice()));
                    if (gain >= 1 and (!found or gain > best_gain)) {
                        found = true;
                        best_gain = gain;
                        best_a = a;
                        best_b = b;
                        best_ra = ra;
                        best_rb = rb;
                        best_is_swap = false;
                        var tb: [MAX_TOUCHED]HouseKey = undefined;
                        const tk = keysOf(&.{stop}, &tb);
                        @memcpy(best_touched[0..tk.len], tk);
                        best_touched_len = tk.len;
                    }
                }
            }
        }
        // Swap between a and b.
        for (0..N_SLOTS) |a| {
            for (a + 1..N_SLOTS) |b| {
                if (by_slot[a].len == 0 or by_slot[b].len == 0) continue;
                for (0..by_slot[a].len) |i| {
                    const sa = by_slot[a].stops[i];
                    if (sa.pin != NO_PIN) continue;
                    for (0..by_slot[b].len) |j| {
                        const sb = by_slot[b].stops[j];
                        if (sb.pin != NO_PIN or sa.nbhd == sb.nbhd) continue;
                        if (loadOf(by_slot[a].slice()) - sa.nh + sb.nh > geo.TRUCK_CAPS[a]) continue;
                        if (loadOf(by_slot[b].slice()) - sb.nh + sa.nh > geo.TRUCK_CAPS[b]) continue;
                        const ra = coalesceStops(reinsert(sub, by_slot[a].slice(), i, sb).slice());
                        const rb = coalesceStops(reinsert(sub, by_slot[b].slice(), j, sa).slice());
                        const gain = cur[a] + cur[b] -
                            (tidiedCost(sub, ra.slice()) + tidiedCost(sub, rb.slice()));
                        if (gain >= 1 and (!found or gain > best_gain)) {
                            found = true;
                            best_gain = gain;
                            best_a = a;
                            best_b = b;
                            best_ra = ra;
                            best_rb = rb;
                            best_is_swap = true;
                            var tb: [MAX_TOUCHED]HouseKey = undefined;
                            const tk = keysOf(&.{ sa, sb }, &tb);
                            @memcpy(best_touched[0..tk.len], tk);
                            best_touched_len = tk.len;
                        }
                    }
                }
            }
        }

        if (!found) break;
        by_slot[best_a] = best_ra;
        by_slot[best_b] = best_rb;
        if (rec) |rr| {
            const frame = slotsFrame(by_slot);
            if (best_is_swap) {
                rr.rec(.swap, best_gain, "traded a stop between trucks {d} and {d}", .{ best_a + 1, best_b + 1 }, &frame, best_touched[0..best_touched_len]);
            } else {
                rr.rec(.or_opt, best_gain, "relocated a stop to truck {d}", .{best_b + 1}, &frame, best_touched[0..best_touched_len]);
            }
        }
    }
}

/// Arc-rebalance (TS arcRebalance): a relocate/swap rescued by shifting one
/// arc of a filler from the overfull side to the other.
fn arcRebalance(sub: *const Substrate, by_slot: *[N_SLOTS]Route, rec: ?*Recorder) void {
    var guard: usize = 0;
    while (guard < 200) : (guard += 1) {
        var cur: [N_SLOTS]i64 = undefined;
        for (0..N_SLOTS) |i| cur[i] = tidiedCost(sub, by_slot[i].slice());
        var found = false;
        var best_gain: i64 = undefined;
        var best_a: usize = undefined;
        var best_b: usize = undefined;
        var best_ra: Route = undefined;
        var best_rb: Route = undefined;
        var best_touched: [MAX_TOUCHED]HouseKey = undefined;
        var best_touched_len: usize = undefined;

        const Ctx = struct {
            sub: *const Substrate,
            by_slot: *[N_SLOTS]Route,
            cur: *const [N_SLOTS]i64,
            found: *bool,
            best_gain: *i64,
            best_a: *usize,
            best_b: *usize,
            best_ra: *Route,
            best_rb: *Route,
            best_touched: *[MAX_TOUCHED]HouseKey,
            best_touched_len: *usize,

            fn score(ctx: @This(), a: usize, b: usize, ra: Route, rb: Route, touched: []const HouseKey) void {
                if (loadOf(ra.slice()) > geo.TRUCK_CAPS[a] or loadOf(rb.slice()) > geo.TRUCK_CAPS[b]) return;
                const gain = ctx.cur[a] + ctx.cur[b] -
                    (tidiedCost(ctx.sub, ra.slice()) + tidiedCost(ctx.sub, rb.slice()));
                if (gain >= 1 and (!ctx.found.* or gain > ctx.best_gain.*)) {
                    ctx.found.* = true;
                    ctx.best_gain.* = gain;
                    ctx.best_a.* = a;
                    ctx.best_b.* = b;
                    ctx.best_ra.* = ra;
                    ctx.best_rb.* = rb;
                    @memcpy(ctx.best_touched[0..touched.len], touched);
                    ctx.best_touched_len.* = touched.len;
                }
            }

            fn withRescue(ctx: @This(), a: usize, b: usize, ra0: Route, rb0: Route, touched: []const HouseKey) void {
                const la = loadOf(ra0.slice());
                const lb = loadOf(rb0.slice());
                if (la <= geo.TRUCK_CAPS[a] and lb <= geo.TRUCK_CAPS[b]) {
                    ctx.score(a, b, ra0, rb0, touched);
                    return;
                }
                const over_a = la > geo.TRUCK_CAPS[a] and lb <= geo.TRUCK_CAPS[b];
                const over_b = lb > geo.TRUCK_CAPS[b] and la <= geo.TRUCK_CAPS[a];
                if (!over_a and !over_b) return;
                const over = if (over_a) ra0 else rb0;
                const under = if (over_a) rb0 else ra0;
                const cap_under: i32 = if (over_a) geo.TRUCK_CAPS[b] else geo.TRUCK_CAPS[a];
                const need: i32 = loadOf(over.slice()) - (if (over_a) @as(i32, geo.TRUCK_CAPS[a]) else geo.TRUCK_CAPS[b]);
                for (0..over.len) |fi| {
                    const F = over.stops[fi];
                    if (F.pin != NO_PIN) continue;
                    const groups = geo.arcGroups(F.nbhd, F.hs());
                    for (0..groups.count) |g| {
                        const arc = groups.group(g);
                        if (@as(i32, @intCast(arc.len)) < need or arc.len >= F.nh) continue;
                        if (loadOf(under.slice()) + @as(i32, @intCast(arc.len)) > cap_under) continue;
                        var in_arc = [_]bool{false} ** geo.MAX_HOUSES;
                        for (arc) |h| {
                            for (F.hs(), 0..) |fh, k| {
                                if (fh == h) in_arc[k] = true;
                            }
                        }
                        var keep: [geo.MAX_HOUSES]u8 = undefined;
                        var keep_n: u8 = 0;
                        for (F.hs(), 0..) |fh, k| {
                            if (!in_arc[k]) {
                                keep[keep_n] = fh;
                                keep_n += 1;
                            }
                        }
                        var new_over_raw = Route{};
                        for (over.slice(), 0..) |s, i| {
                            if (i == fi) {
                                if (keep_n > 0) new_over_raw.push(Stop.init(s.nbhd, keep[0..keep_n], s.pin));
                            } else if (s.nh > 0) {
                                new_over_raw.push(s);
                            }
                        }
                        const new_over = coalesceStops(new_over_raw.slice());
                        const new_under = cheapestInsert(ctx.sub, under.slice(), Stop.init(F.nbhd, arc, NO_PIN));
                        // touched = the base move's keys + the shifted arc (TS order).
                        var ext: [MAX_TOUCHED]HouseKey = undefined;
                        @memcpy(ext[0..touched.len], touched);
                        var en = touched.len;
                        for (arc) |h| {
                            ext[en] = .{ .nbhd = F.nbhd, .h = h };
                            en += 1;
                        }
                        if (over_a) {
                            ctx.score(a, b, new_over, new_under, ext[0..en]);
                        } else {
                            ctx.score(a, b, new_under, new_over, ext[0..en]);
                        }
                    }
                }
            }
        };
        const ctx = Ctx{
            .sub = sub,
            .by_slot = by_slot,
            .cur = &cur,
            .found = &found,
            .best_gain = &best_gain,
            .best_a = &best_a,
            .best_b = &best_b,
            .best_ra = &best_ra,
            .best_rb = &best_rb,
            .best_touched = &best_touched,
            .best_touched_len = &best_touched_len,
        };

        // Relocate candidates, then swap candidates — TS scan order.
        for (0..N_SLOTS) |a| {
            if (by_slot[a].len == 0) continue;
            for (0..by_slot[a].len) |si| {
                const stop = by_slot[a].stops[si];
                if (stop.pin != NO_PIN) continue;
                for (0..N_SLOTS) |b| {
                    if (b == a) continue;
                    var ra0 = Route{};
                    for (by_slot[a].slice(), 0..) |s, i| {
                        if (i != si) ra0.push(s);
                    }
                    var tb: [MAX_TOUCHED]HouseKey = undefined;
                    ctx.withRescue(a, b, ra0, cheapestInsert(sub, by_slot[b].slice(), stop), keysOf(&.{stop}, &tb));
                }
            }
        }
        for (0..N_SLOTS) |a| {
            for (a + 1..N_SLOTS) |b| {
                if (by_slot[a].len == 0 or by_slot[b].len == 0) continue;
                for (0..by_slot[a].len) |i| {
                    const sa = by_slot[a].stops[i];
                    if (sa.pin != NO_PIN) continue;
                    for (0..by_slot[b].len) |j| {
                        const sb = by_slot[b].stops[j];
                        if (sb.pin != NO_PIN or sa.nbhd == sb.nbhd) continue;
                        var tb: [MAX_TOUCHED]HouseKey = undefined;
                        ctx.withRescue(a, b, coalesceStops(reinsert(sub, by_slot[a].slice(), i, sb).slice()), coalesceStops(reinsert(sub, by_slot[b].slice(), j, sa).slice()), keysOf(&.{ sa, sb }, &tb));
                    }
                }
            }
        }

        if (!found) break;
        by_slot[best_a] = best_ra;
        by_slot[best_b] = best_rb;
        if (rec) |rr| {
            const frame = slotsFrame(by_slot);
            rr.rec(.or_opt, best_gain, "arc-rebalance between trucks {d} and {d}", .{ best_a + 1, best_b + 1 }, &frame, best_touched[0..best_touched_len]);
        }
    }
}

// --- Pre-slot balance & split passes -------------------------------------

/// Population stdev, float ops in TS reduce order.
fn stdev(times: []const f64) f64 {
    if (times.len == 0) return 0;
    var sum: f64 = 0;
    for (times) |t| sum += t;
    const mean = sum / @as(f64, @floatFromInt(times.len));
    var acc: f64 = 0;
    for (times) |t| acc += (t - mean) * (t - mean);
    return @sqrt(acc / @as(f64, @floatFromInt(times.len)));
}

/// Free tie-breaks: relocate when total pain is unchanged but the spread
/// shrinks (TS rebalance — |dTotal| > 0.75 on integers means dTotal must be 0).
fn rebalance(sub: *const Substrate, routes: *Routes, rec: ?*Recorder) void {
    var guard: usize = 0;
    while (guard < 400) : (guard += 1) {
        var times: [MAX_ROUTES]i64 = undefined;
        for (0..routes.len) |i| times[i] = costOf(sub, routes.r[i].slice());
        var t0: [MAX_ROUTES]f64 = undefined;
        var t0n: usize = 0;
        for (0..routes.len) |i| {
            if (routes.r[i].len > 0) {
                t0[t0n] = @floatFromInt(times[i]);
                t0n += 1;
            }
        }
        const spread0 = stdev(t0[0..t0n]);

        var found = false;
        var best_dspread: f64 = undefined;
        var best_r: usize = undefined;
        var best_s: usize = undefined;
        var best_t: usize = undefined;
        var best_pos: usize = undefined;

        for (0..routes.len) |r| {
            for (0..routes.r[r].len) |s| {
                const stop = routes.r[r].stops[s];
                if (stop.pin != NO_PIN) continue;
                var without = routes.r[r];
                without.removeAt(s);
                const new_rcost = costOf(sub, without.slice());
                for (0..routes.len) |t| {
                    if (t == r) continue;
                    const ts = routes.r[t].slice();
                    if (loadOf(ts) + stop.nh > capOf(ts)) continue;
                    for (0..ts.len + 1) |pos| {
                        var into = routes.r[t];
                        into.insertAt(pos, stop);
                        const new_tcost = costOf(sub, into.slice());
                        const d_total = new_rcost - times[r] + (new_tcost - times[t]);
                        if (d_total != 0) continue; // TIE = 0.75 on integer deltas
                        var after: [MAX_ROUTES]f64 = undefined;
                        var an: usize = 0;
                        for (0..routes.len) |i| {
                            const nt: i64 = if (i == r) new_rcost else if (i == t) new_tcost else times[i];
                            const alive = if (i == r) without.len > 0 else true;
                            if (alive and routes.r[i].len > 0) {
                                after[an] = @floatFromInt(nt);
                                an += 1;
                            }
                        }
                        const d_spread = stdev(after[0..an]) - spread0;
                        if (d_spread >= -1e-6) continue;
                        if (!found or d_spread < best_dspread) {
                            found = true;
                            best_dspread = d_spread;
                            best_r = r;
                            best_s = s;
                            best_t = t;
                            best_pos = pos;
                        }
                    }
                }
            }
        }

        if (!found) break;
        const stop = routes.r[best_r].stops[best_s];
        routes.r[best_r].removeAt(best_s);
        routes.r[best_t].insertAt(best_pos, stop);
        if (rec) |rr| {
            // saved = -dTotal = 0 for a tie-break; frame BEFORE the empty filter.
            var tbuf: [MAX_TOUCHED]HouseKey = undefined;
            rr.rec(.balance, 0, "tie-break: {s} \xe2\x86\x92 another truck", .{geo.nameOf(stop.nbhd)}, routes, keysOf(&.{stop}, &tbuf));
        }
        routes.dropEmpties();
    }
}

const ArcSubsets = struct {
    houses: [40 * 3]u8 = undefined,
    lens: [40]u8 = undefined,
    count: u8 = 0,

    fn subset(self: *const ArcSubsets, i: usize) []const u8 {
        return self.houses[i * 3 .. i * 3 + self.lens[i]];
    }

    fn add(self: *ArcSubsets, s: []const u8) void {
        @memcpy(self.houses[self.count * 3 .. self.count * 3 + s.len], s);
        self.lens[self.count] = @intCast(s.len);
        self.count += 1;
    }
};

/// Contiguous arc-subsets (size 1..3) by ring angle (TS arcSubsets).
fn arcSubsets(nbhd: u8, houses: []const u8) ArcSubsets {
    var out = ArcSubsets{};
    if (houses.len < 2) return out;
    var ang_buf: [geo.MAX_HOUSES]f64 = undefined;
    const ang = geo.houseAngles(nbhd, houses, &ang_buf);
    // Stable sort houses by angle.
    var order: [geo.MAX_HOUSES]u8 = undefined;
    var keys: [geo.MAX_HOUSES]f64 = undefined;
    for (houses, 0..) |h, i| {
        order[i] = h;
        keys[i] = ang[i];
    }
    var i: usize = 1;
    while (i < houses.len) : (i += 1) {
        const h = order[i];
        const k = keys[i];
        var j = i;
        while (j > 0 and keys[j - 1] > k) : (j -= 1) {
            order[j] = order[j - 1];
            keys[j] = keys[j - 1];
        }
        order[j] = h;
        keys[j] = k;
    }
    const n = houses.len;
    const max_k: usize = @min(3, n - 1); // typed: @min(3, x) would refine to u2 and max_k+1 overflows
    for (1..max_k + 1) |k| {
        for (0..n) |start| {
            var s: [3]u8 = undefined;
            for (0..k) |j| s[j] = order[(start + j) % n];
            // Dedup by set (TS `seen` keys) — linear compare over prior subsets.
            var sorted: [3]u8 = undefined;
            @memcpy(sorted[0..k], s[0..k]);
            std.sort.insertion(u8, sorted[0..k], {}, std.sort.asc(u8));
            var dup = false;
            for (0..out.count) |pi| {
                const prior = out.subset(pi);
                if (prior.len != k) continue;
                var psorted: [3]u8 = undefined;
                @memcpy(psorted[0..k], prior);
                std.sort.insertion(u8, psorted[0..k], {}, std.sort.asc(u8));
                if (std.mem.eql(u8, psorted[0..k], sorted[0..k])) {
                    dup = true;
                    break;
                }
            }
            if (!dup) out.add(s[0..k]);
        }
    }
    return out;
}

/// Voluntary split delivery (TS splitPass): hand a contiguous arc to a second
/// truck when it lowers total pain.
fn splitPass(sub: *const Substrate, routes: *Routes, rec: ?*Recorder) void {
    var guard: usize = 0;
    while (guard < 60) : (guard += 1) {
        var times: [MAX_ROUTES]i64 = undefined;
        for (0..routes.len) |i| times[i] = costOf(sub, routes.r[i].slice());

        var found = false;
        var best_g: i64 = undefined;
        var best_a: usize = undefined;
        var best_sa: usize = undefined;
        var best_b: usize = undefined;
        var best_pos: usize = undefined;
        var best_take: Stop = undefined;
        var best_rest: Stop = undefined;

        for (0..routes.len) |a| {
            for (0..routes.r[a].len) |sa| {
                const stop = routes.r[a].stops[sa];
                if (stop.pin != NO_PIN) continue;
                if (stop.nh < 2) continue;
                const subsets = arcSubsets(stop.nbhd, stop.hs());
                for (0..routes.len) |b| {
                    if (b == a) continue;
                    var serves = false;
                    for (routes.r[b].slice()) |s| {
                        if (s.nbhd == stop.nbhd) serves = true;
                    }
                    if (serves) continue;
                    for (0..subsets.count) |ssi| {
                        const S = subsets.subset(ssi);
                        const bs = routes.r[b].slice();
                        if (loadOf(bs) + @as(i32, @intCast(S.len)) > capOf(bs)) continue;
                        var in_s = [_]bool{false} ** geo.MAX_HOUSES;
                        for (S) |h| {
                            for (stop.hs(), 0..) |sh, k| {
                                if (sh == h) in_s[k] = true;
                            }
                        }
                        var rest: [geo.MAX_HOUSES]u8 = undefined;
                        var rest_n: u8 = 0;
                        for (stop.hs(), 0..) |sh, k| {
                            if (!in_s[k]) {
                                rest[rest_n] = sh;
                                rest_n += 1;
                            }
                        }
                        var new_a = routes.r[a];
                        new_a.stops[sa] = Stop.init(stop.nbhd, rest[0..rest_n], NO_PIN);
                        const cost_a = costOf(sub, new_a.slice());
                        const s_stop = Stop.init(stop.nbhd, S, NO_PIN);
                        var best_bcost: i64 = std.math.maxInt(i64);
                        var best_bpos: usize = 0;
                        for (0..bs.len + 1) |pos| {
                            var cand = routes.r[b];
                            cand.insertAt(pos, s_stop);
                            const c = costOf(sub, cand.slice());
                            if (c < best_bcost) {
                                best_bcost = c;
                                best_bpos = pos;
                            }
                        }
                        const g = cost_a - times[a] + (best_bcost - times[b]);
                        if (g <= -1 and (!found or g < best_g)) {
                            found = true;
                            best_g = g;
                            best_a = a;
                            best_sa = sa;
                            best_b = b;
                            best_pos = best_bpos;
                            best_take = s_stop;
                            best_rest = Stop.init(stop.nbhd, rest[0..rest_n], NO_PIN);
                        }
                    }
                }
            }
        }

        if (!found) break;
        routes.r[best_a].stops[best_sa] = best_rest;
        routes.r[best_b].insertAt(best_pos, best_take);
        if (rec) |rr| {
            var tbuf: [MAX_TOUCHED]HouseKey = undefined;
            rr.rec(.balance, -best_g, "split {s}: {d} of {d} totes to another truck", .{ geo.nameOf(best_take.nbhd), best_take.nh, @as(u32, best_take.nh) + best_rest.nh }, routes, keysFor(best_take.nbhd, best_take.hs(), &tbuf));
        }
    }
}

// --- tidySplitHouses ------------------------------------------------------

/// Entry/exit ring angles of the route's delivery visit to `nbhd` (TS
/// deliveryGates). Null if the route never delivers it.
fn deliveryGates(sub: *const Substrate, stops: []const Stop, nbhd: u8) ?struct { entry: f64, exit: f64 } {
    var buf: [MAX_PATH_NODES]u8 = undefined;
    const nodes = pathNodes(sub, stops, &buf);
    for (1..nodes.len -| 1) |i| {
        if (nodes[i] != nbhd) continue;
        return .{
            .entry = geo.gateAngle(nbhd, geo.nodeAt(nodes[i - 1])),
            .exit = geo.gateAngle(nbhd, geo.nodeAt(nodes[i + 1])),
        };
    }
    return null;
}

/// Pain-neutral house-identity swaps between trucks splitting a neighborhood
/// (TS tidySplitHouses). The one FLOAT-scored pass: localMinutes is real ring
/// geometry, gain threshold stays 1e-6 minutes.
fn tidySplitHouses(sub: *const Substrate, by_slot: *[N_SLOTS]Route) void {
    // nbhd -> slots serving it, in slot order (JS Map insertion order).
    var nbhd_order: [geo.N_NODES]u8 = undefined;
    var nlen: usize = 0;
    var slots: [geo.N_NODES][N_SLOTS]u8 = undefined;
    var slots_n = [_]u8{0} ** geo.N_NODES;
    for (0..N_SLOTS) |i| {
        for (by_slot[i].slice()) |s| {
            if (s.nh == 0) continue;
            if (slots_n[s.nbhd] == 0) {
                nbhd_order[nlen] = s.nbhd;
                nlen += 1;
            }
            slots[s.nbhd][slots_n[s.nbhd]] = @intCast(i);
            slots_n[s.nbhd] += 1;
        }
    }

    for (nbhd_order[0..nlen]) |nbhd| {
        if (slots_n[nbhd] < 2) continue;
        const Part = struct { stop: *Stop, entry: f64, exit: f64 };
        var parts: [N_SLOTS]Part = undefined;
        var pn: usize = 0;
        for (slots[nbhd][0..slots_n[nbhd]]) |slot| {
            var stop: ?*Stop = null;
            for (0..by_slot[slot].len) |i| {
                if (by_slot[slot].stops[i].nbhd == nbhd) {
                    stop = &by_slot[slot].stops[i];
                    break;
                }
            }
            const gates = deliveryGates(sub, by_slot[slot].slice(), nbhd) orelse continue;
            parts[pn] = .{ .stop = stop.?, .entry = gates.entry, .exit = gates.exit };
            pn += 1;
        }
        if (pn < 2) continue;

        while (true) {
            var found = false;
            var best_gain: f64 = undefined;
            var best_p: usize = undefined;
            var best_q: usize = undefined;
            var best_ai: usize = undefined;
            var best_bi: usize = undefined;
            for (0..pn) |x| {
                for (x + 1..pn) |y| {
                    const p = parts[x];
                    const q = parts[y];
                    const base = partCost(nbhd, p) + partCost(nbhd, q);
                    for (0..p.stop.nh) |ai| {
                        for (0..q.stop.nh) |bi| {
                            const a = p.stop.houses[ai];
                            const b = q.stop.houses[bi];
                            p.stop.houses[ai] = b;
                            q.stop.houses[bi] = a;
                            const gain = base - (partCost(nbhd, p) + partCost(nbhd, q));
                            p.stop.houses[ai] = a;
                            q.stop.houses[bi] = b;
                            if (gain > 1e-6 and (!found or gain > best_gain)) {
                                found = true;
                                best_gain = gain;
                                best_p = x;
                                best_q = y;
                                best_ai = ai;
                                best_bi = bi;
                            }
                        }
                    }
                }
            }
            if (!found) break;
            const p = parts[best_p];
            const q = parts[best_q];
            const a = p.stop.houses[best_ai];
            p.stop.houses[best_ai] = q.stop.houses[best_bi];
            q.stop.houses[best_bi] = a;
        }
    }
}

fn partCost(nbhd: u8, p: anytype) f64 {
    var ang_buf: [geo.MAX_HOUSES]f64 = undefined;
    const angs = geo.houseAngles(nbhd, p.stop.hs(), &ang_buf);
    return rg.localMinutes(nbhd, p.entry, p.exit, angs);
}

// --- The full solve -------------------------------------------------------

pub const Plan = struct {
    by_slot: [N_SLOTS]Route,
    unrouted: [16]Stop, // stops that found no room (legality demands none)
    unrouted_len: u8,
    // Display fields (TS Plan) — the playback clock's numbers, never a
    // solver input. Floats ride the trig path (localMinutes).
    route_travel: [N_SLOTS]i64,
    route_time: [N_SLOTS]f64,
    total_travel: i64,
    total_local: f64,
    total_service: i64,
    total_time: f64,
    spread: f64,

    pub fn pain(self: *const Plan, sub: *const Substrate) i64 {
        var total: i64 = 0;
        for (&self.by_slot) |*r| total += painOf(sub, r.slice());
        return total;
    }
};

// Corridor-race sub-recorders (only the winner's moves join the main log).
// Static: a Recorder is ~1.5MB and runSolve is single-threaded.
var g_cons_rec: Recorder = undefined;
var g_aggr_rec: Recorder = undefined;

const Orders = @import("orders.zig");

/// One full solve at one race-variant configuration (TS runSolve).
pub fn runSolve(sub: *const Substrate, demand: *const Orders.Demand, allow_split: bool, cost_aware: bool, defer_medina: bool, rec: ?*Recorder) Plan {
    var all = Routes{};
    customers(demand, &all);

    var in_defer = [_]bool{false} ** geo.N_NODES;
    in_defer[geo.id("Bellevue")] = true;
    if (defer_medina) in_defer[geo.id("Medina")] = true;

    var deferred = Routes{};
    var routes = Routes{};
    for (0..all.len) |i| {
        const nbhd = all.r[i].stops[0].nbhd;
        if (in_defer[nbhd]) deferred.push(all.r[i]) else routes.push(all.r[i]);
    }

    if (rec) |r| r.start_frame = routes; // TS: seed = snapshot(routes), pre-construction

    construct(sub, &routes, false, rec);
    if (routes.len > geo.TRUCKS) construct(sub, &routes, true, rec);
    if (routes.len > geo.TRUCKS) forcePlace(sub, &routes, cost_aware, rec);
    placeDeferred(sub, &routes, &deferred, cost_aware, rec);

    for (0..routes.len) |i| twoOpt(sub, &routes.r[i]);
    orOpt(sub, &routes, rec);
    exchange(sub, &routes, rec);
    for (0..routes.len) |i| twoOpt(sub, &routes.r[i]);

    rebalance(sub, &routes, rec);
    if (allow_split) {
        splitPass(sub, &routes, rec);
        exchange(sub, &routes, rec);
        rebalance(sub, &routes, rec);
    }
    for (0..routes.len) |i| routes.r[i] = coalesceStops(routes.r[i].slice());
    for (0..routes.len) |i| twoOpt(sub, &routes.r[i]);

    var unrouted: [16]Stop = undefined;
    var unrouted_len: u8 = 0;
    while (routes.len > geo.TRUCKS) {
        for (routes.r[routes.len - 1].slice()) |s| {
            unrouted[unrouted_len] = s;
            unrouted_len += 1;
        }
        routes.len -= 1;
    }

    // Slot assignment: anchored routes own their slots; leftovers fill idle
    // slots biggest-first, spilling across slots with room if none fits whole.
    var by_slot = [_]Route{Route{}} ** N_SLOTS;
    var leftover = Routes{};
    for (0..routes.len) |i| {
        const r = routes.r[i];
        if (r.len == 0) continue;
        var anchor: ?u8 = null;
        for (r.slice()) |s| {
            if (s.pin != NO_PIN) {
                anchor = s.pin;
                break;
            }
        }
        if (anchor) |slot| by_slot[slot] = r else leftover.push(r);
    }
    sortRoutesByLoadDesc(&leftover);
    for (0..leftover.len) |li| {
        const r = leftover.r[li];
        var whole: ?usize = null;
        for (0..N_SLOTS) |i| {
            if (by_slot[i].len == 0 and loadOf(r.slice()) <= geo.TRUCK_CAPS[i]) {
                whole = i;
                break;
            }
        }
        if (whole) |i| {
            by_slot[i] = r;
            continue;
        }
        for (r.slice()) |stop| {
            var houses = stop.hs();
            while (houses.len > 0) {
                var best: ?usize = null;
                var room: i32 = 0;
                for (0..N_SLOTS) |i| {
                    const free = @as(i32, geo.TRUCK_CAPS[i]) - loadOf(by_slot[i].slice());
                    if (free > room) {
                        room = free;
                        best = i;
                    }
                }
                if (best == null or room <= 0) {
                    unrouted[unrouted_len] = Stop.init(stop.nbhd, houses, NO_PIN);
                    unrouted_len += 1;
                    break;
                }
                const take: usize = @min(@as(usize, @intCast(room)), houses.len);
                by_slot[best.?].push(Stop.init(stop.nbhd, houses[0..take], NO_PIN));
                houses = houses[take..];
            }
        }
    }

    for (0..N_SLOTS) |i| by_slot[i] = coalesceStops(by_slot[i].slice());

    // Corridor race: conservative (shackled) vs aggressive, keep the cheaper
    // by tidied pain sum — ties go to the conservative pass (strict <).
    var cons = by_slot;
    var aggr = by_slot;
    if (rec != null) {
        g_cons_rec.reset();
        g_aggr_rec.reset();
        corridorRepair(sub, &cons, true, &g_cons_rec);
        corridorRepair(sub, &aggr, false, &g_aggr_rec);
    } else {
        corridorRepair(sub, &cons, true, null);
        corridorRepair(sub, &aggr, false, null);
    }
    var cons_pain: i64 = 0;
    var aggr_pain: i64 = 0;
    for (0..N_SLOTS) |i| {
        cons_pain += tidiedCost(sub, cons[i].slice());
        aggr_pain += tidiedCost(sub, aggr[i].slice());
    }
    const aggr_wins = aggr_pain < cons_pain;
    by_slot = if (aggr_wins) aggr else cons;
    if (rec) |r| {
        // Only the winning corridor pass's moves join the log (TS winner.lg).
        const wrec: *const Recorder = if (aggr_wins) &g_aggr_rec else &g_cons_rec;
        for (wrec.slice()) |m| {
            std.debug.assert(r.len < MAX_MOVES);
            r.moves[r.len] = m;
            r.len += 1;
        }
    }
    for (0..N_SLOTS) |i| twoOpt(sub, &by_slot[i]);

    postSlotLocalSearch(sub, &by_slot, rec);
    for (0..N_SLOTS) |i| twoOpt(sub, &by_slot[i]);

    arcRebalance(sub, &by_slot, rec);
    for (0..N_SLOTS) |i| twoOpt(sub, &by_slot[i]);

    tidySplitHouses(sub, &by_slot);

    if (rec) |r| r.end_frame = slotsFrame(&by_slot);

    // Display numbers (TS built + total reduce): per-route breakdown, plan
    // totals in route order, spread over deployed trucks.
    var plan = Plan{
        .by_slot = by_slot,
        .unrouted = unrouted,
        .unrouted_len = unrouted_len,
        .route_travel = undefined,
        .route_time = undefined,
        .total_travel = 0,
        .total_local = 0,
        .total_service = 0,
        .total_time = 0,
        .spread = 0,
    };
    for (0..N_SLOTS) |i| {
        const b = breakdown(sub, by_slot[i].slice());
        plan.route_travel[i] = b.travel;
        plan.route_time[i] = b.time;
        plan.total_travel += b.travel;
        plan.total_local += b.local;
        plan.total_service += b.service;
    }
    plan.total_time = @as(f64, @floatFromInt(plan.total_travel)) + plan.total_local + @as(f64, @floatFromInt(plan.total_service));
    var t_max: f64 = -std.math.inf(f64);
    var t_min: f64 = std.math.inf(f64);
    var deployed: usize = 0;
    for (0..N_SLOTS) |i| {
        if (by_slot[i].len == 0) continue;
        deployed += 1;
        t_max = @max(t_max, plan.route_time[i]);
        t_min = @min(t_min, plan.route_time[i]);
    }
    plan.spread = if (deployed > 0) t_max - t_min else 0;
    return plan;
}

pub const RaceResult = struct {
    best: Plan,
    winner: u8, // variant index into VARIANTS
    pains: [4]i64,
};

pub const VARIANTS = [_]struct { label: []const u8, cost_aware: bool, defer_medina: bool }{
    .{ .label = "room/whole/M+", .cost_aware = false, .defer_medina = true },
    .{ .label = "room/whole/M-", .cost_aware = false, .defer_medina = false },
    .{ .label = "cost/whole/M+", .cost_aware = true, .defer_medina = true },
    .{ .label = "cost/whole/M-", .cost_aware = true, .defer_medina = false },
};

/// The construction race (TS race): solve all variants, keep the cheapest by
/// pain; a tie resolves to the FIRST listed.
pub fn race(sub: *const Substrate, demand: *const Orders.Demand, rec: ?*Recorder) RaceResult {
    var out: RaceResult = undefined;
    var best_pain: i64 = std.math.maxInt(i64);
    for (VARIANTS, 0..) |v, vi| {
        const plan = runSolve(sub, demand, true, v.cost_aware, v.defer_medina, null);
        const pain = plan.pain(sub);
        out.pains[vi] = pain;
        if (pain < best_pain) {
            best_pain = pain;
            out.best = plan;
            out.winner = @intCast(vi);
        }
    }
    if (rec) |r| {
        // Deterministic re-run of the winner with recording on — identical
        // plan (asserted), so the log is the winner's own, exactly as the TS
        // keeps each runSolve's log with its plan.
        r.reset();
        const v = VARIANTS[out.winner];
        const replay = runSolve(sub, demand, true, v.cost_aware, v.defer_medina, r);
        std.debug.assert(replay.pain(sub) == best_pain);
        out.best = replay;
    }
    return out;
}

test "solve seed 49 produces a legal plan" {
    const sub = rg.buildSubstrate();
    const demand = Orders.chooseOrders(49, geo.ORDERS);
    const result = race(&sub, &demand, null);
    try std.testing.expectEqual(@as(u8, 0), result.best.unrouted_len);
    var total: i32 = 0;
    for (&result.best.by_slot, 0..) |*r, i| {
        const load = loadOf(r.slice());
        try std.testing.expect(load <= geo.TRUCK_CAPS[i]);
        total += load;
    }
    try std.testing.expectEqual(@as(i32, geo.ORDERS), total);
}
