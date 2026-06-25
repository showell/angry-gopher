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

const base_url = "http://localhost:9001";
const burst_requests = 1000; // requests fired per burst
const bursts = 4; // bursts per scenario; burst 1 is warmup (caches fill), slope measured over the rest
const leak_threshold_bpr = 1; // sustained bytes/request of growth at/above which we call it a leak

/// A Scenario is one endpoint exercise: method + path (+ optional body for POSTs).
/// Today the list is just the driving GET; POST scenarios (docs, chat) land next,
/// at which point `body` becomes a shared builder a correctness test also calls.
const Scenario = struct {
    label: []const u8,
    method: std.http.Method = .GET,
    path: []const u8,
    body: ?[]const u8 = null,
};

const scenarios = [_]Scenario{
    .{ .label = "/driving", .path = "/driving" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;

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
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = s.method,
        .payload = s.body,
        .response_writer = &sink.writer,
        .keep_alive = false,
    });
}

/// readLiveBytes fetches /debug/mem and pulls the live_bytes count out of the JSON.
/// A hand scan rather than a JSON parse — one integer field, no allocation.
fn readLiveBytes(client: *std.http.Client, gpa: std.mem.Allocator) !u64 {
    _ = gpa;
    var body_buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&body_buf);
    const res = try client.fetch(.{
        .location = .{ .url = base_url ++ "/debug/mem" },
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
