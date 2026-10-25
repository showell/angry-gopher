//! chat_state: per-user chat state — which
//! (conv, topic) a user was last looking at, and which topics they've pinned
//! in each conversation. Backs /chat/default (resume where you were), the
//! conversation page's topic memory, and the sidebar's Pinned group.
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
const chat_paths = @import("chat_paths.zig");
const Now = @import("request_time.zig").Now;
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");
const disk = @import("webbox").store;
const timefmt = @import("timefmt.zig");

/// userChatStateDir is a user's per-chat-state directory ({chat_root}/users/<uid>),
/// sibling of users/<uid>/docs/.
fn userChatStateDir(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ store.chat_root, "users", uid });
}

// ── last conv / topic (the /chat/default resume pointer) ────────────────────

/// lastUserConv returns the conv-key this user was most recently looking at, or
/// "" if they've never had one.
pub fn lastUserConv(io: Io, alloc: Alloc, uid: []const u8) ![]const u8 {
    const dir = try userChatStateDir(alloc, uid);
    const path = try std.fs.path.join(alloc, &.{ dir, "last-conv" });
    const b = (try disk.readOrNull(io, alloc, path, .unlimited)) orelse return "";
    return std.mem.trim(u8, b, " \t\r\n");
}

/// lastViewedTopic returns the topic id this user last viewed for `conv_key`,
/// or "" if never.
pub fn lastViewedTopic(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]const u8 {
    const dir = try userChatStateDir(alloc, uid);
    const path = try std.fs.path.join(alloc, &.{ dir, "last-sessions", conv_key });
    const b = (try disk.readOrNull(io, alloc, path, .unlimited)) orelse return "";
    return std.mem.trim(u8, b, " \t\r\n");
}

/// setLastViewedTopic persists which topic this user last viewed for `conv_key`
/// AND bumps the last-conv pointer so /chat/default resumes the right pair.
/// Best-effort.
///
/// **WRITTEN ONLY WHEN IT CHANGES** (zig-metal-unikernel 153(1)): on every send and
/// view the value is usually the one already there, and a write is disk
/// requests each time; the read is from memory. `write` makes the folders.
pub fn setLastViewedTopic(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8) !void {
    if (uid.len == 0 or sid.len == 0) return;
    const dir = try userChatStateDir(alloc, uid);
    try writeIfChanged(io, alloc, try std.fs.path.join(alloc, &.{ dir, "last-sessions", conv_key }), sid);
    try writeIfChanged(io, alloc, try std.fs.path.join(alloc, &.{ dir, "last-conv" }), conv_key);
}

/// `value` and a newline at `path`, unless it already holds `value`.
fn writeIfChanged(io: Io, alloc: Alloc, path: []const u8, value: []const u8) !void {
    // absent-ok: a bookmark that cannot be read is written again; the write says whether it can be.
    const was = disk.readOrNull(io, alloc, path, .limited(256)) catch null;
    if (was) |w| if (std.mem.eql(u8, std.mem.trim(u8, w, " \t\r\n"), value)) return;
    try disk.write(io, alloc, path, try std.fmt.allocPrint(alloc, "{s}\n", .{value}), .{});
}

// ── pinned topics (the sidebar's Pinned group) ──────────────────────────────

/// pinnedTopics returns the set of topic ids this user has pinned in the
/// conversation `conv_key`, sorted (the file's content order). A missing file →
/// empty. Stale ids are harmless — callers intersect with the live topic list.
pub fn pinnedTopics(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8) ![][]const u8 {
    return parsePinned(alloc, try readPinnedFile(io, alloc, uid, conv_key));
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
/// tiny — a handful of topics).
pub fn isPinned(set: [][]const u8, sid: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, sid)) return true;
    }
    return false;
}

/// setTopicPinned adds or removes one topic from the user's pinned set for
/// `conv_key`, persisting it sorted. Removing the last pin deletes the file.
/// **A PIN THAT DID NOT LAND SAYS SO** (metal-vmm QUEUE 156(g)): every
/// failure is the caller's, where it answered 204 having written nothing.
pub fn setTopicPinned(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8, sid: []const u8, pinned: bool) !void {
    if (uid.len == 0 or sid.len == 0) return;
    // **A SET THAT WILL NOT READ IS NOT AN EMPTY SET.** What is read here is
    // rewritten below, so treating a failed read as "no pins" used to delete
    // every pin the user had — silently, on the way to adding one. No pins is
    // a missing file (store.zig answers ""); anything else leaves them alone.
    const existing = try readPinnedFile(io, alloc, uid, conv_key);
    const cur = try parsePinned(alloc, existing);

    // Rebuild the set with sid added/removed, kept sorted and de-duped.
    var next: std.ArrayList([]const u8) = .empty;
    var have = false;
    for (cur) |s| {
        if (std.mem.eql(u8, s, sid)) {
            have = true;
            if (!pinned) continue; // drop it
        }
        try next.append(alloc, s);
    }
    if (pinned and !have) try next.append(alloc, sid);

    const path = try pinnedPath(alloc, uid, conv_key);
    if (next.items.len == 0) return disk.remove(io, alloc, path);
    std.mem.sort([]const u8, next.items, {}, lessThanStr);

    var body: std.ArrayList(u8) = .empty;
    for (next.items) |s| {
        try body.appendSlice(alloc, s);
        try body.append(alloc, '\n');
    }
    if (std.fs.path.dirname(path)) |d| try disk.makeDir(io, alloc, d);
    try disk.write(io, alloc, path, body.items, .{});
}

fn pinnedPath(alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]u8 {
    const dir = try userChatStateDir(alloc, uid);
    return std.fs.path.join(alloc, &.{ dir, "pinned-sessions", conv_key });
}

fn readPinnedFile(io: Io, alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]u8 {
    const path = try pinnedPath(alloc, uid, conv_key);
    return disk.readOrEmpty(io, alloc, path, .unlimited);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── resume target (the bare-conv landing topic) ─────────────────────────────

/// resumeTopic picks the topic a bare /chat/c/<conv> (or docs post-to-chat)
/// lands on for `uid`: the one they last viewed, if it still exists; else the
/// conversation's first topic (chat_paths.firstOf); else today's date, so a
/// brand-new conversation makes today's topic on its first post. Shared by
/// /chat/default and the docs post flow. Where the viewer does not count,
/// chat_paths.firstTopic.
pub fn resumeTopic(io: Io, alloc: Alloc, uid: []const u8, conv: []const u8, now: Now) ![]const u8 {
    const dir = try chat_paths.dmConvDir(alloc, conv);
    const topics = try chat_paths.listTopics(io, alloc, dir);

    const last = try lastViewedTopic(io, alloc, uid, conv);
    if (last.len != 0) {
        for (topics) |s| if (std.mem.eql(u8, s, last)) return last;
    }
    const first = chat_paths.firstOf(topics);
    if (first.len > 0) return first;
    return timefmt.formatDateUTC(alloc, now.unixSecs());
}
