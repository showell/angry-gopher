//! roots: where the live data is. One call points every store at it.
//!
//! Given a data directory and an account directory, `point` sets the six
//! roots the stores read:
//!
//!   {data_dir}/lynrummy   storage.data_root          game + puzzle sessions
//!   {data_dir}/users      users.users_root           upload quota
//!   {data_dir}/players    player.player_root         the LOCAL identity
//!   {data_dir}/chat       chat_store.chat_root       conversations
//!   {auth_dir}            users.auth_root            the account store
//!   {auth_dir}            users.session_secret_dir   _session_secret
//!
//! **auth/ HOLDS EVERY SECRET, data/ NONE** (QUEUE item 106): the session
//! secret used to sit in data/chat/, mixed with chat data; now it is beside the
//! password hashes and API keys in auth/, so a leak surface is one tree, not
//! two. `migrateSecret` moves an existing secret there once at startup.
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
const Io = std.Io;
const storage = @import("storage.zig");
const users = @import("users.zig");
const player = @import("player.zig");
const chat_store = @import("chat_store.zig");
const store = @import("store.zig");

pub const Roots = struct {
    data_dir: []const u8,
    auth_dir: []const u8,
};

/// **EVERY GLOBAL `point` SETS, IN ONE LIST** (metal-vmm QUEUE 157(c)):
/// what `save` saves and `restore` puts back, where three test fixtures each
/// copied the eight by hand and restored them by index. A test holds `point`
/// to it (`point` assigns nothing it does not name).
const all = .{
    .{ "storage", storage, "data_root" },
    .{ "users", users, "users_root" },
    .{ "player", player, "player_root" },
    .{ "chat_store", chat_store, "chat_root" },
    .{ "users", users, "auth_root" },
    .{ "users", users, "session_secret_dir" },
    .{ "store", store, "data_base" }, // by store.setBases
    .{ "store", store, "auth_base" }, // by store.setBases
};

const Values = blk: {
    var types: [all.len]type = undefined;
    for (all, 0..) |e, i| types[i] = @TypeOf(@field(e[1], e[2]));
    break :blk std.meta.Tuple(&types);
};

/// Every root as it stood: `restore` puts each back, in one call.
pub const Saved = struct {
    values: Values,

    pub fn restore(self: Saved) void {
        inline for (all, 0..) |e, i| @field(e[1], e[2]) = self.values[i];
    }
};

pub fn save() Saved {
    var v: Values = undefined;
    inline for (all, 0..) |e, i| v[i] = @field(e[1], e[2]);
    return .{ .values = v };
}

/// **FOR A TEST: EVERY ROOT UNDER `base`**, `base/data` and `base/auth`, and
/// the roots as they stood to `defer` back (`saved.restore()`). One root
/// moved by hand left the others at the repo-relative defaults, so a test of
/// one store read another's real data.
pub fn pointForTest(alloc: std.mem.Allocator, base: []const u8) !Saved {
    const saved = save();
    errdefer saved.restore();
    try point(alloc, .{
        .data_dir = try std.fs.path.join(alloc, &.{ base, "data" }),
        .auth_dir = try std.fs.path.join(alloc, &.{ base, "auth" }),
    });
    return saved;
}

/// point sets every root from `r`. The strings are allocated from `alloc` and
/// must live as long as the process, so a host passes its base allocator.
pub fn point(alloc: std.mem.Allocator, r: Roots) !void {
    storage.data_root = try std.fs.path.join(alloc, &.{ r.data_dir, "lynrummy" });
    users.users_root = try std.fs.path.join(alloc, &.{ r.data_dir, "users" });
    player.player_root = try std.fs.path.join(alloc, &.{ r.data_dir, "players" });
    chat_store.chat_root = try std.fs.path.join(alloc, &.{ r.data_dir, "chat" });
    users.auth_root = try alloc.dupe(u8, r.auth_dir);
    // The session secret lives in auth/ now (QUEUE item 106), beside the hashes.
    users.session_secret_dir = users.auth_root;
    store.setBases(try alloc.dupe(u8, r.data_dir), users.auth_root);
}

