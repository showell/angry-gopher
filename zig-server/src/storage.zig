//! storage: filesystem-backed puzzle-session storage. A dumb id-keyed file
//! store; meta is last-write-wins, actions.dsl is append-only.
//!
//! It also keeps the full game's sessions (the `lynrummy-elm` namespace, below).
//!
//! data_root is the live game-data dir. The zig server runs
//! from zig-server/, so the repo-relative path carries the `..`; a host points
//! it at {data_dir}/lynrummy (roots.zig).
//!
//! On-disk shape under {data_root}/{userID}/puzzle/sessions/<id>/:
//!   meta                       — created_at + catalog snapshot (DSL)
//!   puzzle_<idx>/actions.dsl   — one `<seq>) <action>` line per append
//!
//! **APPENDS ARE SERIALIZED BY THE HOST**: one handler runs at a time (its
//! turn, zig-metal-unikernel HOST.md), so this file keeps no lock. store.append stats the file's size
//! and then writes at it (the std.Io file API exposes no O_APPEND), so two
//! appends to one file at once could both write at the old end, one over the
//! other. This file once said that could not happen, because one request
//! allocates a session; but the append routes take any session the player
//! owns, so one player in two tabs, or a client retrying, appends to one file
//! twice at once. Measured: 1,814 of 2,000 lines landed from 8 concurrent
//! writers (zig-metal-unikernel's GROWTH-game-store.md).
//!
//! **EVERY GAME WRITE IS ADMITTED BY WHAT IT WRITES** (metal-vmm QUEUE
//! 157(b)): a handler writes through `makeGameSession`, `appendGameLine` or
//! `appendPuzzleMove`, each of which builds the bytes it will write, asks
//! `game_limits.admit` for exactly their length, and writes them. The writers
//! under them are not `pub`: a caller once counted the bytes by hand, "as
//! storage writes it", and the annotation it counted was not the compacted
//! one storage wrote.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const counter = @import("webbox").counter;
const store = @import("webbox").store;
const game_limits = @import("game_limits.zig");

/// data_root is the live game-data dir (repo-relative from zig-server/, hence the `..`).
pub var data_root: []const u8 = "../games/lynrummy/data";

fn join(alloc: Alloc, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(alloc, parts);
}

/// userRoot is {data_root}/{userID} — a player's whole subtree.
fn userRoot(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id });
}

/// userDataDir is the public form of userRoot — a player's whole game-data
/// subtree ({data_root}/{userID}), which the admin overview walks for stats.
pub fn userDataDir(alloc: Alloc, user_id: []const u8) ![]u8 {
    return userRoot(alloc, user_id);
}

/// deleteUserData removes a player's entire game-data subtree.
/// Refuses an empty id. Absent is OK; a removal that failed is an error, and
/// the caller's to answer (metal-vmm QUEUE 129: both callers said "deleted").
pub fn deleteUserData(io: Io, alloc: Alloc, user_id: []const u8) !void {
    if (std.mem.trim(u8, user_id, " \t\r\n").len == 0) return error.EmptyUserID;
    const root = try userRoot(alloc, user_id);
    // What they held is forgotten whatever the removal did: the next write
    // measures the folder afresh.
    defer game_limits.forget(user_id);
    try store.removeTree(io, alloc, root);
}

fn puzzleRoot(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "puzzle" });
}

/// lynrummyElmRoot is the full-game namespace for a player.
fn lynrummyElmRoot(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "lynrummy-elm" });
}

fn nextPuzzleIDPath(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "next-puzzle-id.txt" });
}

fn nextSessionIDPath(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "next-session-id.txt" });
}

/// puzzleSessionDir is {puzzleRoot}/sessions/<id>.
pub fn puzzleSessionDir(alloc: Alloc, user_id: []const u8, session_id: i64) ![]u8 {
    const root = try puzzleRoot(alloc, user_id);
    const id_str = try std.fmt.allocPrint(alloc, "{d}", .{session_id});
    return join(alloc, &.{ root, "sessions", id_str });
}

/// allocatePuzzleSessionID returns the next sequential puzzle session id (1-based)
/// for a player, persisted in their next-puzzle-id.txt.
pub fn allocatePuzzleSessionID(io: Io, alloc: Alloc, user_id: []const u8) !i64 {
    return counter.next(io, alloc, try nextPuzzleIDPath(alloc, user_id));
}

