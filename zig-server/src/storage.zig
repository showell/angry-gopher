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
//! **APPENDS ARE SERIALIZED** by the host: one handler runs at a time (gopher-metal HOST.md). store.append stats the file's size
//! and then writes at it (the std.Io file API exposes no O_APPEND), so two
//! appends to one file at once could both write at the old end, one over the
//! other. This file once said that could not happen, because one request
//! allocates a session; but the append routes take any session the player
//! owns, so one player in two tabs, or a client retrying, appends to one file
//! twice at once. Measured: 1,814 of 2,000 lines landed from 8 concurrent
//! writers (gopher-metal's GROWTH-game-store.md).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const counter = @import("counter.zig");
const store = @import("store.zig");
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
/// Refuses an empty id. Absent is OK.
pub fn deleteUserData(io: Io, alloc: Alloc, user_id: []const u8) !void {
    if (std.mem.trim(u8, user_id, " \t\r\n").len == 0) return error.EmptyUserID;
    const root = try userRoot(alloc, user_id);
    store.removeTree(io, alloc, root) catch {};
    game_limits.forget(io, user_id); // what they held is gone
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
/// Nothing is written (gopher-metal QUEUE item 52: no write on a GET).
pub fn nextPuzzleSessionID(io: Io, alloc: Alloc, user_id: []const u8) !i64 {
    return counter.peek(io, alloc, try nextPuzzleIDPath(alloc, user_id));
}


/// Makes puzzle session `session_id`, with `meta`, if it is the one a page
/// offered (`nextPuzzleSessionID`) and is not there yet; answers whether the
/// session is there afterwards. An id never offered makes nothing.
pub fn ensurePuzzleSession(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, meta: []const u8) !bool {
    if (try puzzleSessionExists(io, alloc, user_id, session_id)) return true;
    if (session_id != try nextPuzzleSessionID(io, alloc, user_id)) return false;
    const got = try allocatePuzzleSessionID(io, alloc, user_id);
    std.debug.assert(got == session_id); // one handler at a time
    try writePuzzleSessionFile(io, alloc, user_id, session_id, "meta", meta);
    return true;
}

/// writePuzzleSessionFile writes body to <session-dir>/<rel>, creating parent
/// dirs. Last-write-wins (used for meta).
pub fn writePuzzleSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try store.write(io, alloc, full, body, .{});
}

/// puzzleSessionExists reports whether a session directory is on disk.
pub fn puzzleSessionExists(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !bool {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const st = store.stat(io, alloc, dir) catch return false;
    return st.kind == .directory;
}

/// appendPuzzleSessionDslLine appends one DSL line to <session-dir>/<rel>.
pub fn appendPuzzleSessionDslLine(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try appendTextLine(io, alloc, full, body);
}

/// appendTextLine appends `body` (trailing newlines stripped) + one '\n' to
/// `path`, creating parent dirs. The line is written in a single positional
/// write at the current end. See the atomicity note
/// at the top of this file.
fn appendTextLine(io: Io, alloc: Alloc, path: []const u8, body: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, body, "\n");
    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{trimmed});
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
pub fn writeSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try store.write(io, alloc, full, body, .{});
}

/// readSessionFile reads <session-dir>/<rel>, or null when the file (or session)
/// is missing.
pub fn readSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8) !?[]u8 {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    return store.read(io, alloc, full, .unlimited) catch return null;
}

/// sessionExists reports whether a full-game session directory is on disk.
pub fn sessionExists(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !bool {
    const dir = try sessionDir(alloc, user_id, session_id);
    const st = store.stat(io, alloc, dir) catch return false;
    return st.kind == .directory;
}

/// appendSessionDslLine appends one DSL line to <session-dir>/<rel> (actions.dsl).
pub fn appendSessionDslLine(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try appendTextLine(io, alloc, full, body);
}

/// appendSessionJSONLLine appends one JSON-compacted line to <session-dir>/<rel>
/// (annotations.jsonl).
pub fn appendSessionJSONLLine(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    const compact = try compactJSON(alloc, body);
    try appendRawLine(io, alloc, full, compact);
}

/// listSessionIDs returns every full-game session-id directory for a player,
/// sorted ascending.
pub fn listSessionIDs(io: Io, alloc: Alloc, user_id: []const u8) ![]i64 {
    const root = try lynrummyElmRoot(alloc, user_id);
    const sessions = try join(alloc, &.{ root, "sessions" });

    const entries = store.list(io, alloc, sessions) catch return &.{};

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
    const body = store.read(io, alloc, path, .unlimited) catch return 0;
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

/// appendRawLine appends `body` + one '\n' to `path` (no trailing-newline
/// trimming — `body` is already exactly one line). Used by the JSONL path, whose
/// compacted body never contains a newline.
fn appendRawLine(io: Io, alloc: Alloc, path: []const u8, body: []const u8) !void {
    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{body});
    _ = try store.append(io, alloc, path, line);
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

/// One writer of the concurrent-append test. `parent` must be thread-safe:
/// the test passes the page allocator (named only inside a test block).
fn appendMany(io: Io, parent: Alloc, user_id: []const u8, session_id: i64, writer: usize, n: usize) void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // A line long enough that two writes at one offset overlap.
        const line = std.fmt.bufPrint(&buf, "{d}-{d}) {s}", .{ writer, i, "x" ** 1500 }) catch return;
        // Each append in a turn of its own, as a handler's would be: the host
        // serializes handlers (turn.zig), and this file keeps no lock.
        @import("turn.zig").enter(io);
        defer @import("turn.zig").leave(io);
        appendSessionDslLine(io, alloc, user_id, session_id, "actions.dsl", line) catch return;
    }
}

test "fs: appends to one session from many writers at once all land, whole, each in the host's turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = data_root;
    defer data_root = saved;
    data_root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
    defer testing.allocator.free(data_root);

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
        try testing.expect(std.mem.endsWith(u8, line, "x" ** 1500)); // whole, not overwritten
        lines += 1;
    }
    try testing.expectEqual(@as(usize, writers * each), lines);
}
