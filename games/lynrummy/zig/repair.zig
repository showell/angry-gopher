//! repair — the local-repair tier: search small edits of the player's
//! arrangement before any global cover enumeration. Born from Steve's
//! 6C' find (2026-07-23): on a 73-card board the sweep was
//! warm-UNKNOWN at 1M steps and cold-SOLVED only by tearing half the
//! table apart (kept 23/51), while the human answer was two gestures
//! keeping everything but one link. Humans search "small edits to
//! what's in front of me" — a geometry the cover enumeration doesn't
//! have. This tier is that geometry, bounded.
//!
//! The search is PROBLEM-DIRECTED: always address the first short
//! stack (len < 3). Three ops, each one edit of depth budget:
//!   A: attach one of its cards to a legal seat elsewhere
//!   B: bring a legal card to it from elsewhere
//!   C: seat swap — its card displaces an END card of a full stack
//!      (the displaced card becomes the next problem; this is the
//!      6C'-takes-6S's-seat move, and it is what keeps the search
//!      directed when the fixing edit touches two full stacks)
//! IDDFS depth 1..MAX_EDITS with whole-arrangement undo, a shortness
//! bound (each edit can shed at most 2 points of shortness), and a
//! hard node cap. Repair can only ever answer SOLVED — futility and
//! give-ups stay the sweep's job.

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");
const arrangement = @import("arrangement.zig");

const MAX_EDITS = 3;
const MAX_NODES = 10_000;

/// A clean cover found by local repair, as the sparse next-map the
/// rest of the pipeline (reportKept, distill, sim) consumes — or null:
/// no verdict, fall through to the sweep.
pub fn tryRepair(arr: *const arrangement.Arrangement) ?[graph.SLOTS]u8 {
    var work = arr.*;
    var nodes: u32 = 0;
    var depth: u8 = 1;
    while (depth <= MAX_EDITS) : (depth += 1) {
        if (search(&work, depth, &nodes)) return toNext(&work);
        if (nodes >= MAX_NODES) return null;
    }
    return null;
}

fn search(arr: *arrangement.Arrangement, depth: u8, nodes: *u32) bool {
    const p = firstShort(arr) orelse return true;
    if (depth == 0 or nodes.* >= MAX_NODES) return false;
    if (shortness(arr) > 2 * @as(u16, depth)) return false;
    nodes.* += 1;

    const undo = arr.*;
    const pcs = arr.stackCards(p);

    // Op A: a problem card takes a legal seat on another stack.
    for (0..pcs.len) |xi| {
        const x = pcs[xi];
        for (0..arr.n_stacks) |s| {
            if (s == p) continue;
            var pos: usize = undefined;
            if (!canAttach(arr, s, x, &pos)) continue;
            removeCard(arr, p, xi);
            const s_adj = if (p < s and pcs.len == 1) s - 1 else s;
            insertCard(arr, s_adj, pos, x);
            if (search(arr, depth - 1, nodes)) return true;
            arr.* = undo;
        }
    }

    // Op B: bring a legal card to the problem stack.
    for (0..arr.n_stacks) |q| {
        if (q == p) continue;
        const qcs = arr.stackCards(q);
        for (0..qcs.len) |yi| {
            if (!removable(qcs, yi)) continue;
            const y = qcs[yi];
            var pos: usize = undefined;
            if (!canAttach(arr, p, y, &pos)) continue;
            removeCard(arr, q, yi);
            const p_adj = if (q < p and qcs.len == 1) p - 1 else p;
            insertCard(arr, p_adj, pos, y);
            if (search(arr, depth - 1, nodes)) return true;
            arr.* = undo;
        }
    }

    // Op C: seat swap — a problem card displaces an end card of a
    // full stack; the displaced card becomes a fresh singleton (the
    // next problem). Only from singleton problems: a 2-stack's fix
    // should keep its own pair together, and singletons are where
    // the human move lives (the appended hand card).
    if (pcs.len == 1) {
        const x = pcs[0];
        for (0..arr.n_stacks) |q| {
            if (q == p) continue;
            const qcs = arr.stackCards(q);
            if (qcs.len < 3) continue;
            for ([2]usize{ 0, qcs.len - 1 }) |yi| {
                if (!seatFits(qcs, yi, x)) continue;
                const y = qcs[yi];
                // Replace y with x in place; y opens as a singleton.
                arr.cards[arr.start[q] + yi] = x;
                removeCard(arr, p, 0);
                appendSingleton(arr, y);
                if (search(arr, depth - 1, nodes)) return true;
                arr.* = undo;
            }
        }
    }

    return false;
}

