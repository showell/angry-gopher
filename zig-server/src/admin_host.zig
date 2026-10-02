//! admin_host: /admin/host — the running server, for its operator. Admin-only.
//!
//! Two halves. The APPLICATION's: its version, the commit it was built from,
//! the live-byte meter and the edge's reject counters — the same numbers the
//! public /version serves as JSON for the watchdog. And the HOST's: whatever
//! the host handed over through host_status.zig — on Linux its start time and
//! memory, on gopher-metal its volumes, clocks and counters. The page is the
//! same on both; only the second table differs.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const html = @import("html.zig");
const ui = @import("admin_ui.zig");
const home = @import("home.zig");
const mem_meter = @import("mem_meter.zig");
const edge = @import("edge.zig");
const host_status = @import("host_status.zig");
const build_options = @import("build_options");

const Request = std.http.Server.Request;

/// render writes the page. The caller has already checked the admin gate.
pub fn render(req: *Request, io: Io, alloc: Alloc) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "🐹 The running server", "/admin/host");

    const mem = mem_meter.snapshot();
    try b.appendSlice(alloc, "<h2>The application</h2>\n<table>");
    try row(&b, alloc, "version", home.version);
    try row(&b, alloc, "commit", build_options.commit);
    try row(&b, alloc, "base heap, live", try std.fmt.allocPrint(alloc, "{s} in {d} allocations", .{
        try ui.humanBytes(alloc, @intCast(mem.live_bytes)), mem.live_allocs,
    }));
    try row(&b, alloc, "base heap, allocations ever", try std.fmt.allocPrint(alloc, "{d}", .{mem.total_allocs}));
    try row(&b, alloc, "requests refused at the edge", try edge.countsText(alloc));
    try b.appendSlice(alloc, "</table>\n<h2>The host</h2>\n");

    const facts = try host_status.facts(io, alloc);
    if (facts.len == 0) {
        try b.appendSlice(alloc, "<p class=\"muted\">This host reports nothing about itself.</p>\n");
    } else {
        try b.appendSlice(alloc, "<table>");
        for (facts) |f| try row(&b, alloc, f.label, f.value);
        try b.appendSlice(alloc, "</table>\n");
    }
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

fn row(b: *std.ArrayList(u8), alloc: Alloc, label: []const u8, value: []const u8) !void {
    try b.print(alloc, "<tr><td>{s}</td><td>{s}</td></tr>", .{
        try html.htmlEscape(alloc, label), try html.htmlEscape(alloc, value),
    });
}
