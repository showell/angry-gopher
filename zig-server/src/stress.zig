//! stress: the leak stress harness. Hammers each endpoint over real HTTP and
//! watches /debug/mem's live_bytes across bursts. A leak climbs burst-over-burst;
//! a legitimate cache fills once then plateaus — so we judge the SLOPE, not the
//! level (see mem_meter.zig). Out-of-process and zig-native on purpose: it drives
//! the real socket + HTTP path, and the per-scenario request builders are meant to
//! be shared with correctness unit tests later (one scenario, two consumers).
//!
//! Run:
//!   ops/stress           — hunt against the running :9001 dev server
//!   ops/stress_selftest  — point it at a -Dfake_leak build; /driving MUST flag,
//!                          proving the detector before we trust the subtle endpoints
//!
//! Exit code: 0 = all clean, 1 = a leak was detected, 2 = harness/connection error.

const std = @import("std");
const Io = std.Io;

// base_url targets the server under test. The port is GOPHER_PORT (default 9001) —
// the sandbox launcher sets it to a side port so we hammer the hermetic instance,
// not the dev server. Set once in main; the request helpers read it.
var base_url_buf: [64]u8 = undefined;
var base_url: []const u8 = "http://localhost:9001";

const burst_requests = 500; // requests fired per burst
const bursts = 4; // burst 0 is warmup (caches fill); the slope is measured over bursts 1..N-1
const burst_workers = 8; // concurrent firers per burst — cuts wall-clock and stresses the concurrency paths
const leak_threshold_bpr = 1; // sustained bytes/request of growth at/above which we call it a leak

// Per-request failures during a burst, surfaced at the end — a hammer that's
// silently erroring isn't exercising anything, so we never hide it.
var hit_errors: std.atomic.Value(usize) = .init(0);

/// A Scenario is one endpoint exercise: method + path (+ optional body for POSTs).
/// `auth` scenarios carry the session cookie minted by registering at startup.
const Scenario = struct {
    label: []const u8,
    method: std.http.Method = .GET,
    path: []const u8,
    body: ?[]const u8 = null,
    auth: bool = false, // send the member session cookie (member-only surfaces)
};

// A perfectly ordinary doc body — deliberately benign so it exercises the normal
// path, not the hostile-markdown guard. POSTed to /chat/docs/save and /render.
const vanilla_doc_md =
    "# Stress Test Doc\n\nAn ordinary paragraph with a [link](https://example.com) " ++
    "and a little *emphasis*.\n\n- one\n- two\n- three\n\nThat's all.\n";

// `var` (not const) so main can patch the doc-save body once it has a real slug
// (from createDoc). The POST suspects: /save overwrites one doc in place — flat
// memory there means the autosave path truly doesn't leak (Steve's sneakiest
// attack); /new creates a doc per hit; /render is a stateless markdown render.
var scenarios = [_]Scenario{
    // Public GET surface (no auth).
    .{ .label = "/", .path = "/" },
    .{ .label = "/version", .path = "/version" },
    .{ .label = "/driving", .path = "/driving" },
    .{ .label = "/driving/app.js", .path = "/driving/app.js" },
    .{ .label = "/puzzles", .path = "/puzzles" },
    .{ .label = "/game", .path = "/game" },
    .{ .label = "/blog", .path = "/blog" },
    .{ .label = "/learn", .path = "/learn" },
    .{ .label = "/login", .path = "/login" },
    .{ .label = "/login/full", .path = "/login/full" },
    // Member-only GET surface — exercised with the session cookie. These are the
    // real leak suspects: /chat touches presence (a per-uid dupe that must plateau,
    // not climb), /chat/docs touches the reading-list cache.
    .{ .label = "/chat", .path = "/chat", .auth = true },
    .{ .label = "/chat/recent", .path = "/chat/recent", .auth = true },
    .{ .label = "/chat/images", .path = "/chat/images", .auth = true },
    .{ .label = "/chat/code", .path = "/chat/code", .auth = true },
    .{ .label = "/chat/links", .path = "/chat/links", .auth = true },
    .{ .label = "/chat/docs", .path = "/chat/docs", .auth = true },
    // Member-only POST surface (the POST hunt). Bodies built in main.
    .{ .label = "POST /chat/docs/render", .path = "/chat/docs/render", .method = .POST, .auth = true },
    .{ .label = "POST /chat/docs/save", .path = "/chat/docs/save", .method = .POST, .auth = true },
    .{ .label = "POST /chat/docs/new", .path = "/chat/docs/new", .method = .POST, .body = "title=Stress+Doc", .auth = true },
    // The chat WRITE path with NO live subscribers — publish-to-nobody allocates
    // nothing on the bus, so this isolates the append/store path. Path built in main
    // (it needs the DM pair key). The fan-out WITH subscribers is a separate pass.
    .{ .label = "POST chat send (no subscribers)", .path = "", .method = .POST, .body = chat_msg_body, .auth = true },
};

