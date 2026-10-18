//! admin_script: `POST /admin/script`, a signed Shale script run on the
//! live site (metal-vmm QUEUE 200). The same code on Linux and on metal.
//!
//! **TWO LOCKS, BOTH REQUIRED.** The admin's API key as `Authorization:
//! Bearer` (the key /admin/host takes; a session cookie is not enough, so no
//! page can drive this route), then the envelope's Ed25519 signature,
//! checked by Shale's script_route.zig against the public key in
//! `{auth}/shale.conf`. With no key configured the route refuses.
//!
//! **THE ANSWER IS ONE PLAIN-TEXT RESPONSE**: 200 for any run that started,
//! however it ended (what it printed, its effects, how it ended, in the
//! Linux runner's layout); 500 with the same body when its end could not be
//! logged; a 4xx with the reason when it was refused before running.
//!
//! **THE STALE STATE (the decision).** A script's changes do not pass
//! through the handlers that keep memory in step with the store. So after
//! any run that tried an effect, the store-derived state is rebuilt the way
//! start-up builds it (`app_start.refresh`: the search index from every
//! transcript, the last-message records, game usage and reading lists
//! forgotten), in the same turn, and the reply says so and how long it
//! took. Rebuilt even when every effect failed: a failed `remove_tree` may
//! have removed part of a tree. A run that tried none rebuilds nothing.
//!
//! **THE BUDGETS ARE THIS ROUTE'S** (`budgets`), smaller than Shale's
//! defaults: on metal a run holds the turn, and the whole site waits for it.
//!
//! **BACKGROUND RUNS** (metal-vmm QUEUE 222, as Dog Park's `shale.zig`): a
//! signed `mode=background` script is answered at once (202, its number) and
//! stepped a slice at a time between requests (`between`, which webbox's
//! Site hands each host); it only reads, under `background_budgets`. One at a
//! time: a second is refused while one runs; a signed `mode=kill` ends it.
//! `GET /admin/script` shows the run going, or the one that ended last, with
//! what it printed. Accepted only once a host has stepped: one that never
//! calls `between` refuses it (`no_background`) rather than leave it unrun.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const webbox = @import("webbox");
const http = webbox.http;
const shale = @import("shale");
const script = shale.script;
const script_route = shale.script_route;
const users = @import("users.zig");
const limits = @import("limits.zig");
const app_start = @import("app_start.zig");
const ui = @import("admin_ui.zig");

const Request = std.http.Server.Request;

comptime {
    // limits.zig spells the cap as a literal (tools/check_caddy_limits.py
    // reads it as Python): held here to what it stands for.
    std.debug.assert(limits.body.script == script.Budgets.default_source_bytes + script_route.header_bytes);
}

/// **A RUN FITS IN ABOUT A SECOND OF THE TURN ON THE DROPLET** (metal-vmm
/// QUEUE 200). Measured (Shale's runner, then in zig-webbox, ReleaseSafe, natively, which
/// is the guest's arithmetic): at Shale's defaults the steps are cheap, 5M
/// in 45 ms, and the step budget stops a read- or listing-heavy script
/// first; 1,000 replaces were 142 ms on Linux's page cache. On metal the
/// cost is the disk: a replace is several writes (the sibling, the rename,
/// FAT sectors, the directory), each a command to a DigitalOcean volume at
/// about a millisecond, so Shale's 1,000 changes would hold the site for
/// seconds and its 10,000 reads of files not in the page cache longer. So,
/// with each disk command taken at 1 ms: 100 changes (about 0.6 s at six
/// commands each), 500 reads (0.5 s cold, much less warm), 16 MiB read in
/// all, 2M steps (20 ms). The worst one script can do is near one budget,
/// not all four at once: a second or so. Output stays at Shale's 256 KiB.
pub const budgets: script.Budgets = .{
    .steps = 2_000_000,
    .arena_bytes = 8 * 1024 * 1024,
    .reads = 500,
    .read_bytes = 16 * 1024 * 1024,
    .changes = 100,
};

/// **A BACKGROUND RUN'S BUDGETS** (Steve, 2026-10-15): the same, but for its
/// reads. An atomic run holds up requests, so its reads stay at 500; a
/// background run only fills the gaps between them, so it may read 10,000.
/// They apply once this route sets a `backing` (metal-vmm QUEUE 216).
pub const background_budgets: script.Budgets = blk: {
    var b = budgets;
    b.reads = 10_000;
    break :blk b;
};

/// What a run prints: the turn is one at a time on both hosts, so one
/// buffer serves every run (a static one, as metal wants).
var out_buf: [script.Budgets.default_output_bytes]u8 = undefined;
/// The reply's own buffer: the output, the report and the rebuild's line.
var reply_buf: [script.Budgets.default_output_bytes + 64 * 1024]u8 = undefined;

/// Runs whose end could not be logged, since start (/admin/host).
pub var log_failures: u64 = 0;

/// Whether a host has called `between`: only then is a background run
/// accepted.
var stepped: bool = false;

/// **ONE SLICE BETWEEN REQUESTS**, for the host (webbox's `Site.between`):
/// whether the run goes on.
pub fn between(io: Io, now: i64) bool {
    stepped = true;
    return script_route.sliceBackground(io, now);
}

pub fn handle(req: *Request, io: Io, alloc: Alloc) !void {
    const uid = (try users.bearerUserID(io, alloc, req)) orelse
        return refuse(req, .unauthorized, "refused (no_bearer): the admin's API key, as Authorization: Bearer, is required\nnot run\n");
    if (!std.mem.eql(u8, uid, ui.admin_uid))
        return refuse(req, .forbidden, "refused (not_admin): that key is not the admin's\nnot run\n");
    if (req.head.method == .GET) {
        var s: std.Io.Writer = .fixed(&reply_buf);
        script_route.writeBackgroundStatus(&s) catch {};
        return req.respond(s.buffered(), .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
    }
    if (req.head.method != .POST)
        return refuse(req, .method_not_allowed, "refused (method): POST a signed script, or GET the background run's state\nnot run\n");
    const body = (try http.readLimitedBody(req, alloc, limits.body.script)) orelse return;
    const store = webbox.store;
    const data_root = store.data_base orelse return refuse(req, .service_unavailable, "refused (no_roots): this host has no data root\nnot run\n");
    const paths = try script_route.Paths.under(alloc, store.auth_base orelse users.auth_root);
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));

    var outcome = try script_route.handle(io, alloc, body, .{ .paths = paths, .data_root = data_root, .budgets = budgets, .now = now, .out = &out_buf, .background_budgets = background_budgets, .backing = if (stepped) webbox.mem_meter.base() else null });
    defer outcome.deinit();
    var w: std.Io.Writer = .fixed(&reply_buf);
    script_route.writeReply(&outcome, &w) catch {};
    switch (outcome) {
        .ran => |*r| {
            if (r.log_failed != null) log_failures += 1;
            if (r.changedStore()) app_start.describeRefresh(app_start.refresh(io, webbox.mem_meter.base()), &w) catch {};
        },
        // A background run only reads: nothing to rebuild.
        .refused, .started, .killed => {},
    }
    try req.respond(w.buffered(), .{ .status = outcome.status(), .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

fn refuse(req: *Request, status: std.http.Status, text: []const u8) !void {
    try req.respond(text, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}
