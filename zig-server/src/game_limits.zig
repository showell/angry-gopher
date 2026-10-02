//! game_limits: how far one player, and the game store as a whole, may grow
//! (gopher-metal QUEUE item 52; Steve, 2026-10-02: "No benign player would
//! ever possibly fill up the disk; any Lyn Rummy play that fills up disk
//! quickly is either a bot or a truly malicious entity").
//!
//! Every game write asks `admit` first, with the bytes it is about to add and
//! whether it makes a session. Past a bound the answer is a refusal, which
//! `refuse` turns into a 507 that says which bound:
//!
//!   - **per player:** `max_sessions` sessions (games and puzzles together)
//!     and `max_bytes` bytes under {data_root}/<id>. Prod's largest player,
//!     uid 1, is 75 files and 1.3 MB.
//!   - **the floor:** no game write while the data volume has less than a
//!     quarter of itself free, as the host reports it (`free_space`). Chat,
//!     accounts and uploads do not ask, so they carry on.
//!
//! **WHAT A PLAYER HOLDS IS KEPT IN MEMORY**, in a fixed table: measured by a
//! walk of their folder the first time they write after a start (or after
//! being pushed out of the table), then counted up by each write admitted. No
//! allocation lives past a request, so both hosts keep it the same way. A
//! write admitted and then failed is counted anyway: the count errs high, and
//! the next start measures afresh. A release forgets the player (`forget`).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("store.zig");
const storage = @import("storage.zig");

pub const max_sessions: u32 = 500;
pub const max_bytes: u64 = 16 << 20;

pub const Space = struct { free: u64, total: u64 };

/// The data volume's free space, as the host knows it; null (or a host that
/// sets nothing) means it cannot say, and then there is no floor. Linux asks
/// statfs; gopher-metal reads its FAT's free count.
pub var free_space: ?*const fn () ?Space = null;

/// Where the game store is, for a host asking its volume's free space.
pub fn dataRoot() []const u8 {
    return storage.data_root;
}

pub const Refusal = enum {
    sessions,
    bytes,
    floor,

    pub fn text(r: Refusal) []const u8 {
        return switch (r) {
            .sessions => std.fmt.comptimePrint("This player already keeps {d} game sessions, the most one may. Nothing was saved.\n", .{max_sessions}),
            .bytes => std.fmt.comptimePrint("This player's games already take {d} MiB, the most one may. Nothing was saved.\n", .{max_bytes >> 20}),
            .floor => "The server is low on disk, so games are not being saved for now. Nothing was saved.\n",
        };
    }
};

/// The 507 for a refusal.
pub fn refuse(req: *std.http.Server.Request, r: Refusal) !void {
    try req.respond(r.text(), .{ .status = .insufficient_storage });
}

const id_max = 24; // player.isSafeID's bound
const slots = 256;

const Usage = struct {
    id: [id_max]u8 = undefined,
    len: u8 = 0, // 0: an empty slot
    sessions: u32 = 0,
    bytes: u64 = 0,
    used: u64 = 0, // when it was last asked, by `tick`
};

var table: [slots]Usage = @splat(.{});
var tick: u64 = 0;
var mu: Io.Mutex = .init;

/// Whether `id` may add `bytes`, and a session if `new_session`; null when it
/// may, and then it is counted.
pub fn admit(io: Io, alloc: Alloc, id: []const u8, new_session: bool, bytes: u64) !?Refusal {
    if (free_space) |f| if (f()) |s| if (s.free < s.total / 4) return .floor;
    if (id.len == 0 or id.len > id_max) return .bytes; // never a player's: refuse rather than miscount
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const u = try slot(io, alloc, id);
    if (new_session and u.sessions >= max_sessions) return .sessions;
    if (u.bytes + bytes > max_bytes) return .bytes;
    if (new_session) u.sessions += 1;
    u.bytes += bytes;
    return null;
}

/// Drops what is kept for `id`: their folder has gone (a release), or changed
/// behind the table's back.
pub fn forget(io: Io, id: []const u8) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    for (&table) |*u| if (u.len != 0 and std.mem.eql(u8, u.id[0..u.len], id)) {
        u.len = 0;
    };
}

/// Forgets everyone: for a test that moves the data root.
pub fn forgetAll() void {
    table = @splat(.{});
}

/// `id`'s slot: found, or the least recently asked one measured afresh.
fn slot(io: Io, alloc: Alloc, id: []const u8) !*Usage {
    tick += 1;
    var empty: ?*Usage = null;
    var oldest: ?*Usage = null;
    for (&table) |*u| {
        if (u.len == 0) {
            if (empty == null) empty = u;
            continue;
        }
        if (std.mem.eql(u8, u.id[0..u.len], id)) {
            u.used = tick;
            return u;
        }
        if (oldest == null or u.used < oldest.?.used) oldest = u;
    }
    const victim = empty orelse oldest.?;
    const m = try measure(io, alloc, id);
    victim.* = .{ .len = @intCast(id.len), .sessions = m.sessions, .bytes = m.bytes, .used = tick };
    @memcpy(victim.id[0..id.len], id);
    return victim;
}