// A benign chat message (form-urlencoded: '+' = space). Plain text so it sails
// past hostileReason — a rejected message would 400 and never reach the fan-out.
const chat_msg_body = "markdown=hello+from+the+stress+harness&cid=";

// ── fan-out stress (THE risk: does a message fanned out to live subscribers get
// freed?) ────────────────────────────────────────────────────────────────────
// publish() dupes each message into each subscriber's ring (base alloc); next()
// frees it after the SSE write, close() drains the rest. We hold real SSE
// subscribers open and post into them, then close + settle and check the meter
// returned to baseline. Run per burst, so each round exercises open→push→drain→
// close in full; a leak anywhere in that chain climbs across bursts.
const fanout_subscribers = 3; // live SSE streams on the topic, fanned to per message
const fanout_posts_per_burst = 200;

// Runtime POST bodies/paths (built in main; hold for the process).
var doc_slug_buf: [128]u8 = undefined;
var save_body_buf: [2048]u8 = undefined;
var pair_buf: [80]u8 = undefined; // the DM pair key "<a>_<b>"
var send_path_buf: [160]u8 = undefined; // /chat/c/<pair>/stress/send
var stream_url_buf: [224]u8 = undefined; // full URL of /chat/c/<pair>/stress/stream
var uid_a_buf: [32]u8 = undefined;
var uid_b_buf: [32]u8 = undefined;
var cookie2_buf: [1024]u8 = undefined; // the second member's cookie (unused, but its reg mints uid B)
var fanout_send_path: []const u8 = ""; // /chat/c/<pair>/stress/send
var fanout_stream_url: []const u8 = ""; // full URL of /chat/c/<pair>/stress/stream
var render_body_buf: [2048]u8 = undefined;

