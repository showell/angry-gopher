//! suit_first — tier 0 of the solve portfolio: the human prior.
//!
//! Humans solve boards suit-first: pure runs are the bulk carrier, and
//! sets are patch material for the orphans left over (red-black runs
//! don't appear at all in this tier). Steve's solve of the 45-card
//! probe monster was six pure runs and one ace set, found in the time
//! the flavor-symmetric sweep spent disproving cross-suit tangles it
//! never needed — this module is that prior, run first.
//!
//! The shape: per suit, decompose the rank multiset (counts 0..2 —
//! two decks) into cyclic arcs (K→A wraps). One-deck suits have a
//! unique maximal-arc decomposition; doubled ranks open a choice — the
//! level split (all-present layer over doubled layer) loses to the
//! STAIRCASE on shapes like 3 4 4' 5 5' 6, where two overlapping runs
//! 3-4-5 / 4-5-6 need no set at all. A tiny exact DP per suit picks
//! the decomposition with fewest orphan cards, then fewest arcs.
//!
//! Arcs of length ≥ 3 stand as pure runs; shorter arcs are orphans
//! that MUST be absorbed by a set at their rank — up to two sets per
//! rank at two decks, and a same-suit orphan pair must split across
//! both (a set can't repeat a suit). A set takes its orphans plus
//! donor cards peeled out of long arcs; a donation that strands a
//! short residual doesn't fail — the stranded cards become new
//! must-absorb orphans and the repair recurses: bounded ejection
//! chains, the CVRP relocate move in card clothes. Which copy a card
//! is never enters the search (copies are indistinguishable to
//! legality); copies are assigned first-come at build time.
//! Deterministic enumeration, hard attempt cap: this tier is allowed
//! to say "pass" — failure just falls through to the complete sweep.
//! It must never say a false "solved"; success is a constructed cover.

const std = @import("std");
const graph = @import("graph.zig");
const arrangement = @import("arrangement.zig");

const MAX_ARCS = 4 * 14; // per suit: worst is 14 stacked len-1 arcs

const Arc = struct {
    suit: u8,
    start: u8, // rank of first card; full cycles are normalized to 0
    len: u8, // 1..13; 13 = the whole cycle
};

/// The immutable board decomposition.
const Static = struct {
    arcs: [MAX_ARCS]Arc = undefined,
    arc_n: usize = 0,
    // Up to two arcs may cover a (suit, rank) at two decks.
    arc_of: [graph.N][2]u8 = @splat(.{ 0xFF, 0xFF }),
};

/// The mutable search state, copied per branch. Per rank, the [2]u8
/// pairs count multiplicity: [0] = suits with at least one such card,
/// [1] = suits with two. set_at is different: [0] and [1] are the two
/// sets' suit masks (a set never repeats a suit, so masks suffice).
const Cover = struct {
    orphan: [13][2]u8 = @splat(.{ 0, 0 }), // MUST join a set at r
    donor: [13][2]u8 = @splat(.{ 0, 0 }), // MAY be peeled into one
    set_at: [13][2]u8 = @splat(.{ 0, 0 }), // the two sets' members
    donated: [MAX_ARCS]u16 = @splat(0), // per arc: rank mask peeled out
};

