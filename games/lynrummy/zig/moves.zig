//! moves — distill the edge diff between the player's arrangement and
//! a cover into the five human verbs: peel, steal, push, split, merge.
//! Intact stacks say nothing.
//!
//! In a full cover every card ends up melded, so every extraction has
//! a destination: break-edge and make-edge events pair up by card, and
//! the pair IS the compound verb ("peel X from [S] onto [T]"). Sets
//! diff as MEMBERSHIP, never chain order — the same rule reportKept
//! scores by.
//!
//! Copies first: a cover's deck marks are first-come dressing (the
//! search never distinguished copies), so diffing them literally
//! describes surgery on the wrong twin. Step 0 re-dresses the cover —
//! greedy label swaps per doubled card — to hug the player's physical
//! stacks, and only then is the diff taken.
//!
//! The distiller BUILDS the plan by simulating it: each emitted move
//! transforms a working board, and at the end the working board must
//! equal the re-dressed cover exactly — runs by sequence, sets by
//! membership. A mismatch is a distiller bug and fails loud
//! (DistillFailed); the move list cannot lie about what it builds.
//! What this does NOT promise is gesture-level choreography: the list
//! is a faithful build recipe, not a proof that every intermediate
//! state is reachable under UI gesture rules.

const std = @import("std");
const card = @import("card.zig");
const graph = @import("graph.zig");
const arrangement = @import("arrangement.zig");

pub const Verb = enum { peel, steal, push, split, merge };

pub const Error = error{DistillFailed};

const CAP = 32; // max cards in one stack snapshot
const MAX_STACKS = 208; // input stacks plus every split's new half
pub const MAX_MOVES = 256;

pub const Snap = struct {
    n: u8 = 0,
    cards: [CAP]u8 = undefined, // slots

    fn of(slice: []const u8) Snap {
        var s: Snap = .{ .n = @intCast(slice.len) };
        @memcpy(s.cards[0..slice.len], slice);
        return s;
    }
};

pub const Move = struct {
    verb: Verb,
    card: u8, // the moved slot (peel/steal/push); unused for split/merge
    src: Snap, // pre-move source stack (peel/steal/split; merge: the moving block)
    dst: Snap, // pre-move destination (empty: extraction to the table)
    result: Snap, // post-move destination (split: the left half)
    aux: Snap, // split only: the right half
    complete: bool, // result is a legal meld
};

pub const Plan = struct {
    moves: [MAX_MOVES]Move = undefined,
    n: usize = 0,
};

// ---------- the working board ----------

const Sim = struct {
    buf: [MAX_STACKS][CAP]u8 = undefined,
    len: [MAX_STACKS]u8 = @splat(0),
    n: usize = 0,
    loc_stack: [graph.SLOTS]u8 = @splat(NOWHERE),
    loc_pos: [graph.SLOTS]u8 = undefined,

    const NOWHERE: u8 = 0xFF;

    fn stack(self: *const Sim, si: u8) []const u8 {
        return self.buf[si][0..self.len[si]];
    }

    fn reindex(self: *Sim, si: u8) void {
        for (self.stack(si), 0..) |slot, p| {
            self.loc_stack[slot] = si;
            self.loc_pos[slot] = @intCast(p);
        }
    }

    fn addStack(self: *Sim, cards_: []const u8) u8 {
        const si: u8 = @intCast(self.n);
        self.n += 1;
        @memcpy(self.buf[si][0..cards_.len], cards_);
        self.len[si] = @intCast(cards_.len);
        self.reindex(si);
        return si;
    }

    /// A stack is set-shaped when its cards share a rank. Singles are
    /// neither; callers route them through the push path first.
    fn isSet(self: *const Sim, si: u8) bool {
        const s = self.stack(si);
        if (s.len < 2) return false;
        return graph.rankOf(s[0]) == graph.rankOf(s[1]);
    }

    fn removeAt(self: *Sim, si: u8, pos: u8) void {
        const l = self.len[si];
        std.mem.copyForwards(u8, self.buf[si][pos .. l - 1], self.buf[si][pos + 1 .. l]);
        self.len[si] = l - 1;
        self.reindex(si);
    }

    /// Split stack si before pos; the suffix becomes a new stack.
    fn splitOff(self: *Sim, si: u8, pos: u8) u8 {
        const ni: u8 = @intCast(self.n);
        self.n += 1;
        const l = self.len[si];
        @memcpy(self.buf[ni][0 .. l - pos], self.buf[si][pos..l]);
        self.len[ni] = l - pos;
        self.len[si] = pos;
        self.reindex(ni);
        return ni;
    }

    fn appendCard(self: *Sim, si: u8, slot: u8, left: bool) void {
        const l = self.len[si];
        if (left) {
            std.mem.copyBackwards(u8, self.buf[si][1 .. l + 1], self.buf[si][0..l]);
            self.buf[si][0] = slot;
        } else {
            self.buf[si][l] = slot;
        }
        self.len[si] = l + 1;
        self.reindex(si);
    }

    /// Absorb whole stack `from` into `into` on the given side; `from`
    /// dies.
    fn absorb(self: *Sim, into: u8, from: u8, left: bool) void {
        const fl = self.len[from];
        const il = self.len[into];
        if (left) {
            std.mem.copyBackwards(u8, self.buf[into][fl .. fl + il], self.buf[into][0..il]);
            @memcpy(self.buf[into][0..fl], self.buf[from][0..fl]);
        } else {
            @memcpy(self.buf[into][il .. il + fl], self.buf[from][0..fl]);
        }
        self.len[into] = il + fl;
        self.len[from] = 0;
        self.reindex(into);
    }
};