/// The puzzle session id a page offers: the one its first move will make.
/// Nothing is written (zig-metal-unikernel QUEUE item 52: no write on a GET).
pub fn nextPuzzleSessionID(io: Io, alloc: Alloc, user_id: []const u8) !i64 {
    return counter.peek(io, alloc, try nextPuzzleIDPath(alloc, user_id));
}

/// Makes puzzle session `session_id`, with `meta`, if it is the one a page
/// offered (`nextPuzzleSessionID`) and is not there yet; answers whether the
/// session is there afterwards. An id never offered makes nothing. "Is it
/// there, and is it the one offered" and the making of it are one step
/// because one handler runs at a time (no lock: HOST.md's turn), so two
/// first moves make one session, not two.
fn ensurePuzzleSession(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, meta: []const u8) !bool {
    if (try puzzleSessionExists(io, alloc, user_id, session_id)) return true;
    if (session_id != try nextPuzzleSessionID(io, alloc, user_id)) return false;
    const got = try allocatePuzzleSessionID(io, alloc, user_id);
    std.debug.assert(got == session_id); // one handler at a time
    try writePuzzleSessionFile(io, alloc, user_id, session_id, "meta", meta);
    return true;
}

/// writePuzzleSessionFile writes body to <session-dir>/<rel>, creating parent
/// dirs. Last-write-wins (used for meta).
fn writePuzzleSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try store.write(io, alloc, full, body, .{});
}

/// puzzleSessionExists reports whether a session directory is on disk.
pub fn puzzleSessionExists(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !bool {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const st = (try store.statOrNull(io, alloc, dir)) orelse return false;
    return st.kind == .directory;
}

// ── game writes, admitted by what they write (metal-vmm QUEUE 157(b)) ──────

/// Who a game write is charged to: the player and the address it came from
/// (`game_limits.admit`).
pub const Payer = struct { id: []const u8, client: ?[]const u8 };

/// The two kinds of line a session takes: a DSL action (trailing newlines
/// trimmed, one added) and a JSON annotation (compacted, one newline added).
pub const LineKind = enum { actions, annotations };

/// The line `body` lands as.
fn lineOf(alloc: Alloc, kind: LineKind, body: []const u8) ![]u8 {
    const text = switch (kind) {
        .actions => std.mem.trimEnd(u8, body, "\n"),
        .annotations => try compactJSON(alloc, body),
    };
    return std.fmt.allocPrint(alloc, "{s}\n", .{text});
}

/// A new full-game session holding `meta`, its id; or why not.
pub const Made = union(enum) { refused: game_limits.Refusal, id: i64 };

pub fn makeGameSession(io: Io, alloc: Alloc, payer: Payer, meta: []const u8) !Made {
    if (try game_limits.admit(io, alloc, payer.id, payer.client, true, meta.len)) |r| return .{ .refused = r };
    const id = try allocateSessionID(io, alloc, payer.id);
    try writeSessionFile(io, alloc, payer.id, id, "meta", meta);
    return .{ .id = id };
}

/// One line appended to full-game session `session_id`, or why not.
pub fn appendGameLine(io: Io, alloc: Alloc, payer: Payer, session_id: i64, kind: LineKind, body: []const u8) !?game_limits.Refusal {
    const line = try lineOf(alloc, kind, body);
    if (try game_limits.admit(io, alloc, payer.id, payer.client, false, line.len)) |r| return r;
    const rel = switch (kind) {
        .actions => "actions.dsl",
        .annotations => "annotations.jsonl",
    };
    try appendLine(io, alloc, try join(alloc, &.{ try sessionDir(alloc, payer.id, session_id), rel }), line);
    return null;
}

/// A puzzle move's outcome.
pub const Moved = union(enum) { done, refused: game_limits.Refusal, not_offered };

/// One move appended to puzzle `puzzle_idx` of puzzle session `session_id`.
/// `new_meta` is the meta of a session the move makes (THE FIRST MOVE MAKES
/// THE SESSION, puzzles.zig): admitted with the move as one write, and made
/// only if it is the session the page offered; null for a session there.
pub fn appendPuzzleMove(io: Io, alloc: Alloc, payer: Payer, session_id: i64, puzzle_idx: i32, body: []const u8, new_meta: ?[]const u8) !Moved {
    const line = try lineOf(alloc, .actions, body);
    if (new_meta) |meta| {
        if (try game_limits.admit(io, alloc, payer.id, payer.client, true, meta.len + line.len)) |r| return .{ .refused = r };
        if (!try ensurePuzzleSession(io, alloc, payer.id, session_id, meta)) {
            try game_limits.giveBack(io, alloc, payer.id, payer.client, true, meta.len + line.len);
            return .not_offered;
        }
    } else if (try game_limits.admit(io, alloc, payer.id, payer.client, false, line.len)) |r| return .{ .refused = r };
    const rel = try std.fmt.allocPrint(alloc, "puzzle_{d}/actions.dsl", .{puzzle_idx});
    try appendLine(io, alloc, try join(alloc, &.{ try puzzleSessionDir(alloc, payer.id, session_id), rel }), line);
    return .done;
}

/// appendLine appends `line`, already whole with its newline, to `path`,
/// creating parent dirs: one positional write at the current end, inside
/// one handler's turn (see the atomicity note at the top of this file).
fn appendLine(io: Io, alloc: Alloc, path: []const u8, line: []const u8) !void {
    _ = try store.append(io, alloc, path, line);
}

// ── full-game (lynrummy-elm) namespace ──────────────────────────────────────
//
// The full game adds READ-BACK to the puzzle's write-only surface: resume reads
// meta+actions, the list pages read every session dir. Same dumb id-keyed store,
// new namespace ({id}/lynrummy-elm/sessions/<id>/), and a few read helpers.

/// allocateSessionID returns the next sequential full-game session id (1-based)
/// for a player, persisted in their next-session-id.txt.
pub fn allocateSessionID(io: Io, alloc: Alloc, user_id: []const u8) !i64 {
    return counter.next(io, alloc, try nextSessionIDPath(alloc, user_id));
}

/// sessionDir is {lynrummyElmRoot}/sessions/<id>.
pub fn sessionDir(alloc: Alloc, user_id: []const u8, session_id: i64) ![]u8 {
    const root = try lynrummyElmRoot(alloc, user_id);
    const id_str = try std.fmt.allocPrint(alloc, "{d}", .{session_id});
    return join(alloc, &.{ root, "sessions", id_str });
}

/// writeSessionFile writes body to <session-dir>/<rel>, creating parent dirs.
/// Last-write-wins (used for meta).
fn writeSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try store.write(io, alloc, full, body, .{});
}

