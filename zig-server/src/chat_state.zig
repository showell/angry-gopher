//! chat_state: per-user chat state — which
//! (conv, session) a user was last looking at, and which sessions they've pinned
//! in each conversation. Backs /chat/default (resume where you were), the
//! conversation page's session memory, and the sidebar's Pinned group.
//!
//! Per-user state files (under the shared chat tree):
//!   {chat_root}/users/<uid>/last-conv                  — conv-key text file
//!   {chat_root}/users/<uid>/last-sessions/<conv-key>   — session-id text file
//!   {chat_root}/users/<uid>/pinned-sessions/<conv-key> — pinned sids, one/line
//!
//! Written on every conv page view + send, so the pointer tracks real focus.
//! Best-effort throughout: a failed write just loses the bookmark for that visit
//! (errors are never surfaced to the request).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");
const timefmt = @import("timefmt.zig");

/// userChatStateDir is a user's per-chat-state directory ({chat_root}/users/<uid>),
/// sibling of users/<uid>/docs/.
fn userChatStateDir(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ store.chat_root, "users", uid });
}

// ── last conv / session (the /chat/default resume pointer) ────────────────────

/// lastUserConv returns the conv-key this user was most recently looking at, or
/// "" if they've never had one.
pub fn lastUserConv(io: Io, alloc: Alloc, uid: []const u8) ![]const u8 {
    const dir = try userChatStateDir(alloc, uid);
    const path = try std.fs.path.join(alloc, &.{ dir, "last-conv" });
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return "";
    return std.mem.trim(u8, b, " \t\r\n");
}

/// lastUserSession returns the session id this user last viewed for `conv_key`,
/// or "" if never.
pub fn lastUserSession(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]const u8 {
    const dir = try userChatStateDir(alloc, uid);
    const path = try std.fs.path.join(alloc, &.{ dir, "last-sessions", conv_key });
    const b = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return "";
    return std.mem.trim(u8, b, " \t\r\n");
}

/// setUserLastSession persists which session this user last viewed for `conv_key`
/// AND bumps the last-conv pointer so /chat/default resumes the right pair.
/// Best-effort.
pub fn setUserLastSession(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8) void {
    if (uid.len == 0 or sid.len == 0) return;
    const dir = userChatStateDir(alloc, uid) catch return;
    const ls_dir = std.fs.path.join(alloc, &.{ dir, "last-sessions" }) catch return;
    Io.Dir.cwd().createDirPath(io, ls_dir) catch return;
    const ls_path = std.fs.path.join(alloc, &.{ ls_dir, conv_key }) catch return;
    const sv = std.fmt.allocPrint(alloc, "{s}\n", .{sid}) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = ls_path, .data = sv }) catch {};
    const lc_path = std.fs.path.join(alloc, &.{ dir, "last-conv" }) catch return;
    const cv = std.fmt.allocPrint(alloc, "{s}\n", .{conv_key}) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = lc_path, .data = cv }) catch {};
}

// ── pinned sessions (the sidebar's Pinned group) ──────────────────────────────

/// pinnedSessions returns the set of session ids this user has pinned in the
/// conversation `conv_key`, sorted (the file's content order). A missing file →
/// empty. Stale ids are harmless — callers intersect with the live session list.
pub fn pinnedSessions(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8) ![][]const u8 {
    const b = readPinnedFile(io, alloc, uid, conv_key) catch return &.{};
    return parsePinned(alloc, b);
}

fn parsePinned(alloc: Alloc, b: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, b, '\n');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r");
        if (s.len != 0) try out.append(alloc, s);
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

/// isPinned reports whether `sid` is in a pinned-set slice (linear; the set is
/// tiny — a handful of sessions).
pub fn isPinned(set: [][]const u8, sid: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, sid)) return true;
    }
    return false;
}

/// setSessionPinned adds or removes one session from the user's pinned set for
/// `conv_key`, persisting it sorted. Removing the last pin deletes the file.
/// Best-effort.
pub fn setSessionPinned(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8, pinned: bool) void {
    if (uid.len == 0 or sid.len == 0) return;
    const existing = readPinnedFile(io, alloc, uid, conv_key) catch "";
    const cur = parsePinned(alloc, existing) catch return;

    // Rebuild the set with sid added/removed, kept sorted and de-duped.
    var next: std.ArrayList([]const u8) = .empty;
    var have = false;
    for (cur) |s| {
        if (std.mem.eql(u8, s, sid)) {
            have = true;
            if (!pinned) continue; // drop it
        }
        next.append(alloc, s) catch return;
    }
    if (pinned and !have) next.append(alloc, sid) catch return;

    const path = pinnedPath(alloc, uid, conv_key) catch return;
    if (next.items.len == 0) {
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    }
    std.mem.sort([]const u8, next.items, {}, lessThanStr);

    var body: std.ArrayList(u8) = .empty;
    for (next.items) |s| {
        body.appendSlice(alloc, s) catch return;
        body.append(alloc, '\n') catch return;
    }
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(io, d) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items }) catch {};
}

fn pinnedPath(alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]u8 {
    const dir = try userChatStateDir(alloc, uid);
    return std.fs.path.join(alloc, &.{ dir, "pinned-sessions", conv_key });
}

fn readPinnedFile(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]u8 {
    const path = try pinnedPath(alloc, uid, conv_key);
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── resume target (the bare-conv landing session) ─────────────────────────────

/// resolveSessionForUser picks the session a bare /chat/c/<conv> (or docs
/// post-to-chat) lands on for `uid`, in priority order: the user's last-viewed (if
/// it still exists) → ChitChat → first-alphabetical → today's date (so a brand-new
/// conv auto-creates today's session on first post).
/// Shared by /chat/default and the docs post flow.
pub fn resolveSessionForUser(io: Io, alloc: Alloc, uid: []const u8, conv: []const u8) ![]const u8 {
    const dir = try store.dmConvDir(alloc, conv);
    const sessions = try store.listSessions(io, alloc, dir);

    const last = try lastUserSession(io, alloc, uid, conv);
    if (last.len != 0) {
        for (sessions) |s| if (std.mem.eql(u8, s, last)) return last;
    }
    for (sessions) |s| if (std.mem.eql(u8, s, "ChitChat")) return s;
    if (sessions.len > 0) return sessions[0];
    return timefmt.formatDateUTC(alloc, nowUnix(io));
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}