fn isMeld(cards_: []const u8) bool {
    if (cards_.len < 3) return false;
    var flavor: ?graph.EdgeFlavor = null;
    var suits: u8 = @as(u8, 1) << @intCast(graph.suitOf(cards_[0]));
    for (cards_[0 .. cards_.len - 1], cards_[1..]) |a, b| {
        const f = graph.edgeFlavor(a, b) orelse return false;
        if (flavor) |have| {
            if (have != f) return false;
        } else flavor = f;
        if (f == .set) {
            const sb = @as(u8, 1) << @intCast(graph.suitOf(b));
            if (suits & sb != 0) return false;
            suits |= sb;
        }
    }
    return true;
}

// ---------- the distiller ----------

const Distiller = struct {
    sim: Sim = .{},
    plan: *Plan,
    c2: [graph.SLOTS]u8, // the re-dressed cover

    fn emit(self: *Distiller, m: Move) void {
        std.debug.assert(self.plan.n < MAX_MOVES);
        self.plan.moves[self.plan.n] = m;
        self.plan.n += 1;
    }

    /// splitOff with the move emitted.
    fn split(self: *Distiller, si: u8, pos: u8) u8 {
        const pre = Snap.of(self.sim.stack(si));
        const ni = self.sim.splitOff(si, pos);
        self.emit(.{
            .verb = .split,
            .card = self.sim.buf[ni][0],
            .src = pre,
            .dst = .{},
            .result = Snap.of(self.sim.stack(si)),
            .aux = Snap.of(self.sim.stack(ni)),
            .complete = false,
        });
        return ni;
    }

    /// Cut the block starting at first_slot, blen cards, out into its
    /// own stack (splitting as needed) and return its stack index.
    fn isolate(self: *Distiller, first_slot: u8, blen: u8) u8 {
        var si = self.sim.loc_stack[first_slot];
        if (self.sim.loc_pos[first_slot] > 0) {
            si = self.split(si, self.sim.loc_pos[first_slot]);
        }
        if (self.sim.len[si] > blen) {
            _ = self.split(si, blen);
        }
        return si;
    }

    /// Move one card to the destination stack (or to the table when
    /// dst is null), emitting the verb its source classifies: whole
    /// single stack → push, set stack → steal, run stack → peel (after
    /// a split if the card is mid-stack). Returns the card's stack.
    fn extractOne(self: *Distiller, slot: u8, dst: ?u8, left: bool) u8 {
        var si = self.sim.loc_stack[slot];
        if (self.sim.len[si] == 1) {
            const di = dst orelse return si; // already loose: no move
            const pre = Snap.of(self.sim.stack(di));
            self.sim.len[si] = 0;
            self.sim.appendCard(di, slot, left);
            self.emit(.{
                .verb = .push,
                .card = slot,
                .src = .{},
                .dst = pre,
                .result = Snap.of(self.sim.stack(di)),
                .aux = .{},
                .complete = isMeld(self.sim.stack(di)),
            });
            return di;
        }
        var verb: Verb = .peel;
        if (self.sim.isSet(si)) {
            verb = .steal;
        } else {
            // A mid-run card first splits its stack so it sits at an
            // end; the peel reads from the post-split remnant.
            const pos = self.sim.loc_pos[slot];
            if (pos != 0 and pos != self.sim.len[si] - 1) {
                si = self.split(si, pos);
            }
        }
        const pre_src = Snap.of(self.sim.stack(si));
        self.sim.removeAt(si, self.sim.loc_pos[slot]);
        if (dst) |di| {
            const pre_dst = Snap.of(self.sim.stack(di));
            self.sim.appendCard(di, slot, left);
            self.emit(.{
                .verb = verb,
                .card = slot,
                .src = pre_src,
                .dst = pre_dst,
                .result = Snap.of(self.sim.stack(di)),
                .aux = .{},
                .complete = isMeld(self.sim.stack(di)),
            });
            return di;
        }
        const ni = self.sim.addStack(&[1]u8{slot});
        self.emit(.{
            .verb = verb,
            .card = slot,
            .src = pre_src,
            .dst = .{},
            .result = .{},
            .aux = .{},
            .complete = false,
        });
        return ni;
    }

    fn runTarget(self: *Distiller, t: []const u8) void {
        // Maximal blocks contiguous in the CURRENT sim.
        var seg_start: [CAP]u8 = undefined;
        var seg_len: [CAP]u8 = undefined;
        var nseg: u8 = 1;
        seg_start[0] = 0;
        seg_len[0] = 1;
        for (t[1..], 1..) |slot, i| {
            const prev = t[i - 1];
            if (self.sim.loc_stack[slot] == self.sim.loc_stack[prev] and
                self.sim.loc_pos[slot] == self.sim.loc_pos[prev] + 1)
            {
                seg_len[nseg - 1] += 1;
            } else {
                seg_start[nseg] = @intCast(i);
                seg_len[nseg] = 1;
                nseg += 1;
            }
        }
        var base: u8 = 0;
        for (1..nseg) |i| {
            if (seg_len[i] > seg_len[base]) base = @intCast(i);
        }
        // The base block stays on the table; free it of hangers-on.
        var base_si = if (seg_len[base] == 1)
            self.extractOne(t[seg_start[base]], null, false)
        else
            self.isolate(t[seg_start[base]], seg_len[base]);
        // Attach rightward, then leftward.
        var i: u8 = base + 1;
        while (i < nseg) : (i += 1) {
            base_si = self.attachSeg(t, seg_start[i], seg_len[i], base_si, false);
        }
        i = base;
        while (i > 0) : (i -= 1) {
            base_si = self.attachSeg(t, seg_start[i - 1], seg_len[i - 1], base_si, true);
        }
    }

    fn attachSeg(self: *Distiller, t: []const u8, start: u8, slen: u8, dst: u8, left: bool) u8 {
        if (slen == 1) return self.extractOne(t[start], dst, left);
        const bi = self.isolate(t[start], slen);
        const pre_src = Snap.of(self.sim.stack(bi));
        const pre_dst = Snap.of(self.sim.stack(dst));
        self.sim.absorb(dst, bi, left);
        self.emit(.{
            .verb = .merge,
            .card = t[start],
            .src = pre_src,
            .dst = pre_dst,
            .result = Snap.of(self.sim.stack(dst)),
            .aux = .{},
            .complete = isMeld(self.sim.stack(dst)),
        });
        return dst;
    }

    fn setTarget(self: *Distiller, t: []const u8) void {
        // Base: the set-shaped sim stack holding most members.
        var base_si: u8 = Sim.NOWHERE;
        var best: u8 = 1; // an anchor needs at least two members
        for (t) |slot| {
            const si = self.sim.loc_stack[slot];
            if (si == base_si or !self.sim.isSet(si)) continue;
            var ov: u8 = 0;
            for (t) |s2| {
                if (self.sim.loc_stack[s2] == si) ov += 1;
            }
            if (ov > best) {
                best = ov;
                base_si = si;
            }
        }
        if (base_si == Sim.NOWHERE) {
            // Assembled from scratch: the first member anchors loose.
            base_si = self.extractOne(t[0], null, false);
        }
        for (t) |slot| {
            if (self.sim.loc_stack[slot] == base_si) continue;
            base_si = self.extractOne(slot, base_si, false);
        }
    }

    fn verify(self: *const Distiller, chains: []const Snap) bool {
        var matched: [MAX_STACKS]bool = @splat(false);
        for (chains) |t| {
            const si = self.sim.loc_stack[t.cards[0]];
            if (si == Sim.NOWHERE or self.sim.len[si] != t.n or matched[si]) return false;
            matched[si] = true;
            const is_set = t.n >= 2 and
                graph.rankOf(t.cards[0]) == graph.rankOf(t.cards[1]);
            if (is_set) {
                for (t.cards[0..t.n]) |slot| {
                    if (self.sim.loc_stack[slot] != si) return false;
                }
            } else if (!std.mem.eql(u8, self.sim.stack(si), t.cards[0..t.n])) {
                return false;
            }
        }
        return true;
    }
};

