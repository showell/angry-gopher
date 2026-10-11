//! host_start: **THE HOST CONTRACT AS ONE CALL** (Steve, 2026-10-10). A host
//! (Linux's server.zig, gopher-metal's kernel) says everything it supplies in
//! one `Host`, and `start` does the setup in the one right order: where the
//! data is, the session secret's move, every chat session's last-message
//! record, search's index, the host's own facts, and the game store's
//! settings. It answers the Hub and what its one-time passes did, for the host
//! to say in its own log. The hosts had each followed a numbered comment by
//! hand, in different orders, and both called a step it did not list.
//!
//! Before it: `mem_meter.init(base)`, which a host needs earlier still (its
//! own I/O and heaps are built on the metered allocator). After it, per
//! request: `route`, then serve what the request's Bus kept (bus.zig).

const std = @import("std");
const Io = std.Io;
const mem_meter = @import("mem_meter.zig");
const roots = @import("roots.zig");
const chat_store = @import("chat_store.zig");
const search_index = @import("search_index.zig");
const host_facts = @import("host_facts.zig");
const game_limits = @import("game_limits.zig");
const bus = @import("bus.zig");

/// The game store's floor: the data volume's free space as the host reads
/// it, or none, which only a test host says (its data on a development disk
/// whose fullness is no fact about the server).
pub const Floor = union(enum) {
    free_space: *const fn () ?game_limits.Space,
    none_for_a_test,
};

/// Everything a host supplies.
pub const Host = struct {
    /// Where the data and the accounts live; null is the repo-relative
    /// defaults, right for a development checkout and nothing else.
    roots: ?roots.Roots,
    floor: Floor,
    /// The reverse proxy whose X-Forwarded-For is believed, as text; null:
    /// every request is the address it came from.
    trusted_proxy: ?[]const u8,
    /// /admin/host's host half, and the host's own log; null: that page
    /// shows the application's half only.
    facts: ?host_facts.Report = null,
    log: ?host_facts.Log = null,
};

/// What `start` made and did.
pub const Started = struct {
    /// The registry chat publishes through, one per process.
    hub: bus.Hub,
    /// Chat sessions given their last-message record.
    backfilled: usize,
    /// Search's index as built, or null when it could not be (out of memory):
    /// the first search builds it, in that request.
    search: ?search_index.Stats,
    search_ms: i64,
};

/// The setup, once, before the first request. Each one-time pass reads on an
/// arena of its own over the process allocator, given back when the pass ends.
pub fn start(io: Io, host: Host) !Started {
    const base = mem_meter.base();
    if (host.roots) |r| try roots.point(base, r);
    // The session secret moves into auth/, once (QUEUE item 106).
    {
        var pass = std.heap.ArenaAllocator.init(base);
        defer pass.deinit();
        roots.migrateSecret(io, pass.allocator());
    }
    // Every chat session's last-message record, which /chat/recent reads
    // instead of every transcript in full.
    const backfilled = blk: {
        var pass = std.heap.ArenaAllocator.init(base);
        defer pass.deinit();
        break :blk chat_store.backfillAll(io, pass.allocator());
    };
    // Search's index in memory.
    const t0 = Io.Clock.now(.awake, io);
    const search = blk: {
        var pass = std.heap.ArenaAllocator.init(base);
        defer pass.deinit();
        break :blk search_index.buildAll(io, pass.allocator());
    };
    const search_ms: i64 = @intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds - t0.nanoseconds, std.time.ns_per_ms));
    if (host.facts) |f| host_facts.provide(f);
    if (host.log) |l| host_facts.provideLog(l);
    game_limits.free_space = switch (host.floor) {
        .free_space => |f| f,
        .none_for_a_test => null,
    };
    game_limits.trusted_proxy = host.trusted_proxy;
    return .{ .hub = bus.Hub.init(io, base), .backfilled = backfilled, .search = search, .search_ms = search_ms };
}
