//! game_limits: how far one player, and the game store as a whole, may grow
//! (zig-metal-unikernel QUEUE item 52; Steve, 2026-10-02: "No benign player would
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
//!     quarter of itself free, as the host reports it (free_space.zig). Chat,
//!     accounts and uploads do not ask, so they carry on.
//!   - **per address, an hour:** `players_per_hour` new players (/play),
//!     `bytes_per_hour` bytes of game writes, and `resigns_per_hour` re-signs
//!     of a legacy unsigned cookie (uid_cookie.zig); past any, a 429. The address
//!     is client_address.zig's: the connection's, or, behind the trusted
//!     reverse proxy (Caddy: Linux sets 127.0.0.1, Caddy on the same machine;
//!     zig-metal-unikernel sets prod's private address), the one Caddy added. Kept
//!     in a fixed table of `addresses`; an hour after an address's first
//!     count, its counts start again, and a full table gives up its oldest.
//!
//! **WHAT A PLAYER HOLDS IS KEPT IN MEMORY**, in a fixed table: measured by a
//! walk of their folder the first time they write after a start (or after
//! being pushed out of the table), then counted up by each write admitted. No
//! allocation lives past a request, so both hosts keep it the same way. A
//! write admitted and then failed is counted anyway: the count errs high, and
//! the next start measures afresh. A release forgets the player (`forget`).

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const storage = @import("storage.zig");
const client_address = @import("webbox").client_address;
const free_space = @import("webbox").free_space;

pub const max_sessions: u32 = 500;
pub const max_bytes: u64 = 16 << 20;

pub const players_per_hour: u32 = 5;
/// Legacy gopher_uid cookies one address may have re-signed in an hour
/// (uid_cookie.zig): an owner needs one, a household a few. Without a bound,
/// one GET per id took every player not yet back, and locked the owners out
/// (zig-metal-unikernel REVIEW-signed-uid-and-limits.md, finding 1).
pub const resigns_per_hour: u32 = 3;
pub const bytes_per_hour: u64 = 20_000_000;
const hour: i64 = 60 * 60;

/// Where the game store is, for a host asking its volume's free space.
pub fn dataRoot() []const u8 {
    return storage.data_root;
}

pub const Refusal = enum {
    sessions,
    bytes,
    floor,
    address_players,
    address_bytes,
    address_resigns,

    pub fn text(r: Refusal) []const u8 {
        return switch (r) {
            .sessions => std.fmt.comptimePrint("This player already keeps {d} game sessions, the most one may. Nothing was saved.\n", .{max_sessions}),
            .bytes => std.fmt.comptimePrint("This player's games already take {d} MiB, the most one may. Nothing was saved.\n", .{max_bytes >> 20}),
            .floor => "The server is low on disk, so games are not being saved for now. Nothing was saved.\n",
            .address_players => std.fmt.comptimePrint("{d} new players have been named from this address in the last hour, the most it may. Try again later.\n", .{players_per_hour}),
            .address_resigns => std.fmt.comptimePrint("{d} old cookies have been renewed from this address in the last hour, the most it may. Try again later.\n", .{resigns_per_hour}),
            .address_bytes => std.fmt.comptimePrint("This address has saved {d} MB of games in the last hour, the most it may. Nothing was saved; try again later.\n", .{bytes_per_hour / 1_000_000}),
        };
    }
};

