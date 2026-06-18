//! server: the HTTP entry point of the zig port. Listens, accepts, and routes
//! by path prefix to the per-feature handlers (driving.zig, puzzles.zig) —
//! mirroring the Go server's package-per-surface layout (server/driving,
//! server/lynrummy). build.zig is the embed.go analog (where assets are wired).
//!
//! Concurrency is the simplest thing that works: one connection at a time,
//! blocking. Fine for these static/append surfaces; the real concurrency +
//! fan-out decision is deferred until Chat's SSE forces it.
//!
//! Run:  ops/build_driving && ops/build_elm   (from repo root, for the bundles)
//!       cd zig-server && zig build run        (serves on http://localhost:9001)

const std = @import("std");
const net = std.Io.net;
const http = @import("http.zig");
const driving = @import("driving.zig");
const puzzles = @import("puzzles.zig");

const PORT: u16 = 9001;

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try net.IpAddress.parse("0.0.0.0", PORT);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("zig-server: http://localhost:{d}  (/driving, /puzzles)\n", .{PORT});

    while (true) {
        const stream = listener.accept(io) catch |e| {
            std.debug.print("accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        handleConn(io, alloc, stream) catch |e| {
            std.debug.print("connection error: {s}\n", .{@errorName(e)});
        };
    }
}

/// handleConn serves every request on one keep-alive connection until the client
/// closes it (HttpConnectionClosing) or an error ends it. A per-connection arena
/// (reset per request) backs the request-scoped allocations.
fn handleConn(io: std.Io, alloc: std.mem.Allocator, stream: net.Stream) !void {
    defer stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined; // must hold the full request header
    var write_buf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        var req = server.receiveHead() catch |e| switch (e) {
            error.HttpConnectionClosing => return,
            else => return e,
        };
        try route(&req, io, arena.allocator());
    }
}

/// route picks the handler by path prefix, passing the remainder (the path with
/// the prefix stripped, e.g. "/app.js" or "/sessions/3/..."). Mirrors the Go
/// mux's prefix dispatch; each handler owns its own sub-switch.
fn route(req: *std.http.Server.Request, io: std.Io, alloc: std.mem.Allocator) !void {
    const path = stripQuery(req.head.target);

    if (matchPrefix(path, "/driving")) |sub| {
        try driving.handle(req, sub);
    } else if (matchPrefix(path, "/puzzles")) |sub| {
        try puzzles.handle(req, io, alloc, sub);
    } else {
        try http.notFound(req);
    }
}

/// matchPrefix returns the path tail after `prefix` when `path` is exactly
/// `prefix` or `prefix` followed by '/'. Returns null otherwise — so "/drivingX"
/// does NOT match "/driving". The tail keeps its leading '/' (or is empty).
fn matchPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const tail = path[prefix.len..];
    if (tail.len == 0 or tail[0] == '/') return tail;
    return null;
}

/// stripQuery returns the target up to the first '?' (e.g. /driving/app.js?v=…).
fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}
