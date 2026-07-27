// roadgraph.zig — port of delivery/roadgraph.ts: the artery edges (float
// geometry snapped to integer minutes by guarded rounding) and the all-pairs
// Dijkstra substrate. Iteration order is semantics here: edges are built
// ROADS-then-BRIDGES in declaration order, Dijkstra picks the FIRST minimum
// and relaxes with strict <, so equal-cost paths resolve exactly as the TS
// does — the gold's `substrate.paths` section pins all of it.

const std = @import("std");
const geo = @import("geography.zig");

pub const MIN_PER_PX = 0.0225;
pub const SPEED = struct {
    pub const city = 1.6;
    pub const suburb = 1.0;
    pub const bridge = 1.2;
    pub const bridge520 = 1.5;
    pub const fast = 0.6;
    pub const i_5 = 0.8; // "i5" in the TS; renamed (zig reserves i5 as a primitive)
};
pub const NEIGHBORHOOD_SLOWDOWN = 2.1;
pub const SERVICE = 2; // minutes per order (display only — a wash in the solver)

/// Round to integer minutes; panic if the value sits within 1e-9 of a .5
/// boundary (cross-engine coin-flip) or rounds below 1 (same as TS, which throws).
fn safelyRound(x: f64) i64 {
    const r = std.math.round(x);
    if (0.5 - @abs(x - r) < 1e-9) std.debug.panic("safelyRound({d}) lands on a .5 boundary", .{x});
    if (r < 1) std.debug.panic("safelyRound({d}) rounded below 1", .{x});
    return @intFromFloat(r);
}

/// Like safelyRound but a sub-1 result floors to 1 (I-5 exit ramps).
fn roundExit(x: f64) i64 {
    const r = std.math.round(x);
    if (r >= 1 and 0.5 - @abs(x - r) < 1e-9) std.debug.panic("roundExit({d}) lands on a .5 boundary", .{x});
    return @intFromFloat(@max(1, r));
}

fn len(pts: []const geo.Pt) f64 {
    var d: f64 = 0;
    var i: usize = 1;
    while (i < pts.len) : (i += 1) {
        d += std.math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
    }
    return d;
}

fn isWest(node: u8) bool {
    return node != geo.FC and geo.NEIGHBORHOODS[node].side == .west;
}

/// Speed multiplier for an edge (lower = faster) — check order matters and
/// mirrors TS factor(): 520's lake span, then Montlake/I-5, the 405 bypass,
/// bridges, city, suburb.
fn factor(a: u8, b: u8, bridge: bool) f64 {
    const montlake = geo.id("Montlake");
    const medina = geo.id("Medina");
    if ((a == montlake and b == medina) or (a == medina and b == montlake)) return SPEED.bridge520;
    if (a == montlake or b == montlake) return SPEED.i_5;
    if (geo.I5_EXITS[a] or geo.I5_EXITS[b]) return SPEED.i_5;
    const issaquah = geo.id("Issaquah");
    const redmond = geo.id("Redmond");
    if ((a == issaquah and b == redmond) or (a == redmond and b == issaquah)) return SPEED.fast;
    if (bridge) return SPEED.bridge;
    if (isWest(a) or isWest(b)) return SPEED.city;
    return SPEED.suburb;
}

pub const Edge = struct { a: u8, b: u8, minutes: i64 };
pub const MAX_EDGES = 64;

/// Every artery edge (ROADS then BRIDGES segments, declaration order) with
/// its integer travel time.
pub fn edges(out: *[MAX_EDGES]Edge) []Edge {
    var count: usize = 0;
    for (geo.ROADS) |r| {
        const on_i5 = geo.I5_EXITS[r[0]] or geo.I5_EXITS[r[1]];
        // Surface road: gate-to-gate straight shot.
        const pts = [2]geo.Pt{ geo.gateOf(r[0], geo.nodeAt(r[1])), geo.gateOf(r[1], geo.nodeAt(r[0])) };
        const minutes_f = len(&pts) * factor(r[0], r[1], false) * MIN_PER_PX;
        out[count] = .{ .a = r[0], .b = r[1], .minutes = if (on_i5) roundExit(minutes_f) else safelyRound(minutes_f) };
        count += 1;
    }
    for (geo.BRIDGES) |br| {
        for (0..br.nodes.len - 1) |i| {
            const a = br.nodes[i];
            const c = br.nodes[i + 1];
            const w = br.waters[i];
            // Deck: gate (toward first turn) -> waters -> gate (toward last turn).
            var pts: [8]geo.Pt = undefined;
            pts[0] = geo.gateOf(a, if (w.len > 0) w[0] else geo.nodeAt(c));
            for (w, 0..) |p, k| pts[1 + k] = p;
            pts[1 + w.len] = geo.gateOf(c, if (w.len > 0) w[w.len - 1] else geo.nodeAt(a));
            const on_i5 = geo.I5_EXITS[a] or geo.I5_EXITS[c];
            const minutes_f = len(pts[0 .. 2 + w.len]) * factor(a, c, true) * MIN_PER_PX;
            out[count] = .{ .a = a, .b = c, .minutes = if (on_i5) roundExit(minutes_f) else safelyRound(minutes_f) };
            count += 1;
        }
    }
    return out[0..count];
}

