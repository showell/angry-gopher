//! hint — the game-hint orchestrator: board arrangement + hand in,
//! human move plan out.
//!
//! The objective is BEGINNER-FIRST (Steve, 2026-07-23): prefer the
//! simplest play — one card from the hand — over compound plays. The
//! scan tries hand subsets in ASCENDING size (singles in hand order,
//! then pairs, then triples), each candidate probed with a small
//! improve budget; among playable candidates of the smallest workable
//! size, the one whose probe cover kept the most player edges wins,
//! and only the winner gets the full min-break budget. One card almost
//! never blocks playing the rest later, and each Hint click advises
//! the next simplest step — the same click-per-move rhythm the puzzle
//! hints settled into.
//!
//! With nothing playable the hint falls back honestly: a dirty board
//! gets its consolidation plan, a clean board says "draw", a board
//! whose multiset can't cover says so (that means UNDO — a real state
//! players reach), and a solver give-up stays a give-up.

const std = @import("std");
const card = @import("card.zig");
const arrangement = @import("arrangement.zig");
const solver = @import("solver.zig");
const moves = @import("moves.zig");

pub const Kind = enum {
    play, // plan places hand card(s); plan is non-empty
    clean_board, // nothing playable, board dirty: consolidation plan
    no_play, // nothing playable, board already clean: draw
    futile_board, // the board multiset has NO cover: undo territory
    unknown, // the solver gave up; no verdict, honestly labeled
};

pub const Result = struct {
    kind: Kind,
    plan: moves.Plan,
};

// Probe budgets for the candidate scans, strict-first: a playable
// extension usually keeps every edge (perfect score ends the improve
// enumeration immediately), so the budget only pays on candidates
// that force breaks. Raise only on evidence.
const SINGLE_SCAN_STEPS = 20_000;
const PAIR_SCAN_STEPS = 5_000;
const TRIPLE_SCAN_STEPS = 2_000;

/// `preferred`: the objective card of the PREVIOUS hint (the glue
/// remembers it across clicks). A hint should walk one line until it's
/// done or clearly beaten — session 8's ace flip-flop is the lesson —
/// so a still-playable preferred single stays the objective unless
/// some alternative is MORE THAN ONE MOVE cheaper. A switch therefore
/// means the player's own work made the new line decisively better.
/// `just_played`: the previous objective card left the hand since the
/// last hint (the glue detects the count drop and sends a one-shot
/// signal). Steve's game-10 wisdom applies EXACTLY then: with the
/// objective landed and the board dirty, the loose aces find their
/// home before more cards come down — cleaning competes with new
/// plays and wins when strictly shorter (every play plan contains the
/// same cleanup plus its place, so this is usually decisive). On any
/// other fresh hint plays lead as usual — a broader clean bias was
/// tried and it told the player to tear down work-in-progress.
pub fn gameHint(arr: *const arrangement.Arrangement, hand: []const card.Card, preferred: ?card.Card, just_played: bool) (card.Error || moves.Error)!Result {
    var pref_idx: ?u8 = null;
    if (preferred) |p| {
        for (hand, 0..) |c, i| {
            if (c.rank == p.rank and c.suit == p.suit) {
                pref_idx = @intCast(i);
                break;
            }
        }
    }
    // The consolidation candidate always computes (a clean board costs
    // nothing: empty plan, no candidate). When it may WIN is the
    // Steve-calibrated part — see consolWins.
    var consolidation: ?Result = null;
    var consol_homing = false; // breaks no player edge: pure homing
    switch (try solver.solveArrangement(arr)) {
        .solved => |sol| {
            var res = Result{ .kind = .clean_board, .plan = undefined };
            try moves.distill(arr, &sol.next, arr.n_stacks, &res.plan);
            if (res.plan.n > 0) {
                consolidation = res;
                const rep = arrangement.reportKept(arr, &sol.next);
                consol_homing = rep.kept_edges == rep.total_edges;
            }
        },
        else => {},
    }
    inline for (.{ 1, 2, 3 }, .{ SINGLE_SCAN_STEPS, PAIR_SCAN_STEPS, TRIPLE_SCAN_STEPS }) |k, budget| {
        const scan = try scanSize(arr, hand, k, budget, if (k == 1) pref_idx else null);
        const winner: ?Cand = if (scan.best) |best| blk: {
            if (scan.pref) |pref| {
                if (pref.len <= best.len + 1) break :blk pref;
            }
            break :blk best;
        } else null;
        if (winner) |w| {
            var a = arr.*;
            for (w.idx[0..k]) |hi| appendSingle(&a, hand[hi]);
            // The winner gets the full min-break budget. The probe
            // proved a cover exists inside a smaller budget, and the
            // enumeration order is deterministic, so this is .solved.
            const sol = (try solver.solveArrangement(&a)).solved;
            var res = Result{ .kind = .play, .plan = undefined };
            try moves.distill(&a, &sol.next, arr.n_stacks, &res.plan);
            // Fair fight: both plans carry the full budget now.
            if (consolidation) |c| {
                if (consolWins(&c, consol_homing, just_played, res.plan.n)) return c;
            }
            return res;
        }
    }
    if (consolidation) |c| return c;
    // Nothing playable: the board speaks for itself.
    switch (try solver.solveArrangement(arr)) {
        .solved => |sol| {
            var res = Result{ .kind = .clean_board, .plan = undefined };
            try moves.distill(arr, &sol.next, arr.n_stacks, &res.plan);
            if (res.plan.n == 0) res.kind = .no_play;
            return res;
        },
        .futile => return .{ .kind = .futile_board, .plan = .{} },
        .unknown => return .{ .kind = .unknown, .plan = .{} },
    }
}

