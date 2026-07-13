//! suit_first — tier 0 of the solve portfolio: the human prior.
//!
//! Humans solve dense boards suit-first: pure runs are the bulk
//! carrier, and sets are patch material for the orphans left over
//! (red-black runs don't appear at all in this tier). Steve's solve of
//! the 45-card probe monster was six pure runs and one ace set, found
//! in the time the flavor-symmetric sweep spent disproving cross-suit
//! tangles it never needed — this module is that prior, run first.
//!
//! The shape: per suit, the board's ranks form maximal cyclic arcs
//! (K→A wraps). Arcs of length ≥ 3 stand as pure runs; shorter arcs
//! are orphans that MUST be absorbed by a set at their rank. A set at
//! rank r takes all orphans of r plus donor cards peeled out of long
//! arcs — legal iff every arc's residual segments each keep length
//! ≥ 3 (the removability rule that falls out of the 3..5 lemma).
//! Small backtracking over donor choices, strict validation at the
//! leaf, and a hard attempt cap: this tier is allowed to say "pass" —
//! failure just falls through to the complete sweep. It must never
//! say a false "solved"; success is a constructed cover.

const std = @import("std");
const graph = @import("graph.zig");

const FULL: u16 = 0x1FFF; // all 13 ranks

const Arc = struct {
    suit: u8,
    start: u8, // rank of first card
    len: u8, // 1..13; 13 = the whole cycle
    donated: u16 = 0, // rank mask of cards peeled into sets
};

const MAX_ARCS = 4 * 6; // a 13-rank cycle holds at most 6 disjoint arcs

const State = struct {
    arcs: [MAX_ARCS]Arc = undefined,
    arc_n: usize = 0,
    // per rank: suits whose card is an orphan / a potential donor
    orphan: [13]u8 = @splat(0),
    donor: [13]u8 = @splat(0),
    // arc index per (suit, rank), NONE where irrelevant
    arc_of: [graph.N]u8 = @splat(0xFF),
    set_at: [13]u8 = @splat(0), // suits chosen into the set at each rank
    attempts: u32 = 0,
};

/// trySolve attempts a pure-runs-plus-sets cover. On success it fills
/// `next` (a fresh next-map) and returns true; on false, `next` is
/// untouched garbage and the caller falls through to the sweep.
pub fn trySolve(board: u64, next: *[graph.N]u8) bool {
    var st: State = .{};

    // Per-suit maximal cyclic arcs; orphans and donors per rank.
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

    // Every orphan rank needs a set; collect them.
    var need: [13]u8 = undefined;
    var need_n: usize = 0;
    for (0..13) |r| {
        if (st.orphan[r] != 0) {
            need[need_n] = @intCast(r);
            need_n += 1;
        }
    }

    if (!absorb(&st, need[0..need_n], 0)) return false;
    build(&st, next);
    return true;
}

fn addArc(st: *State, suit: u8, start: u8, len: u8) void {
    const id: u8 = @intCast(st.arc_n);
    st.arcs[st.arc_n] = .{ .suit = suit, .start = start, .len = len };
    st.arc_n += 1;
    for (0..len) |k| {
        const r: u8 = @intCast((start + k) % 13);
        st.arc_of[@as(usize, suit) * 13 + r] = id;
        if (len < 3) {
            st.orphan[r] |= @as(u8, 1) << @intCast(suit);
        } else {
            st.donor[r] |= @as(u8, 1) << @intCast(suit);
        }
    }
}

/// absorb: choose donors for the set at each orphan rank, backtracking;
/// at the leaf every arc's residual segments must survive.
fn absorb(st: *State, need: []const u8, i: usize) bool {
    if (i == need.len) return validate(st);
    st.attempts += 1;
    if (st.attempts > 4096) return false; // cap: tier 0 may just pass
    const r = need[i];
    const o = st.orphan[r];
    const o_n = @popCount(o);
    if (o_n > 4) unreachable; // one deck: 4 suits
    // Donor subsets, fewest donations first (least arc damage).
    var subsets: [8]u8 = undefined;
    var sub_n: usize = 0;
    var m: u8 = 0;
    while (true) {
        if (m & ~st.donor[r] == 0 and m & o == 0) {
            const total = o_n + @popCount(m);
            if (total >= 3 and total <= 4) {
                subsets[sub_n] = m;
                sub_n += 1;
            }
        }
        if (m == 15) break;
        m += 1;
    }
    std.mem.sort(u8, subsets[0..sub_n], {}, popCountLess);
    for (subsets[0..sub_n]) |ds| {
        st.set_at[r] = o | ds;
        markDonated(st, r, ds, true);
        if (absorb(st, need, i + 1)) return true;
        markDonated(st, r, ds, false);
        st.set_at[r] = 0;
    }
    return false;
}