// The member session cookie, minted by registering over HTTP at startup (see
// registerMember). Held process-wide; auth scenarios send it.
var cookie_buf: [1024]u8 = undefined;
var session_cookie: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    if (init.environ_map.get("GOPHER_PORT")) |s| {
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 10) catch 9001;
        base_url = std.fmt.bufPrint(&base_url_buf, "http://localhost:{d}", .{port}) catch base_url;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;

    // Register members over HTTP (the real account-creation path — zero dogfooding
    // otherwise). Two of them: StressBot is the poster/subscriber whose cookie the
    // auth scenarios carry; StressBot2 exists so they form a DM pair to post into.
    // A failed registration is fatal when anything needs auth — exit 2.
    const needs_auth = for (scenarios) |s| {
        if (s.auth) break true;
    } else false;
    if (needs_auth) {
        const bot2 = registerMember(&client, "StressBot2", &cookie2_buf, &uid_b_buf) catch |e| {
            try out.print("ERROR  register StressBot2: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(2);
        };
        const bot1 = registerMember(&client, "StressBot", &cookie_buf, &uid_a_buf) catch |e| {
            try out.print("ERROR  register StressBot: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(2);
        };
        session_cookie = bot1.cookie;

        // The canonical DM pair key (smaller numeric id first) + a topic to post
        // into, then patch the chat-send scenario's path with it.
        const pair = chatPairKey(&pair_buf, bot1.uid, bot2.uid);
        _ = postForm(&client, std.fmt.bufPrint(&send_path_buf, "/chat/c/{s}/new", .{pair}) catch unreachable, "topic=stress") catch |e| {
            try out.print("ERROR  create topic: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(2);
        };
        fanout_send_path = std.fmt.bufPrint(&send_path_buf, "/chat/c/{s}/stress/send", .{pair}) catch unreachable;
        fanout_stream_url = std.fmt.bufPrint(&stream_url_buf, "{s}/chat/c/{s}/stress/stream", .{ base_url, pair }) catch unreachable;
        for (&scenarios) |*s| {
            if (std.mem.eql(u8, s.label, "POST chat send (no subscribers)")) s.path = fanout_send_path;
        }
    }

    // Build the POST bodies: create one doc (the idempotent /save target), then
    // url-encode the vanilla markdown into the /save and /render bodies and patch
    // the scenarios that carry them.
    const needs_doc = for (scenarios) |s| {
        if (std.mem.eql(u8, s.label, "POST /chat/docs/save")) break true;
    } else false;
    if (needs_doc) {
        const slug = createDoc(&client) catch |e| {
            try out.print("ERROR  create doc: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(2);
        };
        var enc_buf: [1536]u8 = undefined;
        const enc = urlEncode(&enc_buf, vanilla_doc_md);
        const save_body = std.fmt.bufPrint(&save_body_buf, "slug={s}&body={s}", .{ slug, enc }) catch unreachable;
        const render_body = std.fmt.bufPrint(&render_body_buf, "body={s}", .{enc}) catch unreachable;
        for (&scenarios) |*s| {
            if (std.mem.eql(u8, s.label, "POST /chat/docs/save")) s.body = save_body;
            if (std.mem.eql(u8, s.label, "POST /chat/docs/render")) s.body = render_body;
        }
    }

    try out.print("stress: hammering {s} — {d} bursts x {d} requests per scenario\n", .{ base_url, bursts, burst_requests });
    try out.flush();

    var leaks: usize = 0;
    for (scenarios) |s| {
        // Sanity: the endpoint must actually answer 200 before we trust a CLEAN
        // verdict — a silent 303-to-login (auth broken) or 500 would otherwise
        // "pass" while exercising nothing.
        const st = hitStatus(&client, s) catch |e| {
            try out.print("ERROR  {s}: {s}\n", .{ s.label, @errorName(e) });
            try out.flush();
            std.process.exit(2);
        };
        // GETs must be 200; POSTs succeed with any non-error status (a save 204,
        // a create 303). A 4xx/5xx — or a GET that isn't 200 (e.g. a silent
        // 303-to-login) — means we're not exercising what we think.
        const sane = if (s.method == .POST) @intFromEnum(st) < 400 else st == .ok;
        if (!sane) {
            try out.print("ERROR  {s}: unexpected status {d}\n", .{ s.label, @intFromEnum(st) });
            try out.flush();
            std.process.exit(2);
        }
        const v = hammer(io, &client, gpa, s) catch |e| {
            try out.print("ERROR  {s}: {s}\n", .{ s.label, @errorName(e) });
            try out.flush();
            std.process.exit(2);
        };
        const verdict = if (v.leaked) "LEAK " else "CLEAN";
        try out.print(
            "{s}  {s}\tlive_bytes {d} -> {d} (delta {d} over {d} reqs, {d:.2} B/req)\n",
            .{ verdict, s.label, v.warm_bytes, v.final_bytes, v.growth, v.measured_reqs, v.bytes_per_req },
        );
        try out.flush();
        if (v.leaked) leaks += 1;
    }

    // The fan-out pass: hold real SSE subscribers open and post into them, then
    // close + settle and check the meter came back to baseline. THE risk Steve
    // flagged — the part of the system the fan-out memory lives in.
    if (needs_auth) {
        const v = hammerFanout(io, &client, gpa, fanout_stream_url, fanout_send_path) catch |e| {
            try out.print("ERROR  fanout: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(2);
        };
        const verdict = if (v.leaked) "LEAK " else "CLEAN";
        try out.print(
            "{s}  FANOUT chat send ({d} subscribers)\tlive_bytes {d} -> {d} (delta {d} over {d} msgs x {d} subs, {d:.2} B/req)\n",
            .{ verdict, fanout_subscribers, v.warm_bytes, v.final_bytes, v.growth, v.measured_reqs, fanout_subscribers, v.bytes_per_req },
        );
        try out.flush();
        if (v.leaked) leaks += 1;
    }

    const errs = hit_errors.load(.monotonic);
    if (errs > 0) {
        try out.print("WARNING: {d} request(s) errored mid-burst — verdicts are suspect\n", .{errs});
        try out.flush();
    }

    if (leaks == 0) {
        try out.writeAll("RESULT: clean\n");
        try out.flush();
        std.process.exit(0);
    }
    try out.print("RESULT: leaks detected ({d})\n", .{leaks});
    try out.flush();
    std.process.exit(1);
}

const Verdict = struct {
    warm_bytes: u64, // live_bytes after the warmup burst (caches filled)
    final_bytes: u64, // live_bytes after the final burst
    growth: i64, // final - warm (clamped at 0 below for the rate)
    measured_reqs: u64, // requests fired between the warm and final samples
    bytes_per_req: f64,
    leaked: bool,
};

/// hammer drives one scenario: warmup + measured bursts, reading the meter between
/// bursts, and judges the slope. Caches fill during burst 1, so the baseline is
/// the meter AFTER burst 1; sustained growth past that is the leak signal.
fn hammer(io: Io, client: *std.http.Client, gpa: std.mem.Allocator, s: Scenario) !Verdict {
    var warm_bytes: u64 = 0;
    var final_bytes: u64 = 0;
    var b: usize = 0;
    while (b < bursts) : (b += 1) {
        try fireBurst(io, client, s);
        const live = try readLiveBytes(client, gpa);
        if (b == 0) warm_bytes = live; // baseline: after warmup
        if (b == bursts - 1) final_bytes = live; // endpoint: after the last burst
    }

    const growth: i64 = @as(i64, @intCast(final_bytes)) - @as(i64, @intCast(warm_bytes));
    const measured_reqs: u64 = @as(u64, bursts - 1) * burst_requests;
    const bpr: f64 = if (growth > 0) @as(f64, @floatFromInt(growth)) / @as(f64, @floatFromInt(measured_reqs)) else 0;
    return .{
        .warm_bytes = warm_bytes,
        .final_bytes = final_bytes,
        .growth = growth,
        .measured_reqs = measured_reqs,
        .bytes_per_req = bpr,
        .leaked = bpr >= leak_threshold_bpr,
    };
}

/// hammerFanout is the fan-out leak hunt. Per burst: open fanout_subscribers live
/// SSE streams on the topic, post a batch of messages (each fans out to every
/// subscriber's ring), then cancel the subscribers (closing them → the server
/// drains + frees) and settle the meter. After every subscriber is gone the meter
/// must be back to baseline; a leak in push / next-free / close-drain climbs across
/// bursts. The baseline is taken after burst 0 (the topic's structures warm up).
fn hammerFanout(io: Io, client: *std.http.Client, gpa: std.mem.Allocator, stream_url: []const u8, send_path: []const u8) !Verdict {
    var warm_bytes: u64 = 0;
    var final_bytes: u64 = 0;
    var b: usize = 0;
    const send = Scenario{ .label = "fanout", .path = send_path, .method = .POST, .body = chat_msg_body, .auth = true };
    while (b < bursts) : (b += 1) {
        var ready: std.atomic.Value(u32) = .init(0);
        var stop: std.atomic.Value(bool) = .init(false);
        // io.concurrent (NOT io.async): a guaranteed separate thread. io.async runs
        // the task inline when the pool is saturated, and a drainer's blocking read
        // would then seize this thread before it could ever post the stop.
        var futs: [fanout_subscribers]Io.Future(void) = undefined;
        var n_subs: usize = 0;
        for (0..fanout_subscribers) |_| {
            futs[n_subs] = io.concurrent(drainStream, .{ client, stream_url, &ready, &stop }) catch break;
            n_subs += 1;
        }

        // Let the subscribers attach before posting (so messages actually fan out),
        // polling readiness with a meter round-trip between checks rather than a
        // tight spin. If they never attach we post anyway — fewer fan-outs, still valid.
        var tries: usize = 0;
        while (ready.load(.acquire) < n_subs and tries < 50) : (tries += 1) {
            _ = readLiveBytes(client, gpa) catch {};
        }

        // Post the batch. The drainers read concurrently, so the server's next()
        // delivers + frees each fanned-out copy in steady state.
        var i: usize = 0;
        while (i < fanout_posts_per_burst) : (i += 1) {
            hit(client, send) catch {
                _ = hit_errors.fetchAdd(1, .monotonic);
            };
        }

        // Stop the drainers: set the flag, then post ONE wake message so an idle
        // drainer's blocked read returns at once (rather than waiting out the 25s
        // keepalive) — it then sees the flag and exits. (Cancel can't interrupt a
        // blocked socket read under the threaded IO, so we stop cooperatively.)
        stop.store(true, .release);
        hit(client, send) catch {};
        for (0..n_subs) |k| futs[k].await(io);

        // The drainers closed their client sockets, but each server-side stream
        // handler only frees its (arena-held) state when it NEXT tries to write and
        // sees the dead socket — otherwise it sits in next() until the 25s keepalive.
        // So reap: post messages to wake those handlers, and read the meter once it
        // settles. Without this, closed-but-unreaped handlers (whose backlog grows
        // every burst) read as a climbing "leak" that's pure measurement lag.
        const live = try reapAndSettle(client, gpa, send);
        if (b == 0) warm_bytes = live;
        if (b == bursts - 1) final_bytes = live;
    }

    const growth: i64 = @as(i64, @intCast(final_bytes)) - @as(i64, @intCast(warm_bytes));
    const measured_reqs: u64 = @as(u64, bursts - 1) * fanout_posts_per_burst;
    const bpr: f64 = if (growth > 0) @as(f64, @floatFromInt(growth)) / @as(f64, @floatFromInt(measured_reqs)) else 0;
    return .{
        .warm_bytes = warm_bytes,
        .final_bytes = final_bytes,
        .growth = growth,
        .measured_reqs = measured_reqs,
        .bytes_per_req = bpr,
        .leaked = bpr >= leak_threshold_bpr,
    };
}

/// drainStream opens one SSE subscriber on the topic and reads (discards) it until
/// cancelled — draining the socket so the server's next() loop keeps delivering and
/// freeing each fanned-out message. Signals `ready` once subscribed (receiveHead
/// returns after openStream has registered the subscriber).
fn drainStream(client: *std.http.Client, url: []const u8, ready: *std.atomic.Value(u32), stop: *std.atomic.Value(bool)) void {
    const uri = std.Uri.parse(url) catch return;
    const extra: []const std.http.Header = if (session_cookie) |c|
        &.{.{ .name = "cookie", .value = c }}
    else
        &.{};
    var req = client.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .extra_headers = extra,
    }) catch return;
    defer req.deinit();
    req.sendBodiless() catch return;
    var resp = req.receiveHead(&.{}) catch return;
    _ = ready.fetchAdd(1, .release); // receiveHead returned ⇒ the server registered our subscriber

    // Discard frames until told to stop. During posting, frames arrive steadily so
    // discard returns often and we see `stop` promptly; the wake message covers the
    // idle case. Each frame read lets the server's next() free its ring copy.
    var tbuf: [8192]u8 = undefined;
    const reader = resp.reader(&tbuf);
    while (!stop.load(.acquire)) {
        const n = reader.discard(.limited(8192)) catch return; // connection closed → done
        if (n == 0) return;
    }
}

/// reapAndSettle drives the server to free closed-but-unreaped stream handlers,
/// then returns the settled live_bytes. Each iteration posts a message (which wakes
/// any handler blocked in next() so it writes, hits the dead socket, returns, and
/// frees) and reads the meter; once a handler is gone its key has no subscribers so
/// the post allocates nothing. Returns when the meter holds steady (5 equal reads).
fn reapAndSettle(client: *std.http.Client, gpa: std.mem.Allocator, send: Scenario) !u64 {
    var prev: u64 = 0;
    var stable: usize = 0;
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        hit(client, send) catch {}; // wake + reap any still-closing stream handler
        const cur = readLiveBytes(client, gpa) catch continue;
        if (cur == prev) {
            stable += 1;
            if (stable >= 5) return cur;
        } else {
            stable = 0;
            prev = cur;
        }
    }
    return prev;
}

/// chatPairKey builds the canonical DM key (smaller numeric id first) into `buf`.
fn chatPairKey(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    const ai = std.fmt.parseInt(i64, a, 10) catch 0;
    const bi = std.fmt.parseInt(i64, b, 10) catch 0;
    return if (ai <= bi)
        std.fmt.bufPrint(buf, "{s}_{s}", .{ a, b }) catch unreachable
    else
        std.fmt.bufPrint(buf, "{s}_{s}", .{ b, a }) catch unreachable;
}

/// postForm POSTs a form body to `path` (with the member cookie) and returns the
/// status — used for one-shot setup posts (create topic).
fn postForm(client: *std.http.Client, path: []const u8, body: []const u8) !std.http.Status {
    var scratch: [4096]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&scratch);
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, path });
    const extra: []const std.http.Header = if (session_cookie) |c|
        &.{.{ .name = "cookie", .value = c }}
    else
        &.{};
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &sink.writer,
        .extra_headers = extra,
        .keep_alive = false,
    });
    return res.status;
}