// ---------- problem selection & pruning ----------

fn firstShort(arr: *const arrangement.Arrangement) ?usize {
    for (0..arr.n_stacks) |i| {
        if (arr.stackCards(i).len < 3) return i;
    }
    return null;
}

fn shortness(arr: *const arrangement.Arrangement) u16 {
    var s: u16 = 0;
    for (0..arr.n_stacks) |i| {
        const len = arr.stackCards(i).len;
        if (len < 3) s += @intCast(3 - len);
    }
    return s;
}

// ---------- legality ----------

fn stackFlavor(cs: []const card.Card) ?graph.EdgeFlavor {
    if (cs.len < 2) return null;
    return graph.edgeFlavor(graph.cardIndex(cs[0]), graph.cardIndex(cs[1]));
}

/// Can `x` legally join stack `s` (set membership, run head, or run
/// tail)? On yes, `pos` is the insertion index.
fn canAttach(arr: *const arrangement.Arrangement, s: usize, x: card.Card, pos: *usize) bool {
    const cs = arr.stackCards(s);
    if (cs.len >= 13) return false;
    if (cs.len == 1) {
        // Runs are directional; a singleton accepts x on either side.
        if (graph.edgeFlavor(graph.cardIndex(cs[0]), graph.cardIndex(x)) != null) {
            pos.* = 1;
            return true;
        }
        if (graph.edgeFlavor(graph.cardIndex(x), graph.cardIndex(cs[0])) != null) {
            pos.* = 0;
            return true;
        }
        return false;
    }
    const flavor = stackFlavor(cs).?;
    if (flavor == .set) {
        if (x.rank != cs[0].rank) return false;
        for (cs) |c| {
            if (c.suit == x.suit) return false;
        }
        pos.* = cs.len;
        return true;
    }
    // Run: rank must be fresh, and the junction edge must match the
    // stack's flavor.
    for (cs) |c| {
        if (c.rank == x.rank) return false;
    }
    if (graph.edgeFlavor(graph.cardIndex(x), graph.cardIndex(cs[0]))) |f| {
        if (f == flavor) {
            pos.* = 0;
            return true;
        }
    }
    if (graph.edgeFlavor(graph.cardIndex(cs[cs.len - 1]), graph.cardIndex(x))) |f| {
        if (f == flavor) {
            pos.* = cs.len;
            return true;
        }
    }
    return false;
}

/// Which members may leave a stack: run ends only (the never-pull-
/// from-the-middle table norm); any member of a set; a singleton's
/// card.
fn removable(cs: []const card.Card, i: usize) bool {
    if (cs.len <= 2) return true;
    if (stackFlavor(cs) == .set) return true;
    return i == 0 or i == cs.len - 1;
}

/// Can `x` sit in seat `yi` (an end) of full stack `cs` with the
/// incumbent gone — same flavor into the neighbor, no rank/suit
/// collision with the rest?
fn seatFits(cs: []const card.Card, yi: usize, x: card.Card) bool {
    const flavor = stackFlavor(cs).?;
    if (flavor == .set) {
        if (x.rank != cs[0].rank) return false;
        for (cs, 0..) |c, i| {
            if (i != yi and c.suit == x.suit) return false;
        }
        return true;
    }
    for (cs, 0..) |c, i| {
        if (i != yi and c.rank == x.rank) return false;
    }
    const nb = if (yi == 0) cs[1] else cs[cs.len - 2];
    const f = if (yi == 0)
        graph.edgeFlavor(graph.cardIndex(x), graph.cardIndex(nb))
    else
        graph.edgeFlavor(graph.cardIndex(nb), graph.cardIndex(x));
    return f == flavor;
}

// ---------- arrangement surgery (undo = whole-struct restore) ----------

fn removeCard(arr: *arrangement.Arrangement, s: usize, i: usize) void {
    const at = arr.start[s] + i;
    const n = arr.start[arr.n_stacks];
    std.mem.copyForwards(card.Card, arr.cards[at .. n - 1], arr.cards[at + 1 .. n]);
    if (arr.stackCards(s).len == 1) {
        // Stack vanishes.
        for (s + 1..arr.n_stacks + 1) |k| arr.start[k - 1] = arr.start[k] - 1;
        arr.n_stacks -= 1;
    } else {
        for (s + 1..arr.n_stacks + 1) |k| arr.start[k] -= 1;
    }
}

