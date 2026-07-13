//! suit_first — tier 0 of the solve portfolio: the human prior.
//!
//! Humans solve boards suit-first: pure runs are the bulk carrier, and
//! sets are patch material for the orphans left over (red-black runs
//! don't appear at all in this tier). Steve's solve of the 45-card
//! probe monster was six pure runs and one ace set, found in the time
//! the flavor-symmetric sweep spent disproving cross-suit tangles it
//! never needed — this module is that prior, run first.
//!
//! The shape: per suit, the board's ranks form maximal cyclic arcs
//! (K→A wraps). Arcs of length ≥ 3 stand as pure runs; shorter arcs
//! are orphans that MUST be absorbed by a set at their rank. A set at
//! rank r takes all orphans of r plus donor cards peeled out of long
//! arcs. A donation that strands a short residual segment doesn't fail
//! — the stranded cards become new must-absorb orphans and the repair
//! recurses: bounded ejection chains, the CVRP relocate move in card
//! clothes. Deterministic enumeration, hard attempt cap: this tier is
//! allowed to say "pass" — failure just falls through to the complete
//! sweep. It must never say a false "solved"; success is a constructed
//! cover.

const std = @import("std");
const graph = @import("graph.zig");

const FULL: u16 = 0x1FFF; // all 13 ranks
const MAX_ARCS = 4 * 6; // a 13-rank cycle holds at most 6 disjoint arcs

const Arc = struct {
    suit: u8,
    start: u8, // rank of first card
    len: u8, // 1..13; 13 = the whole cycle
};

/// The immutable board decomposition.
const Static = struct {
    arcs: [MAX_ARCS]Arc = undefined,
    arc_n: usize = 0,
    arc_of: [graph.N]u8 = @splat(0xFF), // arc index per (suit, rank)
};

/// The mutable search state — ~90 bytes, copied per branch.
const Cover = struct {
    orphan: [13]u8 = @splat(0), // suits at r that MUST join the set at r
    donor: [13]u8 = @splat(0), // suits at r that MAY be peeled into it
    set_at: [13]u8 = @splat(0), // suits committed to the set at r
    donated: [MAX_ARCS]u16 = @splat(0), // per arc: rank mask peeled out
};

/// trySolve attempts a pure-runs-plus-sets cover. On success it fills
/// `next` (a fresh next-map) and returns true; on false, `next` is
/// untouched garbage and the caller falls through to the sweep.
pub fn trySolve(board: u64, next: *[graph.N]u8) bool {
    var st: Static = .{};
    for (0..4) |s| {
        const suit: u8 = @intCast(s);
        const m: u16 = @intCast((board >> @intCast(s * 13)) & FULL);
        if (m == 0) continue;
        if (m == FULL) {
            addArc(&st, suit, 0, 13);
            continue;
        }
        for (0..13) |r| {
            const rank: u8 = @intCast(r);
            const prev: u4 = @intCast((r + 12) % 13);
            if (m >> @intCast(rank) & 1 == 0) continue;
            if (m >> prev & 1 != 0) continue; // not an arc start
            var len: u8 = 1;
            while (m >> @intCast((rank + len) % 13) & 1 != 0) len += 1;
            addArc(&st, suit, rank, len);
        }
    }
    var cov: Cover = .{};
    reclassify(&st, &cov);
    var attempts: u32 = 0;
    const done = repair(&st, cov, &attempts) orelse return false;
    build(&st, &done, next);
    return true;
}

fn addArc(st: *Static, suit: u8, start: u8, len: u8) void {
    const id: u8 = @intCast(st.arc_n);
    st.arcs[st.arc_n] = .{ .suit = suit, .start = start, .len = len };
    st.arc_n += 1;
    for (0..len) |k| {
        const r: u8 = @intCast((start + k) % 13);
        st.arc_of[@as(usize, suit) * 13 + r] = id;
    }
}

