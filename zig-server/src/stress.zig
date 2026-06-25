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
const leak_threshold_bpr = 1; // sustained bytes/request of growth at/above which we call it a leak

/// A Scenario is one endpoint exercise: method + path (+ optional body for POSTs).
/// `auth` scenarios carry the session cookie minted by registering at startup.
const Scenario = struct {
    label: []const u8,
    method: std.http.Method = .GET,
    path: []const u8,
    body: ?[]const u8 = null,
    auth: bool = false, // send the member session cookie (member-only surfaces)
};

const scenarios = [_]Scenario{
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
};

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

    // Register a member over HTTP (the real account-creation path — zero dogfooding
    // otherwise) and capture its session cookie for the auth scenarios. If any
    // scenario needs auth, a failed registration is fatal — exit 2.
    const needs_auth = for (scenarios) |s| {
        if (s.auth) break true;
    } else false;
    if (needs_auth) {
        session_cookie = registerMember(&client) catch |e| {
            try out.print("ERROR  register: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(2);
        };
    }

    try out.print("stress: hammering {s} — {d} bursts x {d} requests per scenario\n", .{ base_url, bursts, burst_requests });
    try out.flush();

    var leaks: usize = 0;
    for (scenarios) |s| {
        const v = hammer(&client, gpa, s) catch |e| {
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
fn hammer(client: *std.http.Client, gpa: std.mem.Allocator, s: Scenario) !Verdict {
    var warm_bytes: u64 = 0;
    var final_bytes: u64 = 0;
    var b: usize = 0;
    while (b < bursts) : (b += 1) {
        var i: usize = 0;
        while (i < burst_requests) : (i += 1) try hit(client, s);
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

/// registerMember creates a fresh member over the real /login/full POST and returns
/// its session cookie ("gopher_auth=…; gopher_uid=…", owned by cookie_buf). This
/// exercises the register/login path — code that gets zero dogfooding, since the
/// real users ride long-lived cookies. Uses the low-level request API because
/// fetch() doesn't surface response headers, and we need the Set-Cookie.
fn registerMember(client: *std.http.Client) ![]const u8 {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/login/full", .{base_url});
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled, // see the 303 + its Set-Cookie; don't follow it
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    defer req.deinit();

    const payload = "name=StressBot&password=stress-pw-123456&action=register&next=/chat";
    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    // Capture the cookies from Set-Cookie, copying into cookie_buf before req.deinit
    // frees the head buffer the values point into.
    var auth: ?[]const u8 = null;
    var uid: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        if (cookiePair(h.value, "gopher_auth")) |v| auth = v;
        if (cookiePair(h.value, "gopher_uid")) |v| uid = v;
    }
    const a = auth orelse return error.NoSessionCookie;
    const cookie = try std.fmt.bufPrint(&cookie_buf, "gopher_auth={s}; gopher_uid={s}", .{ a, uid orelse "" });

    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch {};
    return cookie;
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

test "cookiePair extracts the named cookie value from a Set-Cookie header" {
    try testing.expectEqualStrings("abc.123.def", cookiePair("gopher_auth=abc.123.def; Path=/; HttpOnly; SameSite=Lax", "gopher_auth").?);
    try testing.expectEqualStrings("7", cookiePair("gopher_uid=7; Path=/; Max-Age=31536000", "gopher_uid").?);
    try testing.expect(cookiePair("gopher_uid=7; Path=/", "gopher_auth") == null);
}