/// readSessionFile reads <session-dir>/<rel>, or null when the file (or session)
/// is missing. Any other failure is an error: a game resumed from an empty log
/// it could not read would be played on from the start and appended to.
pub fn readSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8) !?[]u8 {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    return store.read(io, alloc, full, .unlimited) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => null,
        else => e,
    };
}

/// sessionExists reports whether a full-game session directory is on disk.
pub fn sessionExists(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !bool {
    const dir = try sessionDir(alloc, user_id, session_id);
    const st = (try store.statOrNull(io, alloc, dir)) orelse return false;
    return st.kind == .directory;
}

/// listSessionIDs returns every full-game session-id directory for a player,
/// sorted ascending.
pub fn listSessionIDs(io: Io, alloc: Alloc, user_id: []const u8) ![]i64 {
    const root = try lynrummyElmRoot(alloc, user_id);
    const sessions = try join(alloc, &.{ root, "sessions" });

    const entries = try store.list(io, alloc, sessions);

    var ids: std.ArrayList(i64) = .empty;
    for (entries) |entry| {
        if (entry.kind != .directory) continue;
        const id = std.fmt.parseInt(i64, entry.name, 10) catch continue;
        if (id <= 0) continue;
        try ids.append(alloc, id);
    }
    const out = try ids.toOwnedSlice(alloc);
    std.mem.sort(i64, out, {}, std.sort.asc(i64));
    return out;
}

/// countTextLines returns the number of non-empty lines in `path`, or 0 if the
/// file is missing.
pub fn countTextLines(io: Io, alloc: Alloc, path: []const u8) !usize {
    const body = (try store.readOrNull(io, alloc, path, .unlimited)) orelse return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

/// countSessionActions counts the lines in <session>/actions.dsl.
pub fn countSessionActions(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !usize {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, "actions.dsl" });
    return countTextLines(io, alloc, full);
}

/// compactJSON strips insignificant whitespace (outside string literals) from
/// `src`: string contents and every non-whitespace byte are copied verbatim;
/// spaces/tabs/CR/LF between tokens are dropped. Real input is always valid
/// Elm-produced JSON, so this does no validation.
fn compactJSON(alloc: Alloc, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_string = false;
    var escaped = false;
    for (src) |c| {
        if (in_string) {
            try out.append(alloc, c);
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            ' ', '\t', '\r', '\n' => continue, // insignificant whitespace
            '"' => {
                in_string = true;
                try out.append(alloc, c);
            },
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const roots = @import("roots.zig");

/// The host's turn, as the writers below take it: a handler runs only inside
/// it (webbox's linux_host `turn`; the bare-metal host's one loop), and
/// this file keeps no lock of its own.
var test_turn: Io.Mutex = .init;

/// One writer of the concurrent-append test, each append in a turn of its
/// own, as a handler's would be. `parent` must be thread-safe: the test
/// passes the page allocator (named only inside a test block).
fn appendMany(io: Io, parent: Alloc, user_id: []const u8, session_id: i64, writer: usize, n: usize) void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // A line long enough that two writes at one offset overlap.
        const line = std.fmt.bufPrint(&buf, "{d}-{d}) {s}", .{ writer, i, &@as([1500]u8, @splat('x')) }) catch return;
        const dir = sessionDir(alloc, user_id, session_id) catch return;
        const path = join(alloc, &.{ dir, "actions.dsl" }) catch return;
        test_turn.lockUncancelable(io);
        defer test_turn.unlock(io);
        appendLine(io, alloc, path, lineOf(alloc, .actions, line) catch return) catch return;
    }
}

test "fs: appends to one session from many writers at once, each in the host's turn, all land, whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();

    const id = try allocateSessionID(io, a, "p1");
    try writeSessionFile(io, a, "p1", id, "meta", "m");
    const writers = 8;
    const each = 100;
    var group: Io.Group = .init;
    var w: usize = 0;
    while (w < writers) : (w += 1) {
        group.concurrent(io, appendMany, .{ io, std.heap.page_allocator, "p1", id, w, each }) catch
            group.async(io, appendMany, .{ io, std.heap.page_allocator, "p1", id, w, each });
    }
    try group.await(io);

    const body = (try readSessionFile(io, a, "p1", id, "actions.dsl")).?;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    while (it.next()) |line| {
        try testing.expect(std.mem.endsWith(u8, line, &@as([1500]u8, @splat('x')))); // whole, not overwritten
        lines += 1;
    }
    try testing.expectEqual(@as(usize, writers * each), lines);
}

test "fs: a session file that cannot be read is an error, never a fresh game" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();

    const id = try allocateSessionID(io, a, "p1");
    try testing.expectEqual(@as(?[]u8, null), try readSessionFile(io, a, "p1", id, "meta")); // not there
    try store.makeDir(io, a, try join(a, &.{ try sessionDir(a, "p1", id), "actions.dsl" }));
    try testing.expect(std.meta.isError(readSessionFile(io, a, "p1", id, "actions.dsl")));
}