/// reclassify derives orphan/donor bits from the arcs minus what's been
/// donated: residual segments of length ≥ 3 are donor material (any of
/// their cards may still be peeled), shorter residuals are orphans that
/// must be absorbed. Set members sit behind their donated bits.
fn reclassify(st: *const Static, cov: *Cover) void {
    cov.orphan = @splat(0);
    cov.donor = @splat(0);
    for (st.arcs[0..st.arc_n], 0..) |arc, ai| {
        const d = cov.donated[ai];
        if (arc.len == 13 and d == 0) {
            for (0..13) |r| cov.donor[r] |= @as(u8, 1) << @intCast(arc.suit);
            continue;
        }
        // Rotate the walk past a donation gap for the full cycle so
        // segments never straddle the walk boundary.
        var offset: u8 = 0;
        if (arc.len == 13) offset = @as(u8, @intCast(@ctz(d))) + 1;
        var seg: [13]u8 = undefined;
        var seg_n: u8 = 0;
        for (0..arc.len) |k| {
            const r: u8 = @intCast((arc.start + offset + k) % 13);
            if (d >> @intCast(r) & 1 != 0) {
                flushSegment(cov, arc.suit, seg[0..seg_n]);
                seg_n = 0;
                continue;
            }
            seg[seg_n] = r;
            seg_n += 1;
        }
        flushSegment(cov, arc.suit, seg[0..seg_n]);
    }
}

fn flushSegment(cov: *Cover, suit: u8, ranks: []const u8) void {
    const target = if (ranks.len >= 3) &cov.donor else &cov.orphan;
    for (ranks) |r| target[r] |= @as(u8, 1) << @intCast(suit);
}

/// repair: find the first rank with unabsorbed must-set cards and
/// branch over the donor subsets that complete its set (fewest extra
/// donations first). Donations may strand short segments; reclassify
/// turns those into new orphans and the recursion absorbs them in turn
/// — or fails, backtracking. Returns the finished cover, or null.
fn repair(st: *const Static, cov: Cover, attempts: *u32) ?Cover {
    attempts.* += 1;
    if (attempts.* > 4096) return null; // cap: tier 0 may just pass
    var rank: u8 = 13;
    for (0..13) |r| {
        if (cov.orphan[r] & ~cov.set_at[r] != 0) {
            rank = @intCast(r);
            break;
        }
    }
    if (rank == 13) return cov; // every orphan absorbed: done
    const must = cov.orphan[rank] | cov.set_at[rank];
    if (@popCount(must) > 4) return null;
    const cand = cov.donor[rank] & ~must;
    var subsets: [16]u8 = undefined;
    var sub_n: usize = 0;
    var m: u8 = 0;
    while (true) : (m += 1) {
        if (m & ~cand == 0) {
            const total = @popCount(must) + @popCount(m);
            if (total >= 3 and total <= 4) {
                subsets[sub_n] = m;
                sub_n += 1;
            }
        }
        if (m == 15) break;
    }
    std.mem.sort(u8, subsets[0..sub_n], {}, popCountLess);
    for (subsets[0..sub_n]) |ds| {
        var nc = cov;
        nc.set_at[rank] = must | ds;
        var members = must | ds;
        while (members != 0) {
            const s: u8 = @intCast(@ctz(members));
            members &= members - 1;
            const ai = st.arc_of[@as(usize, s) * 13 + rank];
            nc.donated[ai] |= @as(u16, 1) << @intCast(rank);
        }
        reclassify(st, &nc);
        if (repair(st, nc, attempts)) |done| return done;
    }
    return null;
}

fn popCountLess(_: void, a: u8, b: u8) bool {
    return @popCount(a) < @popCount(b);
}

