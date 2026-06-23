//! server: the HTTP entry point of the zig port. Listens, accepts, and routes
//! by path prefix to the per-feature handlers (driving.zig, puzzles.zig). One
//! module per surface; build.zig wires the embedded assets.
//!
//! Concurrency: each accepted connection runs as its own task on the std.Io
//! thread pool (a never-awaited Io.Group + group.concurrent — see main). The
//! pool grows on demand and finished tasks self-reap, so it's effectively
//! goroutine-per-connection. This is the model chat needs (long-lived SSE
//! streams that mustn't starve other connections); bus.zig is the keyed
//! fan-out runtime those streams run on. Each connection still serves ONE
//! request then closes (keep-alive off) — that's
//! independent of concurrency and can be revisited when chat lands.
//!
//! Run:  ops/build_driving && ops/build_elm   (from repo root, for the bundles)
//!       cd zig-server && zig build run        (serves on http://localhost:9001)

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = @import("http.zig");
const config = @import("config.zig");
const driving = @import("driving.zig");
const puzzles = @import("puzzles.zig");
const game = @import("game.zig");
const chat = @import("chat.zig");
const settings = @import("settings.zig");
const learn = @import("learn.zig");
const admin = @import("admin.zig");
const home = @import("home.zig");
const blog = @import("blog.zig");
const login = @import("login.zig");
const brand = @import("brand.zig");
const edge = @import("edge.zig");
const users = @import("users.zig");
const Bus = @import("bus.zig").Bus;

const PORT: u16 = 9001;

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Point storage + identity at the live data tree (GOPHER_CONFIG). No-op
    // when unset — repo-relative defaults keep /driving working standalone.
    // (0.16 routes the OS environment through main's Init, not a global.)
    var env = try std.process.Environ.createMap(init.environ, alloc);
    defer env.deinit();
    try config.load(io, alloc, env);

    // The pub/sub fan-out shared across all connections. Lives for the process
    // lifetime; drives chat's SSE streams.
    var bus = Bus.init(io, alloc);

    const addr = try net.IpAddress.parse("0.0.0.0", PORT);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("zig-server: http://localhost:{d}  (/driving, /puzzles, /game, /chat, /channel)\n", .{PORT});

    // Each connection becomes a concurrent task in this group. We never await it
    // — the server runs forever and completed tasks self-reap (see file header).
    var conns: Io.Group = .init;
    while (true) {
        const stream = listener.accept(io) catch |e| {
            std.debug.print("accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        conns.concurrent(io, serveConn, .{ io, alloc, &bus, stream }) catch |e| {
            // Pool exhausted / concurrency unavailable: fall back to serving
            // this one inline rather than dropping it.
            std.debug.print("spawn failed ({s}); serving inline\n", .{@errorName(e)});
            serveConn(io, alloc, &bus, stream);
        };
    }
}

/// serveConn is the per-connection task body. It returns void (swallowing all
/// errors) so it coerces to the Cancelable!void that Io.Group requires.
fn serveConn(io: std.Io, alloc: std.mem.Allocator, bus: *Bus, stream: net.Stream) void {
    handleConn(io, alloc, bus, stream) catch |e| {
        std.debug.print("connection error: {s}\n", .{@errorName(e)});
    };
}

/// handleConn serves exactly ONE request, then closes the connection
/// (`connection: close`). Keep-alive is deliberately OFF: the accept loop is
/// single-threaded, so a held-open idle keep-alive connection would block it
/// while a browser's OTHER parallel connections starve in the accept backlog.
/// That deadlocked /game — its page pulls three scripts at once (engine.js,
/// elm.js, engine_glue.js), so the browser opens parallel connections; /driving
/// and /puzzles load a single script each and never tripped it. One-request-per-
/// connection keeps the simple blocking model working for every surface here.
/// Real concurrency + keep-alive (and streaming) wait for chat's SSE to force
/// the model decision — see the file header.
fn handleConn(io: std.Io, alloc: std.mem.Allocator, bus: *Bus, stream: net.Stream) !void {
    defer stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined; // must hold the full request header
    var write_buf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var req = server.receiveHead() catch |e| switch (e) {
        error.HttpConnectionClosing => return,
        // A request head larger than read_buf (16 KB). Count it (the guaranteed
        // observable, surfaced in /version) and best-effort a 431 before closing.
        // The reader/writer may be mid-stream after an oversize head, so the raw
        // write is swallowed on failure — the count is the part we rely on.
        error.HttpHeadersOversize => {
            edge.count(.header_too_large);
            sw.interface.writeAll(
                "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                    "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            sw.interface.flush() catch {};
            return;
        },
        else => return e,
    };
    req.head.keep_alive = false; // force `connection: close` without touching each handler
    try route(&req, io, arena.allocator(), bus);
}

/// route picks the handler by path prefix, passing the remainder (the path with
/// the prefix stripped, e.g. "/app.js" or "/sessions/3/...").
fn route(req: *std.http.Server.Request, io: std.Io, alloc: std.mem.Allocator, bus: *Bus) !void {
    const path = stripQuery(try http.target(req, alloc));

    if (matchPrefix(path, "/driving")) |sub| {
        try driving.handle(req, sub);
    } else if (matchPrefix(path, "/puzzles")) |sub| {
        try puzzles.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/game")) |sub| {
        try game.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/chat")) |sub| {
        try chat.handle(req, io, alloc, bus, sub);
    } else if (matchPrefix(path, "/channel")) |sub| {
        try chat.handleChannel(req, io, alloc, bus, sub);
    } else if (matchPrefix(path, "/settings")) |sub| {
        try settings.handle(req, io, alloc, bus, sub);
    } else if (matchPrefix(path, "/blog")) |sub| {
        // Public. Reading never gates; posting a comment mints a guest if needed.
        // Resolve the viewer (for the top bar + comment attribution) but never gate.
        const uid = try users.currentUserID(io, alloc, req);
        try blog.handle(req, io, alloc, bus, uid, sub);
    } else if (matchPrefix(path, "/learn")) |sub| {
        try learn.handle(req, sub);
    } else if (matchPrefix(path, "/admin")) |sub| {
        try admin.handle(req, io, alloc, sub);
    } else if (matchPrefix(path, "/login")) |sub| {
        try login.handle(req, io, alloc, bus, sub);
    } else if (std.mem.eql(u8, path, "/logout")) {
        try login.handleLogout(req, io, alloc);
    } else if (matchPrefix(path, "/images")) |sub| {
        try brand.handle(req, sub);
    } else if (std.mem.eql(u8, path, "/version")) {
        try home.handleVersion(req, alloc);
    } else if (std.mem.eql(u8, path, "/")) {
        // The site root: the launch pad. TOTALLY_PUBLIC, so resolve the viewer
        // for the top bar but never gate. The explicit-"/" check plus the
        // notFound fallthrough below means any non-"/" path 404s.
        const uid = try users.currentUserID(io, alloc, req);
        try home.handleHome(req, io, alloc, uid, path);
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