/// trySolve attempts a pure-runs-plus-sets cover. On success it fills
/// `next` (a fresh next-map) and returns true; on false, `next` is
/// untouched garbage and the caller falls through to the sweep.
///
/// `warm` is the board-bridge bias: the player's arrangement, lowered
/// to counts (arrangement.Warm). It reorders choices — which suits form
/// a repair set, where a full-cycle 13-run breaks — and never what is
/// reachable, so Warm.EMPTY reproduces the unbiased solve exactly.
/// (The per-suit arc DP carries no warm term on purpose: with orphans
/// then arcs already lexicographically minimal, the boundary-crossing
/// profile came out count-forced in every shape probed — add a third
/// cost component only on evidence of a real board where it isn't.)
pub fn trySolve(board: u128, warm: *const arrangement.Warm, next: *[graph.SLOTS]u8) bool {
    var st: Static = .{};
    for (0..4) |s| {
        var counts: [13]u8 = @splat(0);
        for (0..13) |r| {
            const base: u7 = @intCast(s * 13 + r);
            if (board >> base & 1 != 0) counts[r] += 1;
            if (board >> (@as(u7, base) + 52) & 1 != 0) counts[r] += 1;
        }
        decomposeSuit(&st, @intCast(s), counts);
    }
    var cov: Cover = .{};
    reclassify(&st, &cov);
    var attempts: u32 = 0;
    const done = repair(&st, cov, &attempts, warm) orelse return false;
    build(&st, &done, warm, next);
    return true;
}

fn addArc(st: *Static, suit: u8, start: u8, len: u8) void {
    const id: u8 = @intCast(st.arc_n);
    // Normalize full cycles to start at A so the donation-gap rotation
    // in reclassify/build/segLenAt works from a fixed base.
    const s0 = if (len == 13) 0 else start;
    st.arcs[st.arc_n] = .{ .suit = suit, .start = s0, .len = len };
    st.arc_n += 1;
    for (0..len) |k| {
        const r: u8 = @intCast((s0 + k) % 13);
        const cell = &st.arc_of[@as(usize, suit) * 13 + r];
        if (cell[0] == 0xFF) cell[0] = id else cell[1] = id;
    }
}

// ---------- per-suit decomposition (exact, tiny DP) ----------
//
// Cost is lexicographic (orphan cards, arc count), packed as
// orphans<<8 | arcs. The DP walks the 13 ranks from an anchor the
// cycle is known not to cross, carrying up to two open arcs whose
// lengths are capped at 3 (all that matters for orphan cost). Suits
// with no zero-count rank get their anchor arc enumerated explicitly.

const INF: u32 = 0xFFFF_FFFF;
const NSTATE = 10;
// Sorted (lo, hi) pairs of capped open-arc lengths; 0 = no arc.
const STATE_LENS = [NSTATE][2]u8{
    .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 1, 1 },
    .{ 1, 2 }, .{ 1, 3 }, .{ 2, 2 }, .{ 2, 3 }, .{ 3, 3 },
};

fn stateOf(a: u8, b: u8) u8 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    for (STATE_LENS, 0..) |sl, i| {
        if (sl[0] == lo and sl[1] == hi) return @intCast(i);
    }
    unreachable;
}

fn closeCost(capped: u8) u32 {
    return if (capped >= 3) 0 else @as(u32, capped) << 8;
}

fn arcCost(len: u8) u32 {
    return (if (len >= 3) @as(u32, 0) else @as(u32, len) << 8) | 1;
}

fn decomposeSuit(st: *Static, suit: u8, counts: [13]u8) void {
    var total: u8 = 0;
    var zero: i8 = -1;
    var one: i8 = -1;
    for (counts, 0..) |c, r| {
        total += c;
        if (c == 0 and zero < 0) zero = @intCast(r);
        if (c == 1 and one < 0) one = @intCast(r);
    }
    if (total == 0) return;
    if (zero >= 0) {
        _ = dpRun(st, suit, counts, @intCast(zero));
        return;
    }
    if (one < 0) { // every rank doubled: two full cycles is optimal
        addArc(st, suit, 0, 13);
        addArc(st, suit, 0, 13);
        return;
    }
    // No empty rank: exactly one arc covers the count-1 anchor.
    // Enumerate it, DP the remainder (which is empty at the anchor).
    const anchor: u8 = @intCast(one);
    var best: u32 = INF;
    var best_a: u8 = 0;
    var best_len: u8 = 0;
    for (0..13) |a| {
        var len: u8 = @intCast(a + 1);
        while (len <= 13) : (len += 1) {
            if (len == 13 and a != 0) break; // full cycle: count once
            var c2 = counts;
            const start: u8 = @intCast((anchor + 13 - a) % 13);
            for (0..len) |k| c2[(start + k) % 13] -= 1;
            const cost = arcCost(len) + dpRun(null, suit, c2, anchor);
            if (cost < best) {
                best = cost;
                best_a = @intCast(a);
                best_len = len;
            }
        }
    }
    var c2 = counts;
    const start: u8 = @intCast((anchor + 13 - best_a) % 13);
    for (0..best_len) |k| c2[(start + k) % 13] -= 1;
    addArc(st, suit, start, best_len);
    _ = dpRun(st, suit, c2, anchor);
}

