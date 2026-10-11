//! server: this site served as a Linux process. Everything a Linux host does
//! is webbox's (linux_host.zig); this is what is angry-gopher's about it: the
//! name it goes by, its environment variables (GOPHER_*, which gopher-metal's
//! judge and gates, the deploy service, the stress harness and metal-vmm's
//! plants set), the game store's floor, and the lines its setup's report
//! prints.
//!
//! Prod runs on gopher-metal, which calls the same `router.start` and
//! `router.route` with no operating system. On a Linux box the default bind
//! is every interface; a firewall keeps 9001 private and Caddy reaches it on
//! localhost, and with GOPHER_BIND=127.0.0.1 a rehearsal on real data answers
//! on loopback only.
//!
//! **KEEP-ALIVE IS OFF** (linux_host.zig serves one request a connection). It
//! was first turned off when the accept loop was single-threaded and a
//! held-open idle connection deadlocked /game's three parallel script loads;
//! connections now run concurrently, and it is still off, as gopher-metal
//! serves one request per connection too. The rules both hosts keep (one
//! handler at a time, a small body read before the turn, as gopher-metal's
//! ready.zig waits) are gopher-metal's HOST.md.
//!
//! Run:  ops/build_elm && ops/build_safari_wasm && ops/build_delivery
//!         (from the repo root, for the embedded bundles)
//!       cd zig-server && zig build run        (serves on http://localhost:9001)

const std = @import("std");
const router = @import("router.zig");
const linux_host = @import("webbox_linux").linux_host;
const free_space = @import("webbox").free_space;

pub fn main(init: std.process.Init.Minimal) !void {
    try linux_host.Server(router).run(init, .{
        .name = "zig-server",
        .env = .{
            .port = "GOPHER_PORT",
            .bind = "GOPHER_BIND",
            .config = "GOPHER_CONFIG",
            .trusted_proxy = "GOPHER_TRUSTED_PROXY",
            .keepalive_ms = "GOPHER_KEEPALIVE_MS",
        },
        .default_port = 9001,
        // Caddy, on the same machine.
        .default_trusted_proxy = "127.0.0.1",
        .default_auth_dir = "~/Auth",
        .routes_hint = "(/driving, /puzzles, /game, /chat, /channel)",
        .free_space = gameFloor,
    }, report);
}

/// The game store's floor reads the data volume's free space, at the game
/// store's folder. A test host whose data sits on a full development disk
/// turns it off, out loud: the floor is then about that disk, not about the
/// server under test.
fn gameFloor(env: *const std.process.Environ.Map) free_space.FreeSpace {
    const off = std.mem.eql(u8, env.get("GOPHER_GAME_FLOOR") orelse "", "off");
    if (off) std.debug.print("zig-server: GOPHER_GAME_FLOOR=off: game writes have no free-space floor\n", .{});
    return if (off) .unknown else .{ .reader = gameStoreSpace };
}

fn gameStoreSpace() ?free_space.Space {
    return linux_host.freeSpaceAt(router.dataRoot());
}

/// What this application's setup did (app_start.zig), said before the
/// listener opens.
fn report(started: *const router.Started) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    router.hosting.describeStart(started.app, &w) catch {};
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.buffered(), "\n"), '\n');
    while (lines.next()) |line| std.debug.print("zig-server: {s}\n", .{line});
}