/// When does cleaning beat playing? Steve's turns, distilled
/// (games 10 and 11):
///   - a hand card just landed (`just_played`, any card — the glue
///     diffs the hand against its last-hint snapshot, so the player's
///     own placements count and an undo disarms the signal): cleaning
///     leads, ties included — "we shouldn't even be considering moves
///     from the hand at that point". Only a play that is itself the
///     faster cleanup (strictly shorter) overrides.
///   - otherwise: cleaning competes only when it is PURE HOMING —
///     it breaks no player edge, it only gives loose cards a home
///     (the 3♥ push; never the tear-down-your-half-built-run kind,
///     which is what sank the first draft of this rule) — and is
///     strictly shorter than the play. This can override a standing
///     objective: tidy-first, then the objective resumes.
fn consolWins(c: *const Result, homing: bool, just_played: bool, play_len: usize) bool {
    if (just_played) return c.plan.n <= play_len;
    return homing and c.plan.n < play_len;
}

const Cand = struct { idx: [3]u8, len: usize, kept: i32 };

/// scanSize probes all size-k hand subsets under the probe budget.
/// The best candidate ranks by SHORTEST plan first (the beginner's
/// simplest next thing — and an in-progress objective gets strictly
/// shorter with each executed move, which is what keeps hints from
/// flip-flopping), then most kept edges, then hand order. Probe
/// give-ups count as not-playable — the budget IS the honesty line.
fn scanSize(
    arr: *const arrangement.Arrangement,
    hand: []const card.Card,
    comptime k: usize,
    budget: u64,
    pref_idx: ?u8,
) (card.Error || moves.Error)!struct { best: ?Cand, pref: ?Cand } {
    var best: ?Cand = null;
    var pref: ?Cand = null;
    if (hand.len < k) return .{ .best = null, .pref = null };
    var idx: [3]u8 = .{ 0, 1, 2 };
    while (true) {
        var a = arr.*;
        for (idx[0..k]) |hi| appendSingle(&a, hand[hi]);
        switch (try solver.solveArrangementBudgeted(&a, budget)) {
            .solved => |sol| {
                var plan: moves.Plan = undefined;
                try moves.distill(&a, &sol.next, arr.n_stacks, &plan);
                const cand = Cand{
                    .idx = idx,
                    .len = plan.n,
                    .kept = arrangement.reportKept(&a, &sol.next).kept_edges,
                };
                if (best == null or cand.len < best.?.len or
                    (cand.len == best.?.len and cand.kept > best.?.kept))
                {
                    best = cand;
                }
                if (pref_idx) |pi| {
                    if (k == 1 and idx[0] == pi) pref = cand;
                }
            },
            else => {},
        }
        // Next k-combination of hand indices, lexicographic.
        var j: usize = k;
        while (j > 0) : (j -= 1) {
            if (idx[j - 1] < hand.len - (k - j) - 1) {
                idx[j - 1] += 1;
                for (j..k) |m| idx[m] = idx[m - 1] + 1;
                break;
            }
        }
        if (j == 0) break;
    }
    return .{ .best = best, .pref = pref };
}

fn appendSingle(a: *arrangement.Arrangement, c: card.Card) void {
    const n = a.start[a.n_stacks];
    a.cards[n] = c;
    a.n_stacks += 1;
    a.start[a.n_stacks] = n + 1;
}

// ---------- tests (native: ops/check_solver) ----------

fn hintFor(board_line: []const u8, hand_line: []const u8) !Result {
    return hintForPref(board_line, hand_line, null);
}

fn hintForPref(board_line: []const u8, hand_line: []const u8, pref: ?[]const u8) !Result {
    const arr = try arrangement.parse(board_line);
    var hb: [card.MAX_CARDS]card.Card = undefined;
    const hand = try card.parseBoard(hand_line, &hb);
    const p: ?card.Card = if (pref) |t| try card.parseCard(t) else null;
    return gameHint(&arr, hand, p, false);
}

