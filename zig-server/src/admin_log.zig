//! admin_log: /admin/log, the host's whole log as plain text, for an agent
//! to fetch and grep (metal-vmm QUEUE 189.3). Admin-only, as /admin/host is,
//! and by the same key (`Authorization: Bearer` with the admin's API key, or
//! the admin's session); GET only, and it changes nothing.
//!
//! /admin/host is the page for a person: a summary, then the newest lines.
//! This is the rest: this boot's log as the host holds it, and the boot
//! before it where the host kept it across a restart, narrowed by the
//! filters log_view.zig reads (`since=`, `until=`, `request=`, `path=`,
//! `boot=`). It opens with header lines, each `# `, saying what it is.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const webbox = @import("webbox");
const http = webbox.http;
const host_facts = webbox.host_facts;
const log_view = webbox.log_view;
const build_options = @import("build_options");

const Request = std.http.Server.Request;

/// What a wrong filter is told, after "400": what each one takes.
const usage =
    \\The filters: since=2026-10-13T14:02 and until=... (an ISO UTC time, or any
    \\leading part of one, a year at least), request=12 (digits), path=/gopher/chat
    \\(a leading /), boot=this|before|both.
    \\
;

/// render writes the view. The caller has already checked the admin gate.
pub fn render(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method != .GET and req.head.method != .HEAD) {
        return req.respond("Only GET: this view changes nothing.\n", .{
            .status = .method_not_allowed,
            .extra_headers = &.{ http.plain_ct, .{ .name = "allow", .value = "GET, HEAD" } },
        });
    }
    const target = try http.target(req, alloc);
    const f = log_view.parseFilter(alloc, target) catch |e| switch (e) {
        error.BadFilter => return req.respond("A filter is spelled wrong. " ++ usage, .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} }),
        else => return e,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    try write(&out.writer, io, alloc, f);
    try req.respond(out.written(), .{ .extra_headers = &.{http.plain_ct} });
}

fn write(w: *std.Io.Writer, io: Io, alloc: Alloc, f: log_view.Filter) !void {
    try w.writeAll("# The host's log, for agents (metal-vmm QUEUE 189.3): lines beginning \"# \" are\n" ++
        "# this header; the rest is the log as written, its secrets taken out then.\n");
    try w.print("# the application: commit {s}\n", .{build_options.commit});
    const logs = (try host_facts.allLogs(io, alloc)) orelse {
        try w.writeAll("# This host keeps no log of its own to show here.\n");
        return;
    };
    if (logs.host_commit) |c| try w.print("# the host: commit {s}\n", .{c});
    if (logs.booted_unix) |b| try w.print("# booted {s}\n", .{try host_facts.utc(alloc, b)});
    try w.print("# filters: since={s} until={s} request={?d} path={s} boot={t}\n", .{
        f.since orelse "-", f.until orelse "-", f.request, f.path orelse "-", f.boot,
    });
    if (f.boot != .before) {
        var body: std.Io.Writer.Allocating = .init(alloc);
        const c = try log_view.writeLines(&body.writer, logs.this_boot, f);
        try w.print("# this boot: {d} bytes in {d} lines held, of {d} kept at most; {d} written before them and no longer held; the oldest timed line {s}; {d} lines below\n", .{
            logs.this_boot.len, c.lines, logs.capacity, logs.lost, c.oldest orelse "(none)", c.kept,
        });
        try w.writeAll(body.written());
    }
    if (f.boot != .this) {
        if (logs.before) |b| {
            var body: std.Io.Writer.Allocating = .init(alloc);
            const c = try log_view.writeLines(&body.writer, b.text, f);
            try w.print("# the boot before (boot {d}, kept across its restart): {d} bytes in {d} lines; the oldest timed line {s}; {d} lines below\n", .{
                b.boot, b.text.len, c.lines, c.oldest orelse "(none)", c.kept,
            });
            try w.writeAll(body.written());
        } else try w.writeAll("# the boot before: none kept (a first boot, or one that did not end on purpose)\n");
    }
}