/// dpRun finds the optimal arc decomposition of `counts` walking the
/// cycle from `anchor` (which must be empty, so no arc wraps the walk
/// boundary). With st == null it returns the cost only; with st it
/// also reconstructs and emits the arcs.
fn dpRun(st: ?*Static, suit: u8, counts: [13]u8, anchor: u8) u32 {
    var best: [14][NSTATE]u32 = @splat(@splat(INF));
    // Packed choice per (pos, state): prev_state<<4 | cont_mask<<2 | n_new.
    var chc: [14][NSTATE]u8 = undefined;
    best[0][0] = 0;
    for (0..13) |p| {
        const c = counts[(anchor + p) % 13];
        for (0..NSTATE) |si| {
            if (best[p][si] == INF) continue;
            const lens = STATE_LENS[si];
            var mask: u8 = 0;
            while (mask < 4) : (mask += 1) {
                if (mask & 1 != 0 and lens[0] == 0) continue;
                if (mask & 2 != 0 and lens[1] == 0) continue;
                if (lens[0] == lens[1] and mask == 2) continue; // twin
                const ncont = @popCount(mask);
                if (ncont > c) continue;
                const nnew = c - ncont;
                var cost = best[p][si] + @as(u32, nnew); // arcs opened
                var v0: u8 = 0;
                var v1: u8 = 0;
                if (mask & 1 != 0) v0 = @min(lens[0] + 1, 3) else cost += closeCost(lens[0]);
                if (mask & 2 != 0) v1 = @min(lens[1] + 1, 3) else cost += closeCost(lens[1]);
                if (nnew >= 1 and v0 == 0) v0 = 1 else if (nnew >= 1) v1 = 1;
                if (nnew == 2) v1 = 1;
                const ns = stateOf(v0, v1);
                if (cost < best[p + 1][ns]) {
                    best[p + 1][ns] = cost;
                    chc[p + 1][ns] = @intCast(si << 4 | mask << 2 | nnew);
                }
            }
        }
    }
    var bcost: u32 = INF;
    var bstate: u8 = 0;
    for (0..NSTATE) |si| {
        if (best[13][si] == INF) continue;
        const lens = STATE_LENS[si];
        const cost = best[13][si] + closeCost(lens[0]) + closeCost(lens[1]);
        if (cost < bcost) {
            bcost = cost;
            bstate = @intCast(si);
        }
    }
    const stp = st orelse return bcost;
    // Walk the choices back, then replay forward with real arcs.
    var masks: [13]u8 = undefined;
    var news: [13]u8 = undefined;
    var cur = bstate;
    var p: usize = 13;
    while (p > 0) : (p -= 1) {
        const ch = chc[p][cur];
        masks[p - 1] = ch >> 2 & 3;
        news[p - 1] = ch & 3;
        cur = ch >> 4;
    }
    // Real open arcs, slot-aligned with the state's sorted capped pair
    // (empty slots first; a new arc's cap 1 sorts below any continued
    // arc's cap ≥ 2, and equal-capped arcs are interchangeable).
    var open: [2]Arc = undefined;
    var caps: [2]u8 = .{ 0, 0 };
    for (0..13) |q| {
        const rank: u8 = @intCast((anchor + q) % 13);
        var nopen: [2]Arc = undefined;
        var ncaps: [2]u8 = .{ 0, 0 };
        var n: usize = 0;
        for (0..2) |slot| {
            if (caps[slot] == 0) continue;
            if (masks[q] >> @intCast(slot) & 1 != 0) {
                nopen[n] = open[slot];
                nopen[n].len += 1;
                ncaps[n] = @min(caps[slot] + 1, 3);
                n += 1;
            } else {
                addArc(stp, suit, open[slot].start, open[slot].len);
            }
        }
        for (0..news[q]) |_| {
            nopen[n] = .{ .suit = suit, .start = rank, .len = 1 };
            ncaps[n] = 1;
            n += 1;
        }
        // Re-sort into slot order: empties first, then capped ascending.
        open = undefined;
        caps = .{ 0, 0 };
        if (n == 1) {
            open[1] = nopen[0];
            caps[1] = ncaps[0];
        } else if (n == 2) {
            const swap = ncaps[0] > ncaps[1];
            open[0] = nopen[if (swap) 1 else 0];
            caps[0] = ncaps[if (swap) 1 else 0];
            open[1] = nopen[if (swap) 0 else 1];
            caps[1] = ncaps[if (swap) 0 else 1];
        }
    }
    for (0..2) |slot| {
        if (caps[slot] != 0) addArc(stp, suit, open[slot].start, open[slot].len);
    }
    return bcost;
}