fn insertCard(arr: *arrangement.Arrangement, s: usize, i: usize, c: card.Card) void {
    const at = arr.start[s] + i;
    const n = arr.start[arr.n_stacks];
    std.mem.copyBackwards(card.Card, arr.cards[at + 1 .. n + 1], arr.cards[at..n]);
    arr.cards[at] = c;
    for (s + 1..arr.n_stacks + 1) |k| arr.start[k] += 1;
}

fn appendSingleton(arr: *arrangement.Arrangement, c: card.Card) void {
    const n = arr.start[arr.n_stacks];
    arr.cards[n] = c;
    arr.n_stacks += 1;
    arr.start[arr.n_stacks] = n + 1;
}

// ---------- lowering to the sparse next-map ----------

fn toNext(arr: *const arrangement.Arrangement) [graph.SLOTS]u8 {
    var next: [graph.SLOTS]u8 = @splat(graph.NONE);
    var used_base = [_]bool{false} ** graph.N;
    var slots: [card.MAX_CARDS]u8 = undefined;
    for (arr.cards[0..arr.nCards()], 0..) |c, i| {
        const base = @as(u8, c.suit) * 13 + c.rank;
        if (!used_base[base]) {
            used_base[base] = true;
            slots[i] = base;
        } else {
            slots[i] = base + graph.N;
        }
    }
    for (0..arr.n_stacks) |s| {
        const from = arr.start[s];
        const to = arr.start[s + 1];
        for (from..to - 1) |i| next[slots[i]] = slots[i + 1];
    }
    return next;
}

// ---------- tests (native: ops/check_solver) ----------

const testing = std.testing;

const Kept = struct { kept: u16, total: u16 };

fn repairKept(board_line: []const u8, extra: []const u8) !?Kept {
    var arr = try arrangement.parse(board_line);
    if (extra.len > 0) appendSingleton(&arr, try card.parseCard(extra));
    const next = tryRepair(&arr) orelse return null;
    const rep = arrangement.reportKept(&arr, &next);
    return .{ .kept = rep.kept_edges, .total = rep.total_edges };
}

test "one-edit repair: the trivial run extension" {
    const r = (try repairKept("5H>6H>7H TS=TC=TD", "8H")).?;
    try testing.expectEqual(r.total, r.kept);
}

test "the 6C' board: two gestures, one broken link" {
    // Steve's find, verbatim (seed 240 turn 13 cut + 6C'): the sweep
    // was warm-UNKNOWN at 1M steps and cold-solved at kept 23/51;
    // his line — 6C' takes 6S's seat, 6S extends the spade run —
    // keeps every edge but [6S>7H]. Repair finds exactly that class.
    const board =
        "4H=4D=4S 5H=5C=5S 8H'=8C=8S TH=TD=TS AD>2C>3D>4C 5D>6D>7D " ++
        "KD>AC>2H>3C' 9C'>TC>JC 6S>7H>8C' AH>2C'>3D'>4C' 7H'=7C=7S " ++
        "TH'>JS>QH'>KS>AH' AD'>2S>3H 5D'>6D'>7D' JD>QS'>KH KD'>AS>2H' " ++
        "2S'>3S>4S' 3S'>4D'>5C' 7S'>8S'>9S 9S'>TD'>JC'>QD>KS' " ++
        "TS'>JD'>QC'>KH'>AC'";
    const r = (try repairKept(board, "6C'")).?;
    try testing.expectEqual(@as(u16, 51), r.total);
    try testing.expectEqual(@as(u16, 50), r.kept);
}

test "gathering loose cards into a fresh set" {
    // 7C loose on the board, 7H appended: repair pairs them, and a
    // third loose seven completes the meld.
    const r = (try repairKept("7C 7D 3S>4S>5S", "7H")).?;
    try testing.expectEqual(r.total, r.kept);
}

test "deep restructures are not repair's job" {
    // 5C on the opening board forces a six-break rebuild (the sweep
    // finds kept 11/17) — far beyond three edits. Repair passes.
    const board = "KS>AS>2S>3S TD>JD>QD>KD 2H>3H>4H 7S=7D=7C AC=AD=AH " ++
        "2C>3D>4C>5H>6S>7H";
    try testing.expectEqual(@as(?Kept, null), try repairKept(board, "5C"));
}

test "a board with no cover is a fall-through, never a false solve" {
    try testing.expectEqual(@as(?Kept, null), try repairKept("3H>4H 5H KC", ""));
}
