//! admin_host: /admin/host — the running server, for its operator. Admin-only.
//!
//! Two halves. The APPLICATION's: its version, the commit it was built from,
//! the live-byte meter and the edge's reject counters — the same numbers the
//! public /version serves as JSON for the watchdog. And the HOST's: whatever
//! the host handed over through host_facts.zig — on Linux its start time and
//! memory, on zig-metal-unikernel its volumes, clocks and counters. The page is the
//! same on both; only the second table differs. The host hands its half over
//! because the route table must not reach for the machine (router.zig's rule).

const std = @import("std");
const operator_counts = @import("operator_counts.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("webbox").http;
const html = @import("webbox").html;
const ui = @import("admin_ui.zig");
const home = @import("home.zig");
const mem_meter = @import("webbox").mem_meter;
const edge = @import("webbox").edge;
const host_facts = @import("webbox").host_facts;
const traffic = @import("webbox").traffic;
const build_options = @import("build_options");

const Request = std.http.Server.Request;

/// render writes the page. The caller has already checked the admin gate.
pub fn render(req: *Request, io: Io, alloc: Alloc) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "🐹 The running server", "/admin/host");

    // **ERRORS FIRST, WHEN THERE ARE ANY** (metal-vmm QUEUE 189.5): every
    // answer 500 or over since boot, the newest first, with its line.
    const t = &traffic.global;
    if (t.n_errors > 0) {
        try b.print(alloc, "<h2>Errors since boot</h2>\n<p>{d} answers were 500 or over; the newest {d}, the newest first:</p>\n<pre class=\"log\">", .{
            t.n_errors, @min(t.n_errors, traffic.errors_kept),
        });
        var k: usize = 0;
        while (t.newestError(k)) |e| : (k += 1) {
            var line: std.Io.Writer.Allocating = .init(alloc);
            try traffic.writeSeen(e, &line.writer);
            try b.print(alloc, "{s}\n", .{try html.htmlEscape(alloc, line.written())});
        }
        try b.appendSlice(alloc, "</pre>\n");
    }

    const mem = mem_meter.snapshot();
    try b.appendSlice(alloc, "<h2>The application</h2>\n<table>");
    try row(&b, alloc, "version", home.version);
    try row(&b, alloc, "commit", build_options.commit);
    try row(&b, alloc, "base heap, live", try std.fmt.allocPrint(alloc, "{s} in {d} allocations", .{
        try ui.humanBytes(alloc, @intCast(mem.live_bytes)), mem.live_allocs,
    }));
    try row(&b, alloc, "base heap, allocations ever", try std.fmt.allocPrint(alloc, "{d}", .{mem.total_allocs}));
    {
        var classes: std.Io.Writer.Allocating = .init(alloc);
        try t.writeClasses(&classes.writer);
        try row(&b, alloc, "requests since boot", classes.written());
        var fams: std.Io.Writer.Allocating = .init(alloc);
        try t.writeFamilies(&fams.writer);
        try row(&b, alloc, "by part of the site", if (fams.written().len > 0) fams.written() else "none yet");
        var slow: std.Io.Writer.Allocating = .init(alloc);
        for (t.slowest[0..t.n_slowest], 0..) |*one, i| {
            if (i > 0) try slow.writer.writeAll("; ");
            try traffic.writeSeen(one, &slow.writer);
        }
        try row(&b, alloc, "the slowest", if (t.n_slowest > 0) slow.written() else "none yet");
    }
    try row(&b, alloc, "requests refused at the edge", try edge.countsText(alloc));
    for (std.enums.values(operator_counts.Kind)) |k| try row(&b, alloc, count_labels.get(k), try operator_counts.text(alloc, k));
    try b.appendSlice(alloc, "</table>\n<h2>The host</h2>\n");

    const facts = try host_facts.facts(io, alloc);
    if (facts.len == 0) {
        try b.appendSlice(alloc, "<p class=\"muted\">This host reports nothing about itself.</p>\n");
    } else {
        try b.appendSlice(alloc, "<table>");
        for (facts) |f| try row(&b, alloc, f.label, f.value);
        try b.appendSlice(alloc, "</table>\n");
    }

    // The host's own log, newest last: on zig-metal-unikernel the serial ring, its
    // secrets taken out as they were written.
    try b.appendSlice(alloc, "<h2>The log</h2>\n");
    if (try host_facts.logText(io, alloc)) |text| {
        try b.print(alloc, "<p class=\"muted\">The newest {d} lines, secrets taken out as they were written.</p>\n<pre class=\"log\">{s}</pre>\n", .{
            host_facts.log_lines, try html.htmlEscape(alloc, text),
        });
    } else {
        try b.appendSlice(alloc, "<p class=\"muted\">This host keeps no log of its own to show here.</p>\n");
    }
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// Each operator count's row, as the operator reads it.
const count_labels: std.EnumArray(operator_counts.Kind, []const u8) = .init(.{
    .dropped_announcement = "new-topic announcements the chat dropped rather than fail a page for",
    .dropped_feed_entry = "damaged feeds the chat dropped entries of rather than fail a page for",
    .dropped_recent_row = "damaged recent rows the chat dropped rather than fail a page for",
    .fanout_failure = "chat fan-out failures since boot",
    .malformed_channel = "listings that skipped a malformed channel",
    .refused_block = "reads that met a refused transcript block",
});

fn row(b: *std.ArrayList(u8), alloc: Alloc, label: []const u8, value: []const u8) !void {
    try b.print(alloc, "<tr><td>{s}</td><td>{s}</td></tr>", .{
        try html.htmlEscape(alloc, label), try html.htmlEscape(alloc, value),
    });
}