pub const N = geo.N_NODES;
const INF = std.math.maxInt(i64);

pub const Substrate = struct {
    matrix: [N][N]i64, // all-pairs shortest travel minutes
    prev: [N][N]i16, // prev[s][v] = node before v on the shortest path from s (-1 = none)

    pub fn time(self: *const Substrate, a: u8, b: u8) i64 {
        return self.matrix[a][b];
    }

    pub const MAX_PATH = 32;

    /// Node sequence of the shortest path a -> b, both ends inclusive.
    pub fn path(self: *const Substrate, a: u8, b: u8, out: *[MAX_PATH]u8) []u8 {
        std.debug.assert(self.matrix[a][b] != INF);
        var rev: [MAX_PATH]u8 = undefined;
        var rlen: usize = 0;
        var v: i16 = b;
        while (v != a) {
            rev[rlen] = @intCast(v);
            rlen += 1;
            v = self.prev[a][@intCast(v)];
            std.debug.assert(v != -1);
        }
        rev[rlen] = a;
        rlen += 1;
        for (0..rlen) |i| out[i] = rev[rlen - 1 - i];
        return out[0..rlen];
    }
};

/// Build the substrate: adjacency from edges() (insertion order preserved),
/// then Dijkstra per source with first-min selection and strict-< relaxation.
pub fn buildSubstrate() Substrate {
    var edge_buf: [MAX_EDGES]Edge = undefined;
    const es = edges(&edge_buf);

    // adj in edge order, both directions — the TS pushes a->b then b->a per edge.
    const Adj = struct { to: u8, w: i64 };
    var adj: [N][16]Adj = undefined;
    var adj_len = [_]usize{0} ** N;
    for (es) |e| {
        adj[e.a][adj_len[e.a]] = .{ .to = e.b, .w = e.minutes };
        adj_len[e.a] += 1;
        adj[e.b][adj_len[e.b]] = .{ .to = e.a, .w = e.minutes };
        adj_len[e.b] += 1;
    }

    var sub: Substrate = undefined;
    for (0..N) |s| {
        var dist = &sub.matrix[s];
        var back = &sub.prev[s];
        @memset(dist, INF);
        @memset(back, -1);
        dist[s] = 0;
        var done = [_]bool{false} ** N;
        for (0..N) |_| {
            var u: i16 = -1;
            var best: i64 = INF;
            for (0..N) |k| {
                if (!done[k] and dist[k] < best) {
                    best = dist[k];
                    u = @intCast(k);
                }
            }
            if (u == -1) break;
            const ui: usize = @intCast(u);
            done[ui] = true;
            for (adj[ui][0..adj_len[ui]]) |e| {
                if (dist[ui] + e.w < dist[e.to]) {
                    dist[e.to] = dist[ui] + e.w;
                    back[e.to] = u;
                }
            }
        }
    }
    return sub;
}

/// Minutes inside a neighborhood on its slow ring (display + tidySplitHouses).
pub fn localMinutes(node: u8, entry_a: f64, exit_a: f64, h_angles: []const f64) f64 {
    const arterial: f64 = if (isWest(node)) SPEED.city else SPEED.suburb;
    return geo.ringWalkArcPx(node, entry_a, exit_a, h_angles) * arterial * NEIGHBORHOOD_SLOWDOWN * MIN_PER_PX;
}

test "substrate is connected and symmetric-ish" {
    const sub = buildSubstrate();
    for (0..geo.N_NBHD) |v| {
        try std.testing.expect(sub.matrix[geo.FC][v] != INF);
        try std.testing.expectEqual(sub.matrix[geo.FC][v], sub.matrix[v][geo.FC]);
    }
}
