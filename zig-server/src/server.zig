//! server: the first real HTTP surface of the zig port — it serves /driving,
//! the standalone first-person driving toy. Chosen as the first target because
//! it's the minimal surface: no auth, no SSE, no POSTs, no runtime markdown, no
//! persistence. The whole job is to serve one HTML shell + one embedded JS
//! bundle, which isolates exactly the new axis (the HTTP runtime) from every
//! stateful subsystem. It mirrors Go's server/driving/driving.go.
//!
//! Primitives this stands up (the Go→zig analogs):
//!   //go:embed app.js          -> @embedFile (compile-time bytes in the binary)
//!   http.ListenAndServe + mux  -> std.Io.net listen/accept + std.http.Server
//!   a handler switch on path    -> the same switch, by hand (std has no router)
//!
//! Concurrency is deliberately the simplest thing that works: one connection at
//! a time, blocking. That's fine for a static toy; the real concurrency/fan-out
//! decision is deferred until Chat's SSE forces it.
//!
//! Run:  cd zig-server && ops/build_driving (from repo root first) ; zig run src/server.zig
//! Then open http://localhost:9001/driving  (9000 stays free for the Go server).

const std = @import("std");
const net = std.Io.net;

const PORT: u16 = 9001;

// The driving bundle, baked into the binary at compile time. Wired in build.zig
// as a named import (it lives outside this package dir, so @embedFile can't
// reach it by path — see build.zig, the embed.go analog). Produced by
// `ops/build_driving` (esbuild over games/driving/main.ts); gitignored build
// output that must exist before this compiles.
const driving_app_js = @embedFile("driving_app_js");

// A near-empty shell: app.js builds its own canvas + DOM (see driving.go's
// drivingPage). No CSS or markup from the server beyond the title + the script.
const driving_page =
    "<!DOCTYPE html>\n" ++
    "<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
    "<title>Driving</title></head><body>" ++
    "<script src=\"/driving/app.js\"></script>" ++
    "</body></html>";

const html_ct = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };
const js_ct = std.http.Header{ .name = "content-type", .value = "application/javascript; charset=utf-8" };

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try net.IpAddress.parse("0.0.0.0", PORT);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("zig-server: serving /driving on http://localhost:{d}/driving\n", .{PORT});

    while (true) {
        const stream = listener.accept(io) catch |e| {
            std.debug.print("accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        handleConn(io, stream) catch |e| {
            std.debug.print("connection error: {s}\n", .{@errorName(e)});
        };
    }
}

/// handleConn serves every request on one keep-alive connection until the client
/// closes it (HttpConnectionClosing) or an error ends it.
fn handleConn(io: std.Io, stream: net.Stream) !void {
    defer stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined; // must hold the full request header
    var write_buf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);
    var http_server = std.http.Server.init(&sr.interface, &sw.interface);

    while (true) {
        var req = http_server.receiveHead() catch |e| switch (e) {
            error.HttpConnectionClosing => return,
            else => return e,
        };
        try route(&req);
    }
}

/// route is the request table — a switch on the path, mirroring HandleDriving.
fn route(req: *std.http.Server.Request) !void {
    const path = stripQuery(req.head.target);

    if (std.mem.eql(u8, path, "/driving") or std.mem.eql(u8, path, "/driving/")) {
        try req.respond(driving_page, .{ .extra_headers = &.{html_ct} });
    } else if (std.mem.eql(u8, path, "/driving/app.js")) {
        try req.respond(driving_app_js, .{ .extra_headers = &.{js_ct} });
    } else {
        try req.respond("not found\n", .{ .status = .not_found });
    }
}

/// stripQuery returns the target up to the first '?' (e.g. /driving/app.js?v=…).
fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}