fn popCountLess(_: void, a: u8, b: u8) bool {
    return @popCount(a) < @popCount(b);
}

fn markDonated(st: *State, rank: u8, suits: u8, on: bool) void {
    var m = suits;
    while (m != 0) {
        const s: u8 = @intCast(@ctz(m));
        m &= m - 1;
        const arc = &st.arcs[st.arc_of[@as(usize, s) * 13 + rank]];
        if (on) {
            arc.donated |= @as(u16, 1) << @intCast(rank);
        } else {
            arc.donated &= ~(@as(u16, 1) << @intCast(rank));
        }
    }
}

/// validate: after donations, every arc must split into segments of
/// length ≥ 3 (or dissolve entirely into sets — only length-1/2 arcs
/// do that here, and their cards are all orphans by construction).
fn validate(st: *State) bool {
    for (st.arcs[0..st.arc_n]) |arc| {
        if (arc.len < 3) continue; // orphan arcs: absorbed by need-ranks
        if (arc.len == 13 and arc.donated == 0) continue; // full cycle stands
        var run: u8 = 0;
        var ok = true;
        for (0..arc.len) |k| {
            const r: u8 = @intCast((arc.start + k) % 13);
            if (arc.donated >> @intCast(r) & 1 != 0) {
                if (run != 0 and run < 3) ok = false;
                run = 0;
            } else run += 1;
        }
        if (run != 0 and run < 3) ok = false;
        // Full cycle with donations: first and last segments are the
        // same cyclic segment only if no donation separates them —
        // covered above because a 13-arc starts at rank 0 by
        // construction only when FULL, and any donation splits it at
        // that rank. Re-check the wrap join: if both ends survived,
        // they were counted separately but form one segment.
        if (arc.len == 13 and arc.donated != 0) {
            // Join head and tail runs around the cycle for the check:
            // find the first donated rank; rotate the walk to start
            // just after it, then the linear scan above is valid. We
            // redo the scan rotated instead of patching counts.
            const first_gap: u8 = @intCast(@ctz(arc.donated));
            run = 0;
            ok = true;
            for (0..13) |k| {
                const r: u8 = @intCast((first_gap + 1 + k) % 13);
                if (arc.donated >> @intCast(r) & 1 != 0) {
                    if (run != 0 and run < 3) ok = false;
                    run = 0;
                } else run += 1;
            }
            if (run != 0 and run < 3) ok = false;
        }
        if (!ok) return false;
    }
    return true;
}

/// build writes the cover into a fresh next-map: residual arc segments
/// as pure runs, chosen sets as same-rank chains (ascending suit).
fn build(st: *State, next: *[graph.N]u8) void {
    next.* = @splat(graph.NONE);
    for (st.arcs[0..st.arc_n]) |arc| {
        if (arc.len < 3) continue;
        if (arc.len == 13 and arc.donated == 0) {
            // The full cycle stands as one 13-run; break it at A.
            for (0..12) |k| {
                next[cardAt(arc.suit, @intCast(k))] = cardAt(arc.suit, @intCast(k + 1));
            }
            continue;
        }
        // Walk the arc (rotated past a donation gap for full cycles so
        // segments never straddle the walk boundary).
        var offset: u8 = 0;
        if (arc.len == 13) offset = @as(u8, @intCast(@ctz(arc.donated))) + 1;
        var prev: u8 = 0xFF;
        for (0..arc.len) |k| {
            const r: u8 = @intCast((arc.start + offset + k) % 13);
            if (arc.donated >> @intCast(r) & 1 != 0) {
                prev = 0xFF;
                continue;
            }
            if (prev != 0xFF) next[cardAt(arc.suit, prev)] = cardAt(arc.suit, r);
            prev = r;
        }
    }
    for (0..13) |r| {
        var m = st.set_at[r];
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
    // Board: A♠ + A♥2♥3♥4♥ + A♦2♦3♦4♦.
    const hearts: u64 = 0b1111;
    const diamonds: u64 = 0b1111 << 13;
    const as_bit: u64 = @as(u64, 1) << (3 * 13);
    try std.testing.expect(trySolve(hearts | diamonds | as_bit, &next));
}

test "tier 0 passes (returns false) when orphans can't set" {
    var next: [graph.N]u8 = undefined;
    // Lone A♠: orphan, no donors anywhere.
    try std.testing.expect(!trySolve(@as(u64, 1) << (3 * 13), &next));
    // A♠ + one donor suit only: set can't reach 3.
    const hearts: u64 = 0b1111;
    try std.testing.expect(!trySolve(hearts | @as(u64, 1) << (3 * 13), &next));
}