const Measured = struct { sessions: u32 = 0, bytes: u64 = 0 };

/// What `id` holds on disk: every file's size under their folder, and the
/// sessions in both games' `sessions` folders.
fn measure(io: Io, alloc: Alloc, id: []const u8) !Measured {
    const root = try storage.userDataDir(alloc, id);
    var m: Measured = .{};
    m.bytes = try sizeOf(io, alloc, root, 0);
    for ([_][]const u8{ "lynrummy-elm", "puzzle" }) |game| {
        const dir = try std.fs.path.join(alloc, &.{ root, game, "sessions" });
        for (try store.list(io, alloc, dir)) |e| {
            if (e.kind == .directory) m.sessions += 1;
        }
    }
    return m;
}

fn sizeOf(io: Io, alloc: Alloc, dir: []const u8, depth: u8) !u64 {
    if (depth > 8) return 0; // the store is four deep; anything deeper is not ours
    var total: u64 = 0;
    for (try store.list(io, alloc, dir)) |e| {
        const p = try std.fs.path.join(alloc, &.{ dir, e.name });
        switch (e.kind) {
            .file => total += (store.stat(io, alloc, p) catch continue).size,
            .directory => total += try sizeOf(io, alloc, p, depth + 1),
            .other => {},
        }
    }
    return total;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_space: ?Space = null;
fn testSpace() ?Space {
    return test_space;
}

test "fs: a player is measured once, counted up, and refused at each bound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = storage.data_root;
    defer storage.data_root = saved;
    storage.data_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "lynrummy" });
    forgetAll();
    defer forgetAll();

    // On disk already: two game sessions and a puzzle session, 30 bytes.
    for ([_][]const u8{ "lynrummy-elm/sessions/1/meta", "lynrummy-elm/sessions/2/meta", "puzzle/sessions/1/meta" }) |rel| {
        try store.write(io, a, try std.fs.path.join(a, &.{ storage.data_root, "p1", rel }), "0123456789", .{});
    }
    const m = try measure(io, a, "p1");
    try testing.expectEqual(@as(u32, 3), m.sessions);
    try testing.expectEqual(@as(u64, 30), m.bytes);

    // Up to the byte bound exactly, then not a byte more.
    try testing.expect((try admit(io, a, "p1", false, max_bytes - 30)) == null);
    try testing.expectEqual(Refusal.bytes, (try admit(io, a, "p1", false, 1)).?);
    try testing.expect((try admit(io, a, "p1", false, 0)) == null);
    // Another player is untouched by it.
    try testing.expect((try admit(io, a, "p2", true, 100)) == null);

    // A release forgets: measured afresh, from the disk.
    forget(io, "p1");
    try testing.expect((try admit(io, a, "p1", false, 1)) == null);

    // Sessions: up to the bound, then not one more; a write to one is still fine.
    forget(io, "p2");
    for (0..max_sessions) |_| try testing.expect((try admit(io, a, "p2", true, 0)) == null);
    try testing.expectEqual(Refusal.sessions, (try admit(io, a, "p2", true, 0)).?);
    try testing.expect((try admit(io, a, "p2", false, 10)) == null);
}

test "fs: the floor refuses every game write below a quarter free, and only then" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = storage.data_root;
    defer storage.data_root = saved;
    storage.data_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "lynrummy" });
    forgetAll();
    defer forgetAll();
    free_space = testSpace;
    defer free_space = null;

    test_space = .{ .free = 25, .total = 100 }; // exactly a quarter: allowed
    try testing.expect((try admit(io, a, "p1", true, 10)) == null);
    test_space = .{ .free = 24, .total = 100 };
    try testing.expectEqual(Refusal.floor, (try admit(io, a, "p1", false, 0)).?);
    test_space = null; // the host cannot say: no floor
    try testing.expect((try admit(io, a, "p1", false, 10)) == null);
}

test "slots: the least recently asked player is the one pushed out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = storage.data_root;
    defer storage.data_root = saved;
    storage.data_root = ".zig-cache/tmp/game-limits-nowhere"; // nobody has anything
    forgetAll();
    defer forgetAll();

    var buf: [16]u8 = undefined;
    for (0..slots) |i| _ = try admit(io, a, try std.fmt.bufPrint(&buf, "p{d}", .{i}), false, 1);
    _ = try admit(io, a, "p0", false, 1); // p0 asked again: p1 is now the oldest
    _ = try admit(io, a, "pnew", false, 1);
    var found_p0 = false;
    var found_p1 = false;
    for (table) |u| {
        if (std.mem.eql(u8, u.id[0..u.len], "p0")) found_p0 = true;
        if (std.mem.eql(u8, u.id[0..u.len], "p1")) found_p1 = true;
    }
    try testing.expect(found_p0 and !found_p1);
    for (table) |u| if (std.mem.eql(u8, u.id[0..u.len], "p0")) try testing.expectEqual(@as(u64, 2), u.bytes);
}
