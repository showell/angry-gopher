//! storage: filesystem-backed puzzle-session storage. Mirrors the puzzle
//! subset of Go's server/lynrummy/game_data.go + platform.AllocateID. Dumb
//! id-keyed file store; meta is last-write-wins, actions.dsl is append-only.
//!
//! data_root is the SHARED live dir Go uses (GameDataRoot). The zig server runs
//! from zig-server/, so the repo-relative path carries the `..`. Per the port
//! decision, both binaries read/write the same tree.
//!
//! On-disk shape under {data_root}/{userID}/puzzle/sessions/<id>/:
//!   meta                       — created_at + catalog snapshot (DSL)
//!   puzzle_<idx>/actions.dsl   — one `<seq>) <action>` line per append
//!
//! Atomicity note: Go gets per-line append atomicity from O_APPEND (writes <
//! PIPE_BUF). The std.Io file API exposes no O_APPEND, so appendTextLine does
//! stat-size-then-positional-write. That is fully atomic for THIS design because
//! session ids come from the shared counter, so a given actions.dsl is only ever
//! written by the one server that allocated its session — there are never two
//! concurrent appenders to the same file. (The counter file itself is the one
//! cross-process race; see allocateID.)

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// data_root mirrors Go's GameDataRoot. Shared, live, repo-relative-from-zig-server.
pub var data_root: []const u8 = "../games/lynrummy/data";

// idMu serializes counter increments within this process, mirroring Go's idMu.
// (Cross-process serialization with the Go server is not provided — same as Go,
// whose mutex is process-local; see the allocateID comment.)
var id_mu: Io.Mutex = .init;

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

/// deleteUserData removes a player's entire game-data subtree (Go's
/// lynrummy.DeleteUserData → os.RemoveAll). Refuses an empty id. Absent is OK.
pub fn deleteUserData(io: Io, alloc: Alloc, user_id: []const u8) !void {
    if (std.mem.trim(u8, user_id, " \t\r\n").len == 0) return error.EmptyUserID;
    const root = try userRoot(alloc, user_id);
    Io.Dir.cwd().deleteTree(io, root) catch {};
}

fn puzzleRoot(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "puzzle" });
}

/// lynrummyElmRoot is the full-game namespace for a player. Mirrors Go's
/// lynrummyElmRoot.
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
/// for a player, persisted in their next-puzzle-id.txt. Mirrors Go's
/// AllocatePuzzleSessionID → platform.AllocateID.
pub fn allocatePuzzleSessionID(io: Io, alloc: Alloc, user_id: []const u8) !i64 {
    return allocateID(io, alloc, try nextPuzzleIDPath(alloc, user_id));
}

/// allocateID is the shared counter-bump primitive: read the counter, return the
/// current value, write value+1, auto-creating the file. Floors at 1. Mirrors
/// platform.AllocateID exactly (including the n<1 → 1 clamp). Public so the user
/// registry (users.zig) can drive the account-id counter (AuthRoot/next-id.txt)
/// through the same primitive Go shares via platform.AllocateID.
pub fn allocateID(io: Io, alloc: Alloc, path: []const u8) !i64 {
    id_mu.lockUncancelable(io);
    defer id_mu.unlock(io);

    try mkParentDirs(io, path);

    var n: i64 = 0;
    if (Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited)) |body| {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (std.fmt.parseInt(i64, trimmed, 10)) |parsed| {
            n = parsed;
        } else |_| {}
    } else |_| {}
    if (n < 1) n = 1;
    const next = n + 1;

    const out = try std.fmt.allocPrint(alloc, "{d}\n", .{next});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out });
    return n;
}

/// writePuzzleSessionFile writes body to <session-dir>/<rel>, creating parent
/// dirs. Last-write-wins (used for meta).
pub fn writePuzzleSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try mkParentDirs(io, full);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = body });
}