fn hintJustPlayed(board_line: []const u8, hand_line: []const u8) !Result {
    const arr = try arrangement.parse(board_line);
    var hb: [card.MAX_CARDS]card.Card = undefined;
    const hand = try card.parseBoard(hand_line, &hb);
    return gameHint(&arr, hand, null, true);
}

// The session-8 ace flip-flop, pinned from the real game (uid 16,
// game 8, 2026-07-23): three loose aces vs the freshly-built
// A♦>2♣>3♦>4♣ toggled the best objective between the two hand aces,
// and the hint flapped with it. States 3 and 4 are the replayed
// arrangements; the hand is Steve's actual hand.
const G8_HAND = "AH' 4H' 7H' 4S' 9S' JS' AD' 2D' 4D' 6D 7C' 9C JC' KC KC'";
const G8_STATE3 = "KS>AS>2S>3S TD>JD>QD>KD 2H>3H>4H 7S=7D=7C AC AD AH " ++
    "2C>3D>4C 5H>6S>7H";
const G8_STATE4 = "KS>AS>2S>3S TD>JD>QD>KD 2H>3H>4H 7S=7D=7C AC AH " ++
    "AD>2C>3D>4C 5H>6S>7H";

test "game 8: pure homing tidies first; destructive cleanup never leads fresh" {
    var buf: [4096]u8 = undefined;
    // Three loose aces are pure homing (no player edge breaks):
    // 2 moves beat the 3-move play, tidy-first (game 11's vote).
    const s3 = try hintFor(G8_STATE3, G8_HAND);
    try std.testing.expectEqual(Kind.clean_board, s3.kind);
    try std.testing.expect(std.mem.indexOf(u8, planText(&s3, &buf), "push AD onto [AH]") != null);
    // With Aâ¦ committed to the club run, cleaning would mean tearing
    // it back out — destructive, so it never leads a fresh hint.
    const s4 = try hintFor(G8_STATE4, G8_HAND);
    try std.testing.expectEqual(Kind.play, s4.kind);
    try std.testing.expect(std.mem.indexOf(u8, planText(&s4, &buf), "place AD'") != null);
}

test "game 11: after placing 3S, the 3H loner outranks the next hand card" {
    // Steve's kitchen-table turn, replayed: he split [2H 3H 4H] to
    // place 3S' into a new run; the 3H loner that maneuver created
    // must be homed before the hint proposes AC' — even though AC'
    // stands as the objective. Pure homing, 1 move vs 2.
    const board = "TD>JD>QD>KD 7S=7D=7C AC=AD=AH 4S'>5H>6S AS>2S>3S " ++
        "6C>7H>8S' 9C'>TD'>JC>QH QH'>KS>AD'>2C 2S'>3D>4C 3H 2H>3S'>4H";
    const hand = "4H' JH JH' AC'";
    const res = try hintForPref(board, hand, "AC'");
    try std.testing.expectEqual(Kind.clean_board, res.kind);
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "push 3H onto [4S 5H 6S] -> [3H 4S 5H 6S] [COMPLETE]",
        planText(&res, &buf),
    );
    // One state earlier (4H still loose too): the 2-move homing beats
    // the 3-move play.
    const board47 = "TD>JD>QD>KD 7S=7D=7C AC=AD=AH 4S'>5H>6S AS>2S>3S " ++
        "6C>7H>8S' 9C'>TD'>JC>QH QH'>KS>AD'>2C 2S'>3D>4C 2H>3S' 3H 4H";
    const res47 = try hintFor(board47, hand);
    try std.testing.expectEqual(Kind.clean_board, res47.kind);
    const t47 = planText(&res47, &buf);
    try std.testing.expect(std.mem.indexOf(u8, t47, "push 4H onto [2H 3S']") != null);
    try std.testing.expect(std.mem.indexOf(u8, t47, "push 3H") != null);
}

test "game 10: after the objective lands, the aces find their home" {
    // The replayed state after action 21 (3♣ just placed — the
    // standing objective is gone from the hand): [A♦ A♥] floats, and
    // the 2-move cleanup beats every new play (each of which contains
    // the same cleanup plus its place).
    const board = "KS>AS>2S>3S' 2S'>3S>4S 2H>3H>4H 7S=7D=7C AD=AH " ++
        "AC>2C>3C 3D>4C>5H>6S 6S'>7H>8C 8D'>9D>TD>JD' JD>QD>KD";
    const hand = "2H' 8H KH 7S' KS' 3C'";
    const res = try hintJustPlayed(board, hand);
    try std.testing.expectEqual(Kind.clean_board, res.kind);
    // Without the just-played signal the same state hints a play.
    const fresh = try hintFor(board, hand);
    try std.testing.expectEqual(Kind.play, fresh.kind);
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "steal AH from [AD AH] onto [2H 3H 4H] -> [AH 2H 3H 4H] [COMPLETE]\n" ++
            "push AD onto [JD' QD KD] -> [JD' QD KD AD] [COMPLETE]",
        planText(&res, &buf),
    );
}