/// fireBurst fires burst_requests at the scenario, spread across burst_workers
/// concurrent firers, and waits for all of them (the barrier before the meter
/// read). Concurrency cuts wall-clock and exercises the server's per-connection
/// concurrency paths under real parallel load.
fn fireBurst(io: Io, client: *std.http.Client, s: Scenario) !void {
    var group: Io.Group = .init;
    var w: usize = 0;
    while (w < burst_workers) : (w += 1) {
        const count = burst_requests / burst_workers + @as(usize, if (w < burst_requests % burst_workers) 1 else 0);
        group.async(io, fireChunk, .{ client, s, count });
    }
    try group.await(io);
}

/// fireChunk fires `count` sequential requests on one worker. A per-request error
/// is counted (surfaced at the end) rather than aborting the burst — a dropped
/// connection mid-hammer shouldn't kill the run, but it must not vanish either.
fn fireChunk(client: *std.http.Client, s: Scenario, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        hit(client, s) catch {
            _ = hit_errors.fetchAdd(1, .monotonic);
        };
    }
}

/// hitStatus fires one request and returns the response status — the per-scenario
/// sanity probe (must be 200 before we trust a CLEAN verdict).
fn hitStatus(client: *std.http.Client, s: Scenario) !std.http.Status {
    var scratch: [4096]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&scratch);
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, s.path });
    const extra: []const std.http.Header = if (s.auth and session_cookie != null)
        &.{.{ .name = "cookie", .value = session_cookie.? }}
    else
        &.{};
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = s.method,
        .payload = s.body,
        .response_writer = &sink.writer,
        .extra_headers = extra,
        .keep_alive = false,
    });
    return res.status;
}

