//! app_start: what this application does once, before its first request:
//! its `setup` for webbox's `Site` (site.zig), which calls it from `start`
//! after pointing the store at the host's roots and before the host's facts,
//! free space, proxy and Hub. In this order: every store pointed at its
//! folder under the roots, the session secret's move, every chat session's
//! last-message record, and search's index. Each one-time pass reads on an
//! arena of its own over the process allocator, given back when it ends.

const std = @import("std");
const Io = @import("host_io").Io;
const roots = @import("roots.zig");
const chat_store = @import("chat_store.zig");
const search_index = @import("search_index.zig");

/// What the setup did, for the host to say in its own log.
pub const StartReport = struct {
    /// Chat sessions given their last-message record.
    backfilled: usize,
    /// Search's index as built, or null when it could not be (out of memory):
    /// the first search builds it, in that request.
    search: ?search_index.Stats,
    search_ms: i64,
};

/// **WHAT THE SETUP DID, IN WORDS**, a line each, for a host to say in its
/// log with its own prefix: the same lines on every host.
pub fn describeStart(r: StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (r.backfilled > 0) try w.print("wrote a last-message record for {d} chat session(s)\n", .{r.backfilled});
    if (r.search) |st| {
        try w.print("search index: {d} messages in {d} transcripts ({d} bytes, {d} words, {d} unreadable) in {d} ms\n", .{ st.messages, st.transcripts, st.bytes, st.words, st.unreadable, r.search_ms });
    } else try w.writeAll("search index: not built (out of memory); the first search builds it\n");
}

pub fn setup(io: Io, base: std.mem.Allocator, host_roots: ?roots.Roots) !StartReport {
    if (host_roots) |r| try roots.point(base, r);
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
    return .{ .backfilled = backfilled, .search = search, .search_ms = search_ms };
}