test "game 9: extending a big run is one move, never a split" {
    // The replayed state where the hint said to break Q-K-A-2-3 of
    // spades before placing J♠. With cover coalescing, the hint is
    // the single obvious extension.
    const board = "QS'>KS>AS>2S>3S TD>JD>QD>KD 2H>3H>4H 7S=7D=7C " ++
        "AC=AD=AH 2C>3D>4C>5D' 3D'>4S>5H 6S>7H>8C";
    const hand = "2H' 3H' 6H JH' KH 9S' TS' JS TD' QC'";
    const res = try hintFor(board, hand);
    try std.testing.expectEqual(Kind.play, res.kind);
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "place JS onto [QS KS AS 2S 3S] -> [JS QS KS AS 2S 3S] [COMPLETE]",
        planText(&res, &buf),
    );
}

test "game 8: a standing objective survives the ace toggle" {
    var buf: [4096]u8 = undefined;
    // Tidy-first outranks even a standing objective when the tidy is
    // pure homing and strictly shorter: at the loose-Aâ¦ state the
    // 2-move ace rebuild leads; the AD' objective resumes after.
    const stick3 = try hintForPref(G8_STATE3, G8_HAND, "AD'");
    try std.testing.expectEqual(Kind.clean_board, stick3.kind);
    try std.testing.expect(std.mem.indexOf(u8, planText(&stick3, &buf), "push AD onto [AH]") != null);
    // And with AH' standing at the committed-Aâ¦ state, its 3-move
    // line (a peel, not a split â Aâ¦ rides the run's end) is within
    // one of AD's 2 â stick again. Either way, no flap.
    const stick4 = try hintForPref(G8_STATE4, G8_HAND, "AH'");
    try std.testing.expect(std.mem.indexOf(u8, planText(&stick4, &buf), "place AH'") != null);
    // A vanished or unplayable preferred card falls back to fresh.
    const fresh = try hintForPref(G8_STATE4, G8_HAND, "9C");
    try std.testing.expect(std.mem.indexOf(u8, planText(&fresh, &buf), "place AD'") != null);
}

fn planText(res: *const Result, buf: []u8) []const u8 {
    return moves.formatPlan(&res.plan, buf);
}

test "one card from hand beats the compound play" {
    // 8H extends the heart run with one move; the three kings could
    // come down as a fresh set — the hint prefers the single.
    const res = try hintFor("5H>6H>7H", "KC 8H KD KS");
    try std.testing.expectEqual(Kind.play, res.kind);
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "place 8H onto [5H 6H 7H] -> [5H 6H 7H 8H] [COMPLETE]",
        planText(&res, &buf),
    );
}

test "a pair from hand plays when no single can" {
    // Neither 7H nor 7D alone can live with the lone 7C; together
    // they make the set. The place lines lead the plan.
    const res = try hintFor("7C 3S>4S>5S", "7H 7D");
    try std.testing.expectEqual(Kind.play, res.kind);
    var buf: [1024]u8 = undefined;
    const text = planText(&res, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "place 7H"));
    try std.testing.expect(std.mem.indexOf(u8, text, "place 7D") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[COMPLETE]") != null);
}

test "nothing playable, dirty board: the hint consolidates" {
    const res = try hintFor("3H>4H 5H", "KC");
    try std.testing.expectEqual(Kind.clean_board, res.kind);
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "push 5H onto [3H 4H] -> [3H 4H 5H] [COMPLETE]",
        planText(&res, &buf),
    );
}

test "nothing playable, clean board: draw" {
    const res = try hintFor("3H>4H>5H", "KC");
    try std.testing.expectEqual(Kind.no_play, res.kind);
    try std.testing.expectEqual(@as(usize, 0), res.plan.n);
}

test "an uncoverable board says so — that means undo" {
    const res = try hintFor("3H>4H 5H KC", "");
    try std.testing.expectEqual(Kind.futile_board, res.kind);
}

test "equally clean singles tie by hand order" {
    // TH joins the ten set and 8H extends the run — both keep every
    // edge, so the earlier hand card wins, deterministically.
    const res = try hintFor("5H>6H>7H TS=TC=TD", "TH 8H");
    try std.testing.expectEqual(Kind.play, res.kind);
    var buf: [2048]u8 = undefined;
    const text = planText(&res, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "place TH"));
}