/// hit fires one request at the scenario's path and discards the body — we're
/// here to exercise the handler, not read it. keep_alive off mirrors the server
/// (it forces `connection: close`), so the client opens a fresh connection each
/// time rather than reusing one the server already closed.
fn hit(client: *std.http.Client, s: Scenario) !void {
    var scratch: [4096]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&scratch);
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, s.path });
    const extra: []const std.http.Header = if (s.auth and session_cookie != null)
        &.{.{ .name = "cookie", .value = session_cookie.? }}
    else
        &.{};
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = s.method,
        .payload = s.body,
        .response_writer = &sink.writer,
        .extra_headers = extra,
        .keep_alive = false,
    });
}

const Member = struct { cookie: []const u8, uid: []const u8 };

/// registerMember creates a fresh member `name` over the real /login/full POST and
/// returns its session cookie ("gopher_auth=…; gopher_uid=…", into cookie_out) plus
/// its uid (into uid_out). This exercises the register/login path — code that gets
/// zero dogfooding, since the real users ride long-lived cookies. Uses the low-level
/// request API because fetch() doesn't surface response headers (the Set-Cookie).
fn registerMember(client: *std.http.Client, name: []const u8, cookie_out: []u8, uid_out: []u8) !Member {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/login/full", .{base_url});
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled, // see the 303 + its Set-Cookie; don't follow it
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    defer req.deinit();

    var pbuf: [160]u8 = undefined;
    const payload = try std.fmt.bufPrint(&pbuf, "name={s}&password=stress-pw-123456&action=register&next=/chat", .{name});
    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    // Capture the cookies from Set-Cookie, copying into the caller buffers before
    // req.deinit frees the head buffer the values point into.
    var auth: ?[]const u8 = null;
    var uid: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        if (cookiePair(h.value, "gopher_auth")) |v| auth = v;
        if (cookiePair(h.value, "gopher_uid")) |v| uid = v;
    }
    const a = auth orelse return error.NoSessionCookie;
    const u = uid orelse return error.NoUidCookie;
    if (u.len == 0 or u.len > uid_out.len) return error.BadUidCookie;
    @memcpy(uid_out[0..u.len], u);
    const cookie = try std.fmt.bufPrint(cookie_out, "gopher_auth={s}; gopher_uid={s}", .{ a, u });

    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch {};
    return .{ .cookie = cookie, .uid = uid_out[0..u.len] };
}