/// distill writes the move plan that transforms the arrangement into
/// the cover. The cover's copy labels are re-dressed to hug the
/// player's stacks first; the emitted plan is verified by construction
/// (DistillFailed = a distiller bug, never bad input).
pub fn distill(arr: *const arrangement.Arrangement, cover: *const [graph.SLOTS]u8, plan: *Plan) Error!void {
    plan.n = 0;
    var d = Distiller{ .plan = plan, .c2 = cover.* };

    // Input stacks at slot level, copies first-come per base card —
    // marks in the input line are dressing, here as everywhere.
    var used: [graph.N]u8 = @splat(0);
    var slot_buf: [card.MAX_CARDS]u8 = undefined;
    for (0..arr.n_stacks) |si| {
        const cs = arr.stackCards(si);
        for (cs, 0..) |c, i| {
            const base = @as(u8, c.suit) * 13 + c.rank;
            slot_buf[i] = base + used[base] * 52;
            used[base] += 1;
        }
        _ = d.sim.addStack(slot_buf[0..cs.len]);
    }

    redress(&d);

    // Cover chains, ascending head slot.
    var indeg: [graph.SLOTS]bool = @splat(false);
    for (d.c2) |nx| {
        if (nx != graph.NONE) indeg[nx] = true;
    }
    var chains: [card.MAX_CARDS]Snap = undefined;
    var nchains: usize = 0;
    for (0..graph.SLOTS) |i| {
        const head: u8 = @intCast(i);
        if (d.sim.loc_stack[head] == Sim.NOWHERE or indeg[head]) continue;
        var t: Snap = .{};
        var cur = head;
        while (true) {
            t.cards[t.n] = cur;
            t.n += 1;
            if (d.c2[cur] == graph.NONE) break;
            cur = d.c2[cur];
        }
        chains[nchains] = t;
        nchains += 1;
    }

    for (chains[0..nchains]) |t| {
        const is_set = t.n >= 2 and
            graph.rankOf(t.cards[0]) == graph.rankOf(t.cards[1]);
        if (is_set) d.setTarget(t.cards[0..t.n]) else d.runTarget(t.cards[0..t.n]);
    }

    if (!d.verify(chains[0..nchains])) return error.DistillFailed;
}

