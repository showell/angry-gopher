// orders.zig — port of delivery/orders.ts: the seeded daily draw. The demand
// the solver receives is ORDER-SENSITIVE in two ways the port must preserve
// (JS Map/Set semantics): neighborhoods appear in first-pick order, and each
// neighborhood's house list is in pick order, NOT sorted. The gold corpus
// pins both (its demand section is name-sorted for comparison, but the house
// lists inside keep pick order).

const std = @import("std");
const geo = @import("geography.zig");

/// mulberry32, bit-exact with the TS: u32 wrapping arithmetic throughout
/// (JS's ToInt32/ToUint32 coercions all collapse to wrapping u32 ops), then
/// the final /2^32 as f64 — every step IEEE-defined, no engine variance.
pub const Mulberry32 = struct {
    s: u32,

    pub fn next(self: *Mulberry32) f64 {
        self.s = self.s +% 0x6d2b79f5;
        var t: u32 = self.s;
        t = (t ^ (t >> 15)) *% (t | 1);
        t ^= t +% ((t ^ (t >> 7)) *% (t | 61));
        return @as(f64, @floatFromInt(t ^ (t >> 14))) / 4294967296.0;
    }
};

pub const TOTAL_HOUSES = blk: {
    var total: u16 = 0;
    for (geo.NEIGHBORHOODS) |nb| total += nb.houses;
    break :blk total;
};

const House = struct { nbhd: u8, index: u8 };

/// Every house in NEIGHBORHOODS order (TS allHouses), comptime-flattened.
pub const ALL_HOUSES = blk: {
    var out: [TOTAL_HOUSES]House = undefined;
    var k: usize = 0;
    for (geo.NEIGHBORHOODS, 0..) |nb, ni| {
        for (0..nb.houses) |hi| {
            out[k] = .{ .nbhd = ni, .index = hi };
            k += 1;
        }
    }
    break :blk out;
};

/// The day's demand: neighborhoods in first-pick order, each with its ordered
/// (pick-order) house indices — the exact shape TS ordersByNeighborhood hands
/// the solver.
pub const Demand = struct {
    nbhds: [geo.N_NBHD]u8 = undefined, // neighborhood ids, first-appearance order
    houses: [geo.N_NBHD][geo.MAX_HOUSES]u8 = undefined,
    counts: [geo.N_NBHD]u8 = [_]u8{0} ** geo.N_NBHD,
    len: u8 = 0,

    pub fn housesOf(self: *const Demand, slot: usize) []const u8 {
        return self.houses[slot][0..self.counts[slot]];
    }
};

/// Pick `count` distinct houses by partial Fisher-Yates (TS chooseOrders),
/// then group them by neighborhood (TS ordersByNeighborhood).
pub fn chooseOrders(seed: u32, count: u16) Demand {
    var idx: [TOTAL_HOUSES]u16 = undefined;
    for (0..TOTAL_HOUSES) |i| idx[i] = @intCast(i);
    var rng = Mulberry32{ .s = seed };
    const n: u16 = @min(count, TOTAL_HOUSES);
    for (0..n) |i| {
        const r = rng.next() * @as(f64, @floatFromInt(TOTAL_HOUSES - i));
        const j = i + @as(usize, @intFromFloat(@floor(r)));
        std.mem.swap(u16, &idx[i], &idx[j]);
    }

    var demand = Demand{};
    var slot_of = [_]u8{0xff} ** geo.N_NBHD;
    for (0..n) |k| {
        const h = ALL_HOUSES[idx[k]];
        if (slot_of[h.nbhd] == 0xff) {
            slot_of[h.nbhd] = demand.len;
            demand.nbhds[demand.len] = h.nbhd;
            demand.len += 1;
        }
        const s = slot_of[h.nbhd];
        demand.houses[s][demand.counts[s]] = h.index;
        demand.counts[s] += 1;
    }
    return demand;
}

test "seed 49 draws exactly 100 houses over a plausible spread" {
    const d = chooseOrders(49, geo.ORDERS);
    var total: u16 = 0;
    for (0..d.len) |s| total += d.counts[s];
    try std.testing.expectEqual(@as(u16, 100), total);
    try std.testing.expect(d.len >= 15 and d.len <= geo.N_NBHD);
}