/// createDoc creates one doc via POST /chat/docs/new and returns its slug (owned
/// by doc_slug_buf) — the idempotent target /chat/docs/save overwrites. Needs the
/// member cookie; reads the slug out of the 303's Location header.
fn createDoc(client: *std.http.Client) ![]const u8 {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/chat/docs/new", .{base_url});
    const uri = try std.Uri.parse(url);

    const extra: []const std.http.Header = if (session_cookie) |c|
        &.{.{ .name = "cookie", .value = c }}
    else
        &.{};
    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = extra,
    });
    defer req.deinit();

    const payload = "title=Stress+Doc";
    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    var loc: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) loc = h.value;
    }
    const l = loc orelse return error.NoLocationHeader;
    const prefix = "/chat/docs/";
    const at = std.mem.indexOf(u8, l, prefix) orelse return error.UnexpectedLocation;
    const slug = l[at + prefix.len ..];
    if (slug.len == 0 or slug.len > doc_slug_buf.len) return error.UnexpectedLocation;
    @memcpy(doc_slug_buf[0..slug.len], slug); // copy before req.deinit frees the head buffer

    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch {};
    return doc_slug_buf[0..slug.len];
}

/// urlEncode percent-encodes `s` into `buf` (form-urlencoded value): unreserved
/// bytes pass through, everything else becomes %XX. `buf` must hold up to 3*len.
fn urlEncode(buf: []u8, s: []const u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            buf[n] = c;
            n += 1;
        } else {
            buf[n] = '%';
            buf[n + 1] = hex[c >> 4];
            buf[n + 2] = hex[c & 0xf];
            n += 3;
        }
    }
    return buf[0..n];
}