// ---------- copy re-dressing ----------

/// Greedy label swaps per doubled base card, maximizing physical
/// agreement between the cover and the input stacks: matching run
/// adjacencies plus input set pairs kept co-resident in one cover set.
fn redress(d: *Distiller) void {
    var doubled: [graph.N]bool = undefined;
    for (0..graph.N) |b| {
        doubled[b] = d.sim.loc_stack[b] != Sim.NOWHERE and
            d.sim.loc_stack[b + 52] != Sim.NOWHERE;
    }
    var pass: u8 = 0;
    while (pass < 8) : (pass += 1) {
        var improved = false;
        for (0..graph.N) |b| {
            if (!doubled[b]) continue;
            const before = agreement(d);
            swapCopies(&d.c2, @intCast(b));
            if (agreement(d) > before) {
                improved = true;
            } else {
                swapCopies(&d.c2, @intCast(b));
            }
        }
        if (!improved) break;
    }
}

fn swapCopies(next: *[graph.SLOTS]u8, b: u8) void {
    const b2 = b + 52;
    std.mem.swap(u8, &next[b], &next[b2]);
    for (next) |*v| {
        if (v.* == b) v.* = b2 else if (v.* == b2) v.* = b;
    }
}

fn agreement(d: *const Distiller) u32 {
    var score: u32 = 0;
    for (0..d.sim.n) |si| {
        const s = d.sim.stack(@intCast(si));
        if (s.len >= 2 and graph.rankOf(s[0]) == graph.rankOf(s[1])) {
            // An input set: score pairs co-resident in one cover set.
            for (s, 0..) |a, i| {
                for (s[i + 1 ..]) |b| {
                    if (coSet(&d.c2, a, b)) score += 1;
                }
            }
            continue;
        }
        for (s[0 .. s.len -| 1], s[1..]) |a, b| {
            if (d.c2[a] == b) score += 1;
        }
    }
    return score;
}

