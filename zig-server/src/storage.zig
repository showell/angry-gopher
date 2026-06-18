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

fn puzzleRoot(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "puzzle" });
}

fn nextPuzzleIDPath(alloc: Alloc, user_id: []const u8) ![]u8 {
    return join(alloc, &.{ data_root, user_id, "next-puzzle-id.txt" });
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
/// platform.AllocateID exactly (including the n<1 → 1 clamp).
fn allocateID(io: Io, alloc: Alloc, path: []const u8) !i64 {
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
/// dirs. Last-write-wins (used for meta). Mirrors Go's WritePuzzleSessionFile.
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
/// Mirrors Go's AppendPuzzleSessionDslLine → AppendTextLine.
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

/// mkParentDirs creates the directory containing `path` (mkdir -p). No-op when
/// `path` has no directory component.
fn mkParentDirs(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| {
        try Io.Dir.cwd().createDirPath(io, d);
    }
}
