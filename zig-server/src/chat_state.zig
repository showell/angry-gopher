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

/// `value` and a newline at `path`, unless it already holds `value`. The
/// Roc chat reads and writes these files itself (roc-webbox
/// chat/ChatState.roc: `bookmark` reads them as lastViewedTopic
/// does, `changed` is this decision); chat_twin_test.zig
/// holds both to this, on disk.
fn writeIfChanged(io: Io, alloc: Alloc, path: []const u8, value: []const u8) !void {
    // absent-ok: a bookmark that cannot be read is written again; the write says whether it can be.
    const was = disk.readOrNull(io, alloc, path, .limited(256)) catch null;
    if (was) |w| if (std.mem.eql(u8, std.mem.trim(u8, w, " \t\r\n"), value)) return;
    try disk.write(io, alloc, path, try std.fmt.allocPrint(alloc, "{s}\n", .{value}), .{});
}

// ── pinned topics (the sidebar's Pinned group) ──────────────────────────────

/// pinnedTopics returns the set of topic ids this user has pinned in the
/// conversation `conv_key`, sorted. A missing file → empty. The Roc chat
/// reads and writes the pins (roc-webbox chat/ChatState.roc); this reads
/// back what it wrote, for the tests.
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

fn pinnedPath(alloc: Alloc, uid: []const u8, conv_key: []const u8) ![]u8 {
    const dir = try userChatStateDir(alloc, uid);
    return std.fs.path.join(alloc, &.{ dir, "pinned-sessions", conv_key });
}

/// The member's pinned file for `conv_key`, as stored: "" when there is
/// none; an error when it will not read, never "".
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
    return chooseResumeTopic(alloc, topics, last, now.unixSecs());
}

/// chooseResumeTopic is resumeTopic's decision, pure: `last` (the topic last
/// viewed, "" for none) while `topics` has it, else their firstOf, else the
/// date of `now_secs`. The Roc chat makes the same choice (roc-webbox
/// chat/ChatState.roc `resume_topic`); chat_twin_test.zig holds it to this.
pub fn chooseResumeTopic(alloc: Alloc, topics: []const []const u8, last: []const u8, now_secs: i64) ![]const u8 {
    if (last.len != 0) {
        for (topics) |s| if (std.mem.eql(u8, s, last)) return last;
    }
    const first = chat_paths.firstOf(topics);
    if (first.len > 0) return first;
    return timefmt.formatDateUTC(alloc, now_secs);
}