test "fs: a first move for a session the page did not offer counts nothing against its player (metal-vmm QUEUE 172)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    const forgot = game_limits.forgetForTest();
    defer forgot.end();
    const payer = Payer{ .id = "p1", .client = null };
    // Session 99 was never offered: refused, and nothing counted.
    try std.testing.expect(try appendPuzzleMove(io, a, payer, 99, 0, "move", "the meta") == .not_offered);
    // Its whole allowance is still there, its sessions too.
    try std.testing.expect((try game_limits.admit(io, a, "p1", null, false, game_limits.max_bytes)) == null);
    for (0..game_limits.max_sessions) |_| try std.testing.expect((try game_limits.admit(io, a, "p1", null, true, 0)) == null);
}

test "fs: a session made counts one against its player; its lines, and a puzzle's later moves, count none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    const forgot = game_limits.forgetForTest();
    defer forgot.end();
    const payer = Payer{ .id = "p1", .client = null };
    const made = try makeGameSession(io, a, payer, "the meta");
    try std.testing.expectEqual(@as(?u32, 1), game_limits.countedSessions("p1"));
    for (0..3) |_| try std.testing.expect(try appendGameLine(io, a, payer, made.id, .actions, "a line") == null);
    try std.testing.expectEqual(@as(?u32, 1), game_limits.countedSessions("p1"));
    const offered = try nextPuzzleSessionID(io, a, "p1");
    try std.testing.expect(try appendPuzzleMove(io, a, payer, offered, 0, "first", "puzzle meta") == .done);
    try std.testing.expectEqual(@as(?u32, 2), game_limits.countedSessions("p1"));
    try std.testing.expect(try appendPuzzleMove(io, a, payer, offered, 0, "second", null) == .done);
    try std.testing.expectEqual(@as(?u32, 2), game_limits.countedSessions("p1"));
}
