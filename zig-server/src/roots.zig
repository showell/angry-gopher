//! roots: where the live data is. One call points every store at it.
//!
//! Given a data directory and an account directory, `point` sets the six
//! roots the stores read:
//!
//!   {data_dir}/lynrummy   storage.data_root          game + puzzle sessions
//!   {data_dir}/users      users.users_root           last-seen, upload quota
//!   {data_dir}/players    player.player_root         the LOCAL identity
//!   {data_dir}/chat       users.session_secret_dir   _session_secret
//!   {data_dir}/chat       chat_store.chat_root       conversations
//!   {auth_dir}            users.auth_root            the account store
//!
//! **IT IS SEPARATE FROM config.zig BECAUSE IT CAN CROSS.** config.zig reads an
//! environment variable and opens the file it names — which is how a Linux
//! process learns where its data is, and which does not exist on a machine with
//! no operating system. This is the part that was never about the environment:
//! the mapping from two directories to six roots. config.zig calls it after
//! parsing; a kernel calls it with paths on its own volume. Neither restates the
//! mapping, so the two hosts cannot disagree about where a store lives.
//!
//! Content read relative to the working directory — `pages/`, `gallery/`,
//! `downloads/` — is not here: those are the site, not its data, and they
//! resolve against wherever the host is standing.

const std = @import("std");
const storage = @import("storage.zig");
const users = @import("users.zig");
const player = @import("player.zig");
const chat_store = @import("chat_store.zig");

pub const Roots = struct {
    data_dir: []const u8,
    auth_dir: []const u8,
};

/// point sets every root from `r`. The strings are allocated from `alloc` and
/// must live as long as the process, so a host passes its base allocator.
pub fn point(alloc: std.mem.Allocator, r: Roots) !void {
    storage.data_root = try std.fs.path.join(alloc, &.{ r.data_dir, "lynrummy" });
    users.users_root = try std.fs.path.join(alloc, &.{ r.data_dir, "users" });
    player.player_root = try std.fs.path.join(alloc, &.{ r.data_dir, "players" });
    users.session_secret_dir = try std.fs.path.join(alloc, &.{ r.data_dir, "chat" });
    chat_store.chat_root = try std.fs.path.join(alloc, &.{ r.data_dir, "chat" });
    users.auth_root = try alloc.dupe(u8, r.auth_dir);
}

// ══ TESTS ════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Snapshot restores every root a test moved, so the defaults the rest of the
/// test binary expects are still there afterwards.
const Snapshot = struct {
    data: []const u8,
    users_r: []const u8,
    players: []const u8,
    secret: []const u8,
    chat: []const u8,
    auth: []const u8,

    fn take() Snapshot {
        return .{
            .data = storage.data_root,
            .users_r = users.users_root,
            .players = player.player_root,
            .secret = users.session_secret_dir,
            .chat = chat_store.chat_root,
            .auth = users.auth_root,
        };
    }

    fn restore(s: Snapshot) void {
        storage.data_root = s.data;
        users.users_root = s.users_r;
        player.player_root = s.players;
        users.session_secret_dir = s.secret;
        chat_store.chat_root = s.chat;
        users.auth_root = s.auth;
    }
};

test "point sets all six roots from two directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = Snapshot.take();
    defer saved.restore();

    try point(arena.allocator(), .{ .data_dir = "/srv/gopher", .auth_dir = "/srv/auth" });
    try testing.expectEqualStrings("/srv/gopher/lynrummy", storage.data_root);
    try testing.expectEqualStrings("/srv/gopher/users", users.users_root);
    try testing.expectEqualStrings("/srv/gopher/players", player.player_root);
    try testing.expectEqualStrings("/srv/gopher/chat", users.session_secret_dir);
    try testing.expectEqualStrings("/srv/gopher/chat", chat_store.chat_root);
    try testing.expectEqualStrings("/srv/auth", users.auth_root);
}

test "point takes the relative paths a kernel uses on its own volume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = Snapshot.take();
    defer saved.restore();

    try point(arena.allocator(), .{ .data_dir = "data", .auth_dir = "auth" });
    try testing.expectEqualStrings("data/lynrummy", storage.data_root);
    try testing.expectEqualStrings("data/players", player.player_root);
    try testing.expectEqualStrings("auth", users.auth_root);
    // Nothing reaches upward: a FAT16 root directory has no `..` entry, which is
    // why the stores' repo-relative defaults cannot serve a volume.
    for ([_][]const u8{ storage.data_root, users.users_root, player.player_root, users.session_secret_dir, chat_store.chat_root, users.auth_root }) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "..") == null);
    }
}

test "a trailing slash on the data directory changes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = Snapshot.take();
    defer saved.restore();

    try point(arena.allocator(), .{ .data_dir = "/srv/gopher/", .auth_dir = "/srv/auth" });
    try testing.expectEqualStrings("/srv/gopher/lynrummy", storage.data_root);
    try testing.expectEqualStrings("/srv/gopher/players", player.player_root);
}

test "point copies the auth directory rather than aliasing the caller's buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = Snapshot.take();
    defer saved.restore();

    var buf = "/srv/auth".*;
    try point(arena.allocator(), .{ .data_dir = "/d", .auth_dir = &buf });
    buf[1] = 'X'; // the caller reuses its buffer
    try testing.expectEqualStrings("/srv/auth", users.auth_root);
}

test "an allocation failure is reported, not swallowed" {
    // point is called once, at startup, and a failure there must end the
    // process: some roots would be new and the rest still defaults, and serving
    // from that mix would read one store and write another.
    const saved = Snapshot.take();
    defer saved.restore();

    var tiny: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    try testing.expectError(error.OutOfMemory, point(fba.allocator(), .{ .data_dir = "/srv/gopher", .auth_dir = "/a" }));
}
