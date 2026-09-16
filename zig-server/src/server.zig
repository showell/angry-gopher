//! server: HOW THIS PROCESS STARTS. The allocator, the thread pool, the
//! environment, the config file, the socket, and one request per accepted
//! connection — then it hands that request to router.zig, which is the only
//! thing here that knows what the site serves.
//!
//! That division is the whole point of the file: everything below is a Linux
//! process detail, and a machine with no operating system replaces all of it
//! while calling the same `router.route`.
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
//! Run:  ops/build_elm && ops/build_safari_wasm && ops/build_delivery
//!         (from the repo root, for the embedded bundles)
//!       cd zig-server && zig build run        (serves on http://localhost:9001)

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const router = @import("router.zig");
const config = @import("config.zig");
const edge = @import("edge.zig");
const mem_meter = @import("mem_meter.zig");
const Bus = @import("bus.zig").Bus;

const default_port: u16 = 9001;

/// portFromEnv reads GOPHER_PORT (default 9001). A port override is load-bearing
/// for running more than one server at once — e.g. the stress harness spins a
/// hermetic sandbox instance on a side port so the :9001 dev server keeps running.
fn portFromEnv(env: std.process.Environ.Map) u16 {
    const s = env.get("GOPHER_PORT") orelse return default_port;
    return std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 10) catch default_port;
}

pub fn main(init: std.process.Init.Minimal) !void {
    // The metered allocator wraps page_allocator and counts live bytes/allocs for
    // /debug/mem + /version (the leak smoke detector — see mem_meter.zig). It IS
    // the process base allocator: everything downstream (the IO pool, the bus, the
    // per-request arenas) allocates through it, so the meter sees the whole
    // leakable surface. presence/reading_list capture mem_meter.base() directly.
    const alloc = mem_meter.init(std.heap.page_allocator);
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

    const port = portFromEnv(env);
    const addr = try net.IpAddress.parse("0.0.0.0", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("zig-server: http://localhost:{d}  (/driving, /puzzles, /game, /chat, /channel)\n", .{port});

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
    try router.route(&req, io, arena.allocator(), bus);
}