/// build writes the cover into a fresh next-map: residual arc segments
/// as pure runs, chosen sets as same-rank chains (ascending suit).
fn build(st: *const Static, cov: *const Cover, next: *[graph.N]u8) void {
    next.* = @splat(graph.NONE);
    for (st.arcs[0..st.arc_n], 0..) |arc, ai| {
        const d = cov.donated[ai];
        if (arc.len == 13 and d == 0) {
            // The full cycle stands as one 13-run; break it at A.
            for (0..12) |k| {
                next[cardAt(arc.suit, @intCast(k))] = cardAt(arc.suit, @intCast(k + 1));
            }
            continue;
        }
        var offset: u8 = 0;
        if (arc.len == 13) offset = @as(u8, @intCast(@ctz(d))) + 1;
        var prev: u8 = 0xFF;
        for (0..arc.len) |k| {
            const r: u8 = @intCast((arc.start + offset + k) % 13);
            if (d >> @intCast(r) & 1 != 0) {
                prev = 0xFF;
                continue;
            }
            if (prev != 0xFF) next[cardAt(arc.suit, prev)] = cardAt(arc.suit, r);
            prev = r;
        }
    }
    for (0..13) |r| {
        var m = cov.set_at[r];
        var prev: u8 = 0xFF;
        while (m != 0) {
            const s: u8 = @intCast(@ctz(m));
            m &= m - 1;
            if (prev != 0xFF) next[cardAt(prev, @intCast(r))] = cardAt(s, @intCast(r));
            prev = s;
        }
    }
}

fn cardAt(suit: u8, rank: u8) u8 {
    return suit * 13 + rank;
}

// ---------- tests (native: ops/check_solver) ----------
// Mechanics only; end-to-end verification lives in solver.zig, which
// owns the strict verifier.

test "no orphans: full and partial suits stand as pure runs" {
    var next: [graph.N]u8 = undefined;
    // All 13 hearts.
    try std.testing.expect(trySolve(0x1FFF, &next));
    // Hearts 3..7 (ranks 2..6): one arc, stands alone.
    try std.testing.expect(trySolve(0b1111100, &next));
}

test "orphans absorbed by a set with donor peels" {
    var next: [graph.N]u8 = undefined;
    // The keystone shape: A♠ is an orphan; A♥ and A♦ each head a
    // 4-arc, so peeling them leaves legal 3-runs — the ace set forms.
    const hearts: u64 = 0b1111;
    const diamonds: u64 = 0b1111 << 13;
    const as_bit: u64 = @as(u64, 1) << (3 * 13);
    try std.testing.expect(trySolve(hearts | diamonds | as_bit, &next));
}

test "ejection chain: a stranding donation cascades into more sets" {
    var next: [graph.N]u8 = undefined;
    // Board: 6H 7H 8H | 6D 8D | 6C 7C 8C? no — deliberately:
    // 6D 6C, 7S 7C, 8D 8C as loner pairs plus the 6H 7H 8H arc.
    // Rank 6 needs 6H; donating it strands 7H 8H, which then complete
    // the rank-7 and rank-8 sets — three sets, no run survives.
    const b = bit(0, 5) | bit(0, 6) | bit(0, 7) // 6H 7H 8H
    | bit(1, 5) | bit(2, 5) // 6D 6C
    | bit(3, 6) | bit(2, 6) // 7S 7C
    | bit(1, 7) | bit(2, 7); // 8D 8C
    try std.testing.expect(trySolve(b, &next));
    // Spot-check the cascade's output: three same-rank chains.
    try std.testing.expectEqual(cardAt(2, 5), next[cardAt(1, 5)]); // 6D=6C
    try std.testing.expectEqual(cardAt(2, 6), next[cardAt(0, 6)]); // 7H=7C
    try std.testing.expectEqual(cardAt(2, 7), next[cardAt(1, 7)]); // 8D=8C
}

test "tier 0 passes (returns false) when orphans can't set" {
    var next: [graph.N]u8 = undefined;
    // Lone A♠: orphan, no donors anywhere.
    try std.testing.expect(!trySolve(@as(u64, 1) << (3 * 13), &next));
    // A♠ + one donor suit only: set can't reach 3.
    const hearts: u64 = 0b1111;
    try std.testing.expect(!trySolve(hearts | @as(u64, 1) << (3 * 13), &next));
}

fn bit(suit: u8, rank: u8) u64 {
    return @as(u64, 1) << @intCast(@as(u32, suit) * 13 + rank);
}