/// Both slots inside one cover set chain (walk the same-rank links).
fn coSet(c2: *const [graph.SLOTS]u8, a: u8, b: u8) bool {
    var cur = a;
    for (0..4) |_| {
        const nx = c2[cur];
        if (nx == graph.NONE or graph.rankOf(nx) != graph.rankOf(cur)) break;
        cur = nx;
        if (cur == b) return true;
    }
    cur = b;
    for (0..4) |_| {
        const nx = c2[cur];
        if (nx == graph.NONE or graph.rankOf(nx) != graph.rankOf(cur)) break;
        cur = nx;
        if (cur == a) return true;
    }
    return false;
}

// ---------- rendering ----------

const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn str(self: *Writer, s: []const u8) void {
        @memcpy(self.buf[self.n..][0..s.len], s);
        self.n += s.len;
    }

    fn slot(self: *Writer, sl: u8) void {
        var cb: [3]u8 = undefined;
        self.str(card.formatCard(.{
            .rank = @intCast(graph.rankOf(sl)),
            .suit = @intCast(graph.suitOf(sl)),
            .deck = @intCast(sl / 52),
        }, &cb));
    }

    fn snap(self: *Writer, s: *const Snap) void {
        self.str("[");
        for (s.cards[0..s.n], 0..) |sl, i| {
            if (i > 0) self.str(" ");
            self.slot(sl);
        }
        self.str("]");
    }
};

/// formatMove renders one plan line, e.g.
/// "steal 8H from [8H 8S 8D'] onto [6D 7C'] -> [6D 7C' 8H] [COMPLETE]".
pub fn formatMove(m: *const Move, buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };
    w.str(@tagName(m.verb));
    w.str(" ");
    if (m.verb == .split) {
        w.snap(&m.src);
        w.str(" -> ");
        w.snap(&m.result);
        w.str(" + ");
        w.snap(&m.aux);
        return buf[0..w.n];
    }
    if (m.verb == .merge) {
        w.snap(&m.src);
    } else {
        w.slot(m.card);
        if (m.verb != .push) {
            w.str(" from ");
            w.snap(&m.src);
        }
    }
    if (m.dst.n > 0) {
        w.str(" onto ");
        w.snap(&m.dst);
        w.str(" -> ");
        w.snap(&m.result);
        if (m.complete) w.str(" [COMPLETE]");
    }
    return buf[0..w.n];
}

/// formatPlan renders the whole plan, one move per line.
pub fn formatPlan(plan: *const Plan, buf: []u8) []const u8 {
    var n: usize = 0;
    for (plan.moves[0..plan.n], 0..) |*m, i| {
        if (i > 0) {
            buf[n] = '\n';
            n += 1;
        }
        n += formatMove(m, buf[n..]).len;
    }
    return buf[0..n];
}