/// The answer to a refusal: 507 for what is held, 429 for what an address did
/// this hour.
pub fn refuse(req: *std.http.Server.Request, r: Refusal) !void {
    const status: std.http.Status = switch (r) {
        .sessions, .bytes, .floor => .insufficient_storage,
        .address_players, .address_bytes, .address_resigns => .too_many_requests,
    };
    try req.respond(r.text(), .{ .status = status });
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
// No lock on the tables: only handlers reach them, one at a time (the host's
// turn, zig-metal-unikernel HOST.md).

/// Whether `id`, from `client`, may add `bytes`, and a session if
/// `new_session`; null when it may, and then it is counted against both.
pub fn admit(io: Io, alloc: Alloc, id: []const u8, client: ?[]const u8, new_session: bool, bytes: u64) !?Refusal {
    if (free_space.read()) |s| if (s.free < s.total / 4) return .floor;
    if (id.len == 0 or id.len > id_max) return .bytes; // never a player's: refuse rather than miscount
    const u = try slot(io, alloc, id);
    if (new_session and u.sessions >= max_sessions) return .sessions;
    if (u.bytes + bytes > max_bytes) return .bytes;
    const a: ?*Seen = if (client) |c| seenSlot(c, now(io)) else null;
    if (a) |s| if (s.bytes + bytes > bytes_per_hour) return .address_bytes;
    if (new_session) u.sessions += 1;
    u.bytes += bytes;
    if (a) |s| s.bytes += bytes;
    return null;
}

/// What `admit` counted for a write that then did not happen, given back
/// (metal-vmm QUEUE 172: a first move for a session not offered was counted
/// as written).
pub fn giveBack(io: Io, alloc: Alloc, id: []const u8, client: ?[]const u8, new_session: bool, bytes: u64) !void {
    const u = try slot(io, alloc, id);
    if (new_session) u.sessions -|= 1;
    u.bytes -|= bytes;
    if (client) |c| seenSlot(c, now(io)).bytes -|= bytes;
}

/// Whether `client` may have another legacy cookie re-signed this hour; null
/// when it may, and then it is counted.
pub fn admitResign(io: Io, client: ?[]const u8) !?Refusal {
    const c = client orelse return null;
    const s = seenSlot(c, now(io));
    if (s.resigns >= resigns_per_hour) return .address_resigns;
    s.resigns += 1;
    return null;
}

/// Whether `client` may name another player this hour; null when it may, and
/// then it is counted.
pub fn admitPlayer(io: Io, client: ?[]const u8) !?Refusal {
    const c = client orelse return null;
    const s = seenSlot(c, now(io));
    if (s.players >= players_per_hour) return .address_players;
    s.players += 1;
    return null;
}

fn now(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// Drops what is kept for `id`: their folder has gone (a release), or changed
/// behind the table's back.
pub fn forget(id: []const u8) void {
    for (&table) |*u| if (u.len != 0 and std.mem.eql(u8, u.id[0..u.len], id)) {
        u.len = 0;
    };
}

/// What is counted for `id` so far, or null when nothing is: for a test that
/// holds the count to what landed (metal-vmm QUEUE 157(b)).
pub fn countedBytes(id: []const u8) ?u64 {
    for (&table) |*u| if (u.len != 0 and std.mem.eql(u8, u.id[0..u.len], id)) return u.bytes;
    return null;
}

/// **FOR A TEST: NOTHING KEPT NOW, AND NOTHING AFTER** (`defer forgot.end()`;
/// 157(e)).
pub fn forgetForTest() Forgot {
    forgetAll();
    return .{};
}

pub const Forgot = struct {
    pub fn end(_: Forgot) void {
        forgetAll();
    }
};

/// Forgets everyone, and every address: for a test that moves the data root.
pub fn forgetAll() void {
    table = @splat(.{});
    seen = @splat(.{});
}

// ── per address ──────────────────────────────────────────────────────────────

const addr_max = client_address.addr_max;
const addresses = 1024;

const Seen = struct {
    addr: [addr_max]u8 = undefined,
    len: u8 = 0, // 0: an empty slot
    since: i64 = 0, // the hour's start: its first count
    players: u32 = 0,
    resigns: u32 = 0,
    bytes: u64 = 0,
};

var seen: [addresses]Seen = @splat(.{});

/// `addr`'s counts for the hour it is in: found (and started again if its
/// hour is over), or a new slot, taken from an empty one, one whose hour is
/// over, or the one whose hour began longest ago.
fn seenSlot(addr_in: []const u8, t: i64) *Seen {
    const addr = addr_in[0..@min(addr_in.len, addr_max)];
    var free: ?*Seen = null;
    var oldest: ?*Seen = null;
    for (&seen) |*s| {
        if (s.len != 0 and std.mem.eql(u8, s.addr[0..s.len], addr)) {
            if (t - s.since >= hour) s.* = fresh(addr, t);
            return s;
        }
        if (free == null and (s.len == 0 or t - s.since >= hour)) free = s;
        if (s.len != 0 and (oldest == null or s.since < oldest.?.since)) oldest = s;
    }
    const s = free orelse oldest.?;
    s.* = fresh(addr, t);
    return s;
}

fn fresh(addr: []const u8, t: i64) Seen {
    var s: Seen = .{ .len = @intCast(addr.len), .since = t };
    @memcpy(s.addr[0..addr.len], addr);
    return s;
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
            .file => total += ((try store.statOrNull(io, alloc, p)) orelse continue).size,
            .directory => total += try sizeOf(io, alloc, p, depth + 1),
            .other => {},
        }
    }
    return total;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const roots = @import("roots.zig");

var test_space: ?free_space.Space = null;
fn testSpace() ?free_space.Space {
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
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    const forgot = forgetForTest();
    defer forgot.end();

    // On disk already: two game sessions and a puzzle session, 30 bytes.
    for ([_][]const u8{ "lynrummy-elm/sessions/1/meta", "lynrummy-elm/sessions/2/meta", "puzzle/sessions/1/meta" }) |rel| {
        try store.write(io, a, try std.fs.path.join(a, &.{ storage.data_root, "p1", rel }), "0123456789", .{});
    }
    const m = try measure(io, a, "p1");
    try testing.expectEqual(@as(u32, 3), m.sessions);
    try testing.expectEqual(@as(u64, 30), m.bytes);

    // Up to the byte bound exactly, then not a byte more.
    try testing.expect((try admit(io, a, "p1", null, false, max_bytes - 30)) == null);
    try testing.expectEqual(Refusal.bytes, (try admit(io, a, "p1", null, false, 1)).?);
    try testing.expect((try admit(io, a, "p1", null, false, 0)) == null);
    // Another player is untouched by it.
    try testing.expect((try admit(io, a, "p2", null, true, 100)) == null);

    // A release forgets: measured afresh, from the disk.
    forget("p1");
    try testing.expect((try admit(io, a, "p1", null, false, 1)) == null);

    // Sessions: up to the bound, then not one more; a write to one is still fine.
    forget("p2");
    for (0..max_sessions) |_| try testing.expect((try admit(io, a, "p2", null, true, 0)) == null);
    try testing.expectEqual(Refusal.sessions, (try admit(io, a, "p2", null, true, 0)).?);
    try testing.expect((try admit(io, a, "p2", null, false, 10)) == null);

    // An id that is no player's, empty or past id_max, is refused before
    // anything is measured or counted.
    try testing.expectEqual(Refusal.bytes, (try admit(io, a, "", null, false, 1)).?);
    try testing.expectEqual(Refusal.bytes, (try admit(io, a, "p" ++ "1" ** id_max, null, false, 1)).?);
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
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    const forgot = forgetForTest();
    defer forgot.end();
    const host_space = free_space.save();
    defer host_space.restore();
    free_space.reader = testSpace;

    test_space = .{ .free = 25, .total = 100 }; // exactly a quarter: allowed
    try testing.expect((try admit(io, a, "p1", null, true, 10)) == null);
    test_space = .{ .free = 24, .total = 100 };
    try testing.expectEqual(Refusal.floor, (try admit(io, a, "p1", null, false, 0)).?);
    test_space = null; // the host cannot say: no floor
    try testing.expect((try admit(io, a, "p1", null, false, 10)) == null);
}

test "slots: the least recently asked player is the one pushed out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = try roots.pointForTest(a, ".zig-cache/tmp/game-limits-nowhere"); // nobody has anything
    defer saved.restore();
    const forgot = forgetForTest();
    defer forgot.end();

    var buf: [16]u8 = undefined;
    for (0..slots) |i| _ = try admit(io, a, try std.fmt.bufPrint(&buf, "p{d}", .{i}), null, false, 1);
    _ = try admit(io, a, "p0", null, false, 1); // p0 asked again: p1 is now the oldest
    _ = try admit(io, a, "pnew", null, false, 1);
    var found_p0 = false;
    var found_p1 = false;
    for (table) |u| {
        if (std.mem.eql(u8, u.id[0..u.len], "p0")) found_p0 = true;
        if (std.mem.eql(u8, u.id[0..u.len], "p1")) found_p1 = true;
    }
    try testing.expect(found_p0 and !found_p1);
    for (table) |u| if (std.mem.eql(u8, u.id[0..u.len], "p0")) try testing.expectEqual(@as(u64, 2), u.bytes);
}