/// puzzleSessionExists reports whether a session directory is on disk. Mirrors
/// Go's PuzzleSessionExists (stat + IsDir).
pub fn puzzleSessionExists(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !bool {
    const dir = try puzzleSessionDir(alloc, user_id, session_id);
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch return false;
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
/// write at the current end. Mirrors Go's AppendTextLine. See the atomicity note
/// at the top of this file.
fn appendTextLine(io: Io, alloc: Alloc, path: []const u8, body: []const u8) !void {
    try mkParentDirs(io, path);

    const trimmed = std.mem.trimEnd(u8, body, "\n");
    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{trimmed});

    // truncate=false: open-or-create without clobbering existing content.
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, line, st.size);
}

// ── full-game (lynrummy-elm) namespace ──────────────────────────────────────
//
// The full game adds READ-BACK to the puzzle's write-only surface: resume reads
// meta+actions, the list pages read every session dir. Same dumb id-keyed store,
// new namespace ({id}/lynrummy-elm/sessions/<id>/), and a few read helpers.

/// allocateSessionID returns the next sequential full-game session id (1-based)
/// for a player, persisted in their next-session-id.txt. Mirrors Go's
/// AllocateSessionID → platform.AllocateID.
pub fn allocateSessionID(io: Io, alloc: Alloc, user_id: []const u8) !i64 {
    return allocateID(io, alloc, try nextSessionIDPath(alloc, user_id));
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
    try mkParentDirs(io, full);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = body });
}

/// readSessionFile reads <session-dir>/<rel>, or null when the file (or session)
/// is missing. Mirrors Go's ReadSessionFile (which returns os.ErrNotExist; the
/// callers all treat not-exist as "absent", so null carries the same meaning).
pub fn readSessionFile(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8) !?[]u8 {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    return Io.Dir.cwd().readFileAlloc(io, full, alloc, .unlimited) catch return null;
}

/// sessionExists reports whether a full-game session directory is on disk.
pub fn sessionExists(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !bool {
    const dir = try sessionDir(alloc, user_id, session_id);
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch return false;
    return st.kind == .directory;
}

/// appendSessionDslLine appends one DSL line to <session-dir>/<rel> (actions.dsl).
pub fn appendSessionDslLine(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64, rel: []const u8, body: []const u8) !void {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, rel });
    try appendTextLine(io, alloc, full, body);
}

/// appendSessionJSONLLine appends one JSON-compacted line to <session-dir>/<rel>
/// (annotations.jsonl). Mirrors Go's AppendSessionLine → AppendJSONLLine: the
/// body is JSON-compacted (insignificant whitespace stripped) then written as
/// compact-body + '\n'.
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

    var dir = Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var ids: std.ArrayList(i64) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
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
    const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

/// countSessionActions counts the lines in <session>/actions.dsl. Mirrors Go's
/// CountSessionActions.
pub fn countSessionActions(io: Io, alloc: Alloc, user_id: []const u8, session_id: i64) !usize {
    const dir = try sessionDir(alloc, user_id, session_id);
    const full = try join(alloc, &.{ dir, "actions.dsl" });
    return countTextLines(io, alloc, full);
}

/// appendRawLine appends `body` + one '\n' to `path` (no trailing-newline
/// trimming — `body` is already exactly one line). Used by the JSONL path, whose
/// compacted body never contains a newline. Mirrors the write half of Go's
/// AppendJSONLLine.
fn appendRawLine(io: Io, alloc: Alloc, path: []const u8, body: []const u8) !void {
    try mkParentDirs(io, path);
    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{body});
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, line, st.size);
}

/// compactJSON strips insignificant whitespace (outside string literals) from
/// `src`, mirroring Go's json.Compact at the token level: string contents and
/// every non-whitespace byte are copied verbatim; spaces/tabs/CR/LF between
/// tokens are dropped. Real input is always valid Elm-produced JSON, so this does
/// no validation.
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

/// mkParentDirs creates the directory containing `path` (mkdir -p). No-op when
/// `path` has no directory component.
fn mkParentDirs(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| {
        try Io.Dir.cwd().createDirPath(io, d);
    }
}