// ---------- tests (native: ops/check_solver) ----------

/// A next-map from a cover line — melds in the arrangement notation.
/// Unlike everywhere else, deck marks are HONORED here (collision
/// takes the twin), so tests can build label-crossed covers and prove
/// the re-dressing works.
fn coverNext(line: []const u8) ![graph.SLOTS]u8 {
    const arr = try arrangement.parse(line);
    var next: [graph.SLOTS]u8 = @splat(graph.NONE);
    var taken: [graph.SLOTS]bool = @splat(false);
    var slots: [card.MAX_CARDS]u8 = undefined;
    for (0..arr.n_stacks) |si| {
        const cs = arr.stackCards(si);
        for (cs, 0..) |c, i| {
            const base = @as(u8, c.suit) * 13 + c.rank;
            var slot = base + @as(u8, c.deck) * 52;
            if (taken[slot]) slot = (slot + 52) % graph.SLOTS;
            taken[slot] = true;
            slots[i] = slot;
        }
        for (0..cs.len -| 1) |i| next[slots[i]] = slots[i + 1];
    }
    return next;
}

fn expectPlan(arr_line: []const u8, cover_line: []const u8, expected: []const u8) !void {
    const arr = try arrangement.parse(arr_line);
    const cover = try coverNext(cover_line);
    var plan: Plan = undefined;
    try distill(&arr, &cover, &plan);
    var buf: [8192]u8 = undefined;
    try std.testing.expectEqualStrings(expected, formatPlan(&plan, &buf));
}

test "an untouched board distills to no moves" {
    try expectPlan(
        "3H>4H>5H KH=KC=KS",
        "3H>4H>5H KH=KC=KS",
        "",
    );
}

test "re-dressing: crossed copy labels are no diff at all" {
    // The cover interleaves the two heart runs' labels; physically the
    // player's stacks already ARE the cover.
    try expectPlan(
        "3H>4H>5H 3H'>4H'>5H'",
        "3H>4H'>5H 3H'>4H>5H'",
        "",
    );
}

test "merge: a surviving pair joins a partial run" {
    try expectPlan(
        "3H>4H 5H>6H>7H",
        "3H>4H>5H>6H>7H",
        "merge [3H 4H] onto [5H 6H 7H] -> [3H 4H 5H 6H 7H] [COMPLETE]",
    );
}

test "steal: a set member finishes a run" {
    try expectPlan(
        "KH=KC=KS=KD JS>QS",
        "KH=KC=KD JS>QS>KS",
        "steal KS from [KH KC KS KD] onto [JS QS] -> [JS QS KS] [COMPLETE]",
    );
}

test "split: one break, both halves stand" {
    try expectPlan(
        "3H>4H>5H>6H>7H>8H",
        "3H>4H>5H 6H>7H>8H",
        "split [3H 4H 5H 6H 7H 8H] -> [3H 4H 5H] + [6H 7H 8H]",
    );
}

test "a set assembles: a peel anchors it, pushes finish it" {
    try expectPlan(
        "AH>2S>3H>4S AC AS",
        "2S>3H>4S AH=AC=AS",
        "peel AH from [AH 2S 3H 4S]\n" ++
            "push AC onto [AH] -> [AH AC]\n" ++
            "push AS onto [AH AC] -> [AH AC AS] [COMPLETE]",
    );
}

test "mid-run extraction reads as split then peel" {
    // 4H leaves the middle of the heart run for the four set; the
    // split frees it, the peel reads from the remnant, and the freed
    // 3H finds its own rb home.
    try expectPlan(
        "3H>4H>5H>6H>7H 4D=4C AD 2S",
        "4H=4D=4C AD>2S>3H 5H>6H>7H",
        "split [3H 4H 5H 6H 7H] -> [3H] + [4H 5H 6H 7H]\n" ++
            "peel 4H from [4H 5H 6H 7H] onto [4D 4C] -> [4D 4C 4H] [COMPLETE]\n" ++
            "push 2S onto [AD] -> [AD 2S]\n" ++
            "push 3H onto [AD 2S] -> [AD 2S 3H] [COMPLETE]",
    );
}