test "an address's hour: counted, started again after it, and the oldest given up when full" {
    const forgot = forgetForTest();
    defer forgot.end();
    const t0: i64 = 1_790_000_000;
    const s = seenSlot("203.0.113.7", t0);
    s.players = 5;
    s.bytes = 99;
    try testing.expect(seenSlot("203.0.113.7", t0 + hour - 1) == s);
    try testing.expectEqual(@as(u32, 5), s.players); // still the same hour
    _ = seenSlot("203.0.113.7", t0 + hour); // an hour on: counted afresh
    try testing.expectEqual(@as(u32, 0), s.players);
    try testing.expectEqual(@as(u64, 0), s.bytes);

    // A full table: a new address takes the slot whose hour began first.
    forgetAll();
    var buf: [32]u8 = undefined;
    for (0..addresses) |i| seenSlot(try std.fmt.bufPrint(&buf, "10.0.{d}.{d}", .{ i / 256, i % 256 }), t0 + @as(i64, @intCast(i))).players = 1;
    const newcomer = seenSlot("192.0.2.1", t0 + 2000);
    try testing.expectEqual(@as(i64, t0 + 2000), newcomer.since);
    try testing.expect(newcomer == &seen[0]); // 10.0.0.0, the first counted
    try testing.expectEqual(@as(u32, 1), seenSlot("10.0.0.1", t0 + 2000).players); // the rest kept
}