/// **MOVE THE SESSION SECRET INTO auth/, ONCE** (QUEUE item 106). `point` points
/// the reads at auth/; this carries an existing secret there from its old home,
/// data/chat/, so a volume or tree written before the move still serves and no
/// session is lost. `host_start.start` calls it after `point`, before the
/// first request. Best-effort and idempotent.
///
/// **NEVER TWO COPIES.** Each of the three secret files is written to auth/ and
/// read back before the old one in data/chat/ is removed; a stop in between
/// leaves both, and the next startup finishes the job (auth/ already has it, so
/// the old is just removed). The end state is always the secret in auth/ alone.
pub fn migrateSecret(io: Io, alloc: std.mem.Allocator) void {
    const new_dir = users.session_secret_dir; // auth/, after point()
    const old_dir = chat_store.chat_root; // data/chat/, the old home
    if (std.mem.eql(u8, new_dir, old_dir)) return; // already the same place
    for ([_][]const u8{
        "_session_secret",
        "_session_secret.previous",
        "_session_secret.previous-until",
    }) |name| {
        const old_path = std.fs.path.join(alloc, &.{ old_dir, name }) catch continue;
        // absent-ok: a migration that cannot look does nothing: the next startup tries again.
        if (!(store.has(io, alloc, old_path) catch continue)) continue;
        const new_path = std.fs.path.join(alloc, &.{ new_dir, name }) catch continue;
        // absent-ok: an error is not "absent": nothing is written over what may be there.
        if (!(store.has(io, alloc, new_path) catch continue)) {
            // absent-ok: nothing read is nothing written, and the old copy stays.
            const bytes = store.read(io, alloc, old_path, .unlimited) catch continue;
            store.write(io, alloc, new_path, bytes, .{ .private = true }) catch continue;
            // Confirm the new copy reads back whole before dropping the old.
            // absent-ok: a copy that will not read back is not confirmed, and the old one stays.
            const back = store.read(io, alloc, new_path, .unlimited) catch continue;
            if (!std.mem.eql(u8, back, bytes)) continue;
        }
        store.remove(io, alloc, old_path) catch {};
    }
}

// ══ TESTS ════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "point sets all six roots from two directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = save();
    defer saved.restore();

    try point(arena.allocator(), .{ .data_dir = "/srv/gopher", .auth_dir = "/srv/auth" });
    try testing.expectEqualStrings("/srv/gopher/lynrummy", storage.data_root);
    try testing.expectEqualStrings("/srv/gopher/users", users.users_root);
    try testing.expectEqualStrings("/srv/gopher/players", player.player_root);
    try testing.expectEqualStrings("/srv/gopher/chat", chat_store.chat_root);
    try testing.expectEqualStrings("/srv/auth", users.auth_root);
    // The session secret is in auth/ now, not data/chat/ (QUEUE item 106).
    try testing.expectEqualStrings("/srv/auth", users.session_secret_dir);
}