/// cookiePair pulls the value of cookie `name` from one Set-Cookie header value
/// (`<name>=<value>; Path=/; HttpOnly; …`), or null if this header isn't `name`.
fn cookiePair(set_cookie: []const u8, name: []const u8) ?[]const u8 {
    const semi = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    const first = set_cookie[0..semi];
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first[0..eq], " "), name)) return null;
    return first[eq + 1 ..];
}

/// readLiveBytes fetches /debug/mem and pulls the live_bytes count out of the JSON.
/// A hand scan rather than a JSON parse — one integer field, no allocation.
fn readLiveBytes(client: *std.http.Client, gpa: std.mem.Allocator) !u64 {
    _ = gpa;
    var body_buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&body_buf);
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/debug/mem", .{base_url});
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &w,
        .keep_alive = false,
    });
    if (res.status != .ok) return error.MeterUnavailable;
    return parseLiveBytes(w.buffered());
}

/// parseLiveBytes extracts the integer value of the "live_bytes" field from a
/// /debug/mem body. Pure, so it's unit-tested without a server.
fn parseLiveBytes(body: []const u8) !u64 {
    const marker = "\"live_bytes\":";
    const at = std.mem.indexOf(u8, body, marker) orelse return error.BadMeterResponse;
    var j = at + marker.len;
    var n: u64 = 0;
    var saw_digit = false;
    while (j < body.len and body[j] >= '0' and body[j] <= '9') : (j += 1) {
        n = n * 10 + (body[j] - '0');
        saw_digit = true;
    }
    if (!saw_digit) return error.BadMeterResponse;
    return n;
}

const testing = std.testing;

test "parseLiveBytes pulls the field out of a /debug/mem body" {
    try testing.expectEqual(@as(u64, 6014), try parseLiveBytes(
        \\{"live_bytes":6014,"live_allocs":88,"total_allocs":98}
    ));
    try testing.expectEqual(@as(u64, 0), try parseLiveBytes(
        \\{"live_bytes":0,"live_allocs":0,"total_allocs":0}
    ));
    try testing.expectError(error.BadMeterResponse, parseLiveBytes("{\"other\":1}"));
}

test "urlEncode percent-encodes form values, passes unreserved through" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcABC123-_.~", urlEncode(&buf, "abcABC123-_.~"));
    try testing.expectEqualStrings("a%20b", urlEncode(&buf, "a b"));
    try testing.expectEqualStrings("x%0Ay%26z%3D", urlEncode(&buf, "x\ny&z="));
}

test "cookiePair extracts the named cookie value from a Set-Cookie header" {
    try testing.expectEqualStrings("abc.123.def", cookiePair("gopher_auth=abc.123.def; Path=/; HttpOnly; SameSite=Lax", "gopher_auth").?);
    try testing.expectEqualStrings("7", cookiePair("gopher_uid=7; Path=/; Max-Age=31536000", "gopher_uid").?);
    try testing.expect(cookiePair("gopher_uid=7; Path=/", "gopher_auth") == null);
}