// ---------- classification and repair ----------

fn addTo(m: *[13][2]u8, r: u8, suit: u8) void {
    const b = @as(u8, 1) << @intCast(suit);
    if (m[r][0] & b != 0) m[r][1] |= b else m[r][0] |= b;
}

fn cnt2(pair: [2]u8, s: usize) u8 {
    return (pair[0] >> @intCast(s) & 1) + (pair[1] >> @intCast(s) & 1);
}

/// reclassify derives orphan/donor multiplicities from the arcs minus
/// what's been donated: residual segments of length ≥ 3 are donor
/// material (any of their cards may still be peeled), shorter
/// residuals are orphans that must be absorbed. Set members sit behind
/// their donated bits.
fn reclassify(st: *const Static, cov: *Cover) void {
    cov.orphan = @splat(.{ 0, 0 });
    cov.donor = @splat(.{ 0, 0 });
    for (st.arcs[0..st.arc_n], 0..) |arc, ai| {
        const d = cov.donated[ai];
        if (arc.len == 13 and d == 0) {
            for (0..13) |r| addTo(&cov.donor, @intCast(r), arc.suit);
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
    for (ranks) |r| addTo(target, r, suit);
}

/// The length of the undonated segment of arc `ai` containing rank r.
fn segLenAt(st: *const Static, cov: *const Cover, ai: u8, r: u8) u8 {
    const arc = st.arcs[ai];
    const d = cov.donated[ai];
    if (d == 0) return arc.len;
    var start = arc.start;
    if (arc.len == 13) start = @intCast((@as(u8, @intCast(@ctz(d))) + 1) % 13);
    const k0 = (@as(usize, r) + 13 - start) % 13;
    var len: u8 = 1;
    var k = k0;
    while (k + 1 < arc.len) {
        k += 1;
        if (d >> @intCast((start + k) % 13) & 1 != 0) break;
        len += 1;
    }
    k = k0;
    while (k > 0) {
        k -= 1;
        if (d >> @intCast((start + k) % 13) & 1 != 0) break;
        len += 1;
    }
    return len;
}

/// Mark `m` total set memberships of (suit, rank) as consumed, i.e.
/// peel that many covering arcs. Arcs already peeled at this rank are
/// prior commitments and count toward m. Orphan segments peel before
/// donor segments — copies are interchangeable, so the set may as well
/// take the card that can't stand as a run. (When two donor arcs could
/// each give the single needed card, the first is taken without
/// branching: a deliberate incompleteness — tier 0 may pass.)
fn consumeCards(st: *const Static, cov: *Cover, suit: usize, rank: u8, m: u8) void {
    const cell = st.arc_of[suit * 13 + rank];
    var avail: [2]u8 = undefined;
    var na: u8 = 0;
    var marked: u8 = 0;
    for (cell) |ai| {
        if (ai == 0xFF) continue;
        if (cov.donated[ai] >> @intCast(rank) & 1 != 0) {
            marked += 1;
        } else {
            avail[na] = ai;
            na += 1;
        }
    }
    var need = m - marked;
    if (need == 0) return;
    if (need == 1 and na == 2 and segLenAt(st, cov, avail[0], rank) >= 3 and
        segLenAt(st, cov, avail[1], rank) < 3)
    {
        avail[0] = avail[1];
    }
    var i: u8 = 0;
    while (need > 0) : (need -= 1) {
        cov.donated[avail[i]] |= @as(u16, 1) << @intCast(rank);
        i += 1;
    }
}

/// repair: find the first rank with unabsorbed orphan cards and branch
/// over the (up to two) sets that absorb them — fewest broken warm set
/// pairs first, then fewest extra donations. Donations may strand short
/// segments; reclassify turns those into new orphans and the recursion
/// absorbs them in turn — or fails, backtracking. Returns the finished
/// cover, or null.
fn repair(st: *const Static, cov: Cover, attempts: *u32, warm: *const arrangement.Warm) ?Cover {
    attempts.* += 1;
    if (attempts.* > 4096) return null; // cap: tier 0 may just pass
    var rank: u8 = 13;
    for (0..13) |r| {
        if (cov.orphan[r][0] != 0) {
            rank = @intCast(r);
            break;
        }
    }
    if (rank == 13) return cov; // every orphan absorbed: done
    const must_a = cov.set_at[rank][0];
    const must_b = cov.set_at[rank][1];
    var cands: [64]SetCand = undefined;
    var n_cand: usize = 0;
    var a: u8 = 0;
    while (a < 16) : (a += 1) {
        if (a & must_a != must_a) continue;
        if (a != 0 and (@popCount(a) < 3 or @popCount(a) > 4)) continue;
        var b: u8 = 0;
        blk: while (b < 16) : (b += 1) {
            if (b & must_b != must_b) continue;
            if (b != 0 and a == 0) continue;
            if (b != 0 and (@popCount(b) < 3 or @popCount(b) > 4)) continue;
            if (must_a == must_b and b > a) continue; // unordered pair
            var don: u8 = 0;
            for (0..4) |s| {
                const m = (a >> @intCast(s) & 1) + (b >> @intCast(s) & 1);
                const committed = cnt2(cov.set_at[rank], s);
                if (m < committed) continue :blk;
                const fresh = m - committed;
                const oc = cnt2(cov.orphan[rank], s);
                if (fresh < oc) continue :blk; // orphan left behind
                if (fresh - oc > cnt2(cov.donor[rank], s)) continue :blk;
                don += fresh - oc;
            }
            cands[n_cand] = .{
                .a = a,
                .b = b,
                .wb = brokenSetPairs(warm, rank, a, b),
                .don = don,
            };
            n_cand += 1;
        }
    }
    std.mem.sort(SetCand, cands[0..n_cand], {}, candLess);
    for (cands[0..n_cand]) |cd| {
        var nc = cov;
        nc.set_at[rank] = .{ cd.a, cd.b };
        for (0..4) |s| {
            const m = (cd.a >> @intCast(s) & 1) + (cd.b >> @intCast(s) & 1);
            if (m != 0) consumeCards(st, &nc, s, rank, m);
        }
        reclassify(st, &nc);
        if (repair(st, nc, attempts, warm)) |done| return done;
    }
    return null;
}

const SetCand = struct { a: u8, b: u8, wb: u8, don: u8 };

fn candLess(_: void, x: SetCand, y: SetCand) bool {
    if (x.wb != y.wb) return x.wb < y.wb;
    return x.don < y.don;
}

/// How many of the player's warm set pairs the candidate sets (a, b)
/// would break at this rank — the same co-membership greedy the report
/// uses, so the ordering chases the reported metric. 0 when warm is
/// empty, keeping the sort identical to the unbiased one.
fn brokenSetPairs(warm: *const arrangement.Warm, rank: u8, a: u8, b: u8) u8 {
    var broken: u8 = 0;
    var rem = [2]u8{ a, b };
    for (warm.set_masks[rank][0..warm.set_n[rank]]) |m| {
        var pairs: u8 = @popCount(m) - 1;
        if (@popCount(m & rem[1]) > @popCount(m & rem[0]))
            std.mem.swap(u8, &rem[0], &rem[1]);
        for (&rem) |*o| {
            const ov: u8 = @popCount(m & o.*);
            if (ov >= 2) pairs -= @min(pairs, ov - 1);
            o.* &= ~m;
        }
        broken += pairs;
    }
    return broken;
}

// ---------- building the next-map ----------

/// build writes the cover into a fresh next-map: residual arc segments
/// as pure runs, chosen sets as same-rank chains (ascending suit).
/// Copies are assigned first-come per (suit, rank) — the search never
/// distinguished them, so any consistent assignment is correct.
fn build(st: *const Static, cov: *const Cover, warm: *const arrangement.Warm, next: *[graph.SLOTS]u8) void {
    next.* = @splat(graph.NONE);
    var used: [graph.N]u8 = @splat(0);
    for (st.arcs[0..st.arc_n], 0..) |arc, ai| {
        const d = cov.donated[ai];
        if (arc.len == 13 and d == 0) {
            // The full cycle stands as one 13-run, broken at the
            // COLDEST boundary — the start rank whose incoming edge
            // carries the least warmth. All-cold scans to A, the old
            // fixed choice.
            var start: u8 = 0;
            var coldest: u8 = 255;
            for (0..13) |x| {
                const wb = warm.pure[arc.suit][(x + 12) % 13];
                if (wb < coldest) {
                    coldest = wb;
                    start = @intCast(x);
                }
            }
            var prev = takeSlot(&used, arc.suit, start);
            for (1..13) |r| {
                const cur = takeSlot(&used, arc.suit, @intCast((start + r) % 13));
                next[prev] = cur;
                prev = cur;
            }
            continue;
        }
        var offset: u8 = 0;
        if (arc.len == 13) offset = @as(u8, @intCast(@ctz(d))) + 1;
        var prev: u8 = graph.NONE;
        for (0..arc.len) |k| {
            const r: u8 = @intCast((arc.start + offset + k) % 13);
            if (d >> @intCast(r) & 1 != 0) {
                prev = graph.NONE;
                continue;
            }
            const cur = takeSlot(&used, arc.suit, r);
            if (prev != graph.NONE) next[prev] = cur;
            prev = cur;
        }
    }
    for (0..13) |r| {
        for (cov.set_at[r]) |mask| {
            var m = mask;
            var prev: u8 = graph.NONE;
            while (m != 0) {
                const s: u8 = @intCast(@ctz(m));
                m &= m - 1;
                const cur = takeSlot(&used, s, @intCast(r));
                if (prev != graph.NONE) next[prev] = cur;
                prev = cur;
            }
        }
    }
}

fn takeSlot(used: *[graph.N]u8, suit: u8, rank: u8) u8 {
    const base = @as(usize, suit) * 13 + rank;
    const copy = used[base];
    used[base] += 1;
    return @intCast(base + @as(usize, copy) * 52);
}

fn cardAt(suit: u8, rank: u8) u8 {
    return suit * 13 + rank;
}

// ---------- tests (native: ops/check_solver) ----------
// Mechanics only; end-to-end verification lives in solver.zig, which
// owns the strict verifier.

test "no orphans: full and partial suits stand as pure runs" {
    var next: [graph.SLOTS]u8 = undefined;
    // All 13 hearts.
    try std.testing.expect(trySolve(0x1FFF, &arrangement.Warm.EMPTY, &next));
    // Hearts 3..7 (ranks 2..6): one arc, stands alone.
    try std.testing.expect(trySolve(0b1111100, &arrangement.Warm.EMPTY, &next));
}

test "orphans absorbed by a set with donor peels" {
    var next: [graph.SLOTS]u8 = undefined;
    // The keystone shape: A♠ is an orphan; A♥ and A♦ each head a
    // 4-arc, so peeling them leaves legal 3-runs — the ace set forms.
    const hearts: u64 = 0b1111;
    const diamonds: u64 = 0b1111 << 13;
    const as_bit: u64 = @as(u64, 1) << (3 * 13);
    try std.testing.expect(trySolve(hearts | diamonds | as_bit, &arrangement.Warm.EMPTY, &next));
}

test "ejection chain: a stranding donation cascades into more sets" {
    var next: [graph.SLOTS]u8 = undefined;
    // 6D 6C, 7S 7C, 8D 8C as loner pairs plus the 6H 7H 8H arc.
    // Rank 6 needs 6H; donating it strands 7H 8H, which then complete
    // the rank-7 and rank-8 sets — three sets, no run survives.
    const b = bit(0, 5) | bit(0, 6) | bit(0, 7) // 6H 7H 8H
    | bit(1, 5) | bit(2, 5) // 6D 6C
    | bit(3, 6) | bit(2, 6) // 7S 7C
    | bit(1, 7) | bit(2, 7); // 8D 8C
    try std.testing.expect(trySolve(b, &arrangement.Warm.EMPTY, &next));
    // Spot-check the cascade's output: three same-rank chains.
    try std.testing.expectEqual(cardAt(2, 5), next[cardAt(1, 5)]); // 6D=6C
    try std.testing.expectEqual(cardAt(2, 6), next[cardAt(0, 6)]); // 7H=7C
    try std.testing.expectEqual(cardAt(2, 7), next[cardAt(1, 7)]); // 8D=8C
}

test "tier 0 passes (returns false) when orphans can't set" {
    var next: [graph.SLOTS]u8 = undefined;
    // Lone A♠: orphan, no donors anywhere.
    try std.testing.expect(!trySolve(@as(u64, 1) << (3 * 13), &arrangement.Warm.EMPTY, &next));
    // A♠ + one donor suit only: set can't reach 3.
    const hearts: u64 = 0b1111;
    try std.testing.expect(!trySolve(hearts | @as(u64, 1) << (3 * 13), &arrangement.Warm.EMPTY, &next));
}

test "staircase: 3 4 4' 5 5' 6 is two overlapping runs, no set" {
    var next: [graph.SLOTS]u8 = undefined;
    // Counts H: ranks 2..5 = 1,2,2,1 — the level split strands the
    // doubled pair; the DP must find 3-4-5 / 4-5-6.
    const b = dbit(0, 2, 0) | dbit(0, 3, 0) | dbit(0, 3, 1) |
        dbit(0, 4, 0) | dbit(0, 4, 1) | dbit(0, 5, 0);
    try std.testing.expect(trySolve(b, &arrangement.Warm.EMPTY, &next));
    try std.testing.expectEqual(cardAt(0, 3), next[cardAt(0, 2)]); // 3H>4H
    try std.testing.expectEqual(cardAt(0, 4), next[cardAt(0, 3)]); // 4H>5H
    try std.testing.expectEqual(cardAt(0, 4) + 52, next[cardAt(0, 3) + 52]); // 4H'>5H'
    try std.testing.expectEqual(cardAt(0, 5), next[cardAt(0, 4) + 52]); // 5H'>6H
}

test "fully doubled suit: two parallel 13-runs" {
    var next: [graph.SLOTS]u8 = undefined;
    const b: u128 = 0x1FFF | (@as(u128, 0x1FFF) << 52);
    try std.testing.expect(trySolve(b, &arrangement.Warm.EMPTY, &next));
    for (0..12) |r| {
        try std.testing.expectEqual(cardAt(0, @intCast(r + 1)), next[cardAt(0, @intCast(r))]);
        try std.testing.expectEqual(cardAt(0, @intCast(r + 1)) + 52, next[cardAt(0, @intCast(r)) + 52]);
    }
}

test "doubled orphan pair splits across two sets at one rank" {
    var next: [graph.SLOTS]u8 = undefined;
    // 6H 6H' both orphans; diamonds and clubs 3..9 doubled donate a 6
    // from each layer — two sets {6H,6D,6C}, {6H',6D',6C'}, and the
    // donor arcs strand nothing (3-4-5 and 7-8-9 survive).
    var b: u128 = dbit(0, 5, 0) | dbit(0, 5, 1);
    for (2..9) |r| {
        b |= dbit(1, @intCast(r), 0) | dbit(1, @intCast(r), 1);
        b |= dbit(2, @intCast(r), 0) | dbit(2, @intCast(r), 1);
    }
    try std.testing.expect(trySolve(b, &arrangement.Warm.EMPTY, &next));
}

test "warm set choice steers which suits absorb the orphan" {
    var next: [graph.SLOTS]u8 = undefined;
    // A♠ orphan; hearts, diamonds and clubs each hold A..4, so any
    // three-suit ace set is reachable at equal donation cost.
    const b = bit(0, 0) | bit(0, 1) | bit(0, 2) | bit(0, 3) // AH..4H
    | bit(1, 0) | bit(1, 1) | bit(1, 2) | bit(1, 3) // AD..4D
    | bit(2, 0) | bit(2, 1) | bit(2, 2) | bit(2, 3) // AC..4C
    | bit(3, 0); // AS
    const pair = try arrangement.parse("AS=AC");
    // Cold: the first enumerated candidate wins — {H,D,S}, no clubs.
    try std.testing.expect(trySolve(b, &arrangement.Warm.EMPTY, &next));
    const cold = arrangement.reportKept(&pair, &next);
    try std.testing.expectEqual(@as(u16, 0), cold.kept_edges);
    // The player's AS=AC pair steers the set to include clubs.
    var w = arrangement.Warm.EMPTY;
    w.set_masks[0][0] = 0b1100; // {C,S}
    w.set_n[0] = 1;
    try std.testing.expect(trySolve(b, &w, &next));
    const rep = arrangement.reportKept(&pair, &next);
    try std.testing.expectEqual(@as(u16, 1), rep.kept_edges);
    try std.testing.expectEqual(arrangement.Fate.intact, rep.fate[0]);
}

test "a full-cycle 13-run breaks at the coldest boundary" {
    var next: [graph.SLOTS]u8 = undefined;
    // All 13 hearts; the player's stack rides the wrap: QH>KH>AH>2H.
    var w = arrangement.Warm.EMPTY;
    w.pure[0][11] = 1; // Q>K
    w.pure[0][12] = 1; // K>A
    w.pure[0][0] = 1; // A>2
    try std.testing.expect(trySolve(0x1FFF, &w, &next));
    try std.testing.expectEqual(cardAt(0, 0), next[cardAt(0, 12)]); // KH>AH kept
    try std.testing.expectEqual(cardAt(0, 1), next[cardAt(0, 0)]); // AH>2H kept
    try std.testing.expectEqual(graph.NONE, next[cardAt(0, 1)]); // cold 2H|3H broken
    // Cold board: the old fixed break at A.
    try std.testing.expect(trySolve(0x1FFF, &arrangement.Warm.EMPTY, &next));
    try std.testing.expectEqual(graph.NONE, next[cardAt(0, 12)]);
}

fn bit(suit: u8, rank: u8) u64 {
    return @as(u64, 1) << @intCast(@as(u32, suit) * 13 + rank);
}

fn dbit(suit: u8, rank: u8, copy: u8) u128 {
    return @as(u128, 1) << @intCast(@as(u32, suit) * 13 + rank + @as(u32, copy) * 52);
}