test "migrateSecret moves the secret from data/chat to auth once, and never leaves two copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = save();
    defer saved.restore();

    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try point(a, .{
        .data_dir = try std.fs.path.join(a, &.{ base, "data" }),
        .auth_dir = try std.fs.path.join(a, &.{ base, "auth" }),
    });
    const old = chat_store.chat_root; // data/chat, the old home
    const new = users.session_secret_dir; // auth, the new one
    const secret = "a session secret at least thirty-two bytes!";
    const join = struct {
        fn f(al: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
            return std.fs.path.join(al, &.{ dir, name });
        }
    }.f;
    try store.write(io, a, try join(a, old, "_session_secret"), secret, .{});
    try store.write(io, a, try join(a, old, "_session_secret.previous"), "the previous secret, also thirty-two+", .{});
    try store.write(io, a, try join(a, old, "_session_secret.previous-until"), "9999999999\n", .{});

    migrateSecret(io, a);

    // It is in auth/ now, gone from data/chat/, and read from the new place.
    try testing.expectEqualStrings(secret, try store.read(io, a, try join(a, new, "_session_secret"), .unlimited));
    for ([_][]const u8{ "_session_secret", "_session_secret.previous", "_session_secret.previous-until" }) |name| {
        try testing.expect(!try store.has(io, a, try join(a, old, name)));
        try testing.expect(try store.has(io, a, try join(a, new, name)));
    }
    try testing.expectEqualStrings(secret, (try users.sessionSecret(io, a)).?);

    // A stale copy left in the old home (a crash mid-move) is cleaned, not kept
    // beside the new one, and the new secret is untouched.
    try store.write(io, a, try join(a, old, "_session_secret"), "stale", .{});
    migrateSecret(io, a);
    try testing.expect(!try store.has(io, a, try join(a, old, "_session_secret")));
    try testing.expectEqualStrings(secret, (try users.sessionSecret(io, a)).?);
}

test "point takes the relative paths a kernel uses on its own volume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = save();
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
    const saved = save();
    defer saved.restore();

    try point(arena.allocator(), .{ .data_dir = "/srv/gopher/", .auth_dir = "/srv/auth" });
    try testing.expectEqualStrings("/srv/gopher/lynrummy", storage.data_root);
    try testing.expectEqualStrings("/srv/gopher/players", player.player_root);
}

test "point copies the auth directory rather than aliasing the caller's buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = save();
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
    const saved = save();
    defer saved.restore();

    var tiny: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    try testing.expectError(error.OutOfMemory, point(fba.allocator(), .{ .data_dir = "/srv/gopher", .auth_dir = "/a" }));
}

test "point assigns no global the list of roots does not name, and restore puts every one back (metal-vmm QUEUE 157(c))" {
    // point's own source: every `x.y =` in its body is in `all`.
    const src = @embedFile("roots.zig");
    const start = std.mem.indexOf(u8, src, "pub fn point(").?;
    const body = src[start .. start + std.mem.indexOf(u8, src[start..], "\n}\n").?];
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    var arena_names = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_names.deinit();
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
        if (std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "var ")) continue;
        try names.append(testing.allocator, line[0..eq]);
    }
    // And what store.setBases, which point calls, assigns (the review of 157:
    // the test was blind to it).
    const store_src = @embedFile("store.zig");
    const sb = std.mem.indexOf(u8, store_src, "pub fn setBases(").?;
    const sb_body = store_src[sb .. sb + std.mem.indexOf(u8, store_src[sb..], "\n}\n").?];
    var sb_lines = std.mem.splitScalar(u8, sb_body, '\n');
    while (sb_lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
        if (std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "const ")) continue;
        try names.append(testing.allocator, try std.fmt.allocPrint(arena_names.allocator(), "store.{s}", .{line[0..eq]}));
    }
    try testing.expect(names.items.len >= 8);
    // store.setBases(...) sets the last two; it is a call, and they are listed.
    for (names.items) |n| {
        var found = false;
        inline for (all) |e| {
            if (std.mem.eql(u8, n, e[0] ++ "." ++ e[2])) found = true;
        }
        if (!found) std.debug.print("point assigns {s}, which roots.all does not list\n", .{n});
        try testing.expect(found);
    }
    // And the list is what restore puts back.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const before = save();
    {
        const saved = try pointForTest(arena.allocator(), "/nowhere");
        try testing.expectEqualStrings("/nowhere/data/chat", chat_store.chat_root);
        saved.restore();
    }
    inline for (all, 0..) |e, i| {
        const was = before.values[i];
        const now = @field(e[1], e[2]);
        if (@TypeOf(was) == []const u8) try testing.expectEqualStrings(was, now) else try testing.expectEqual(was, now);
    }
}
