//! request: **THE ONE DOOR BETWEEN A REQUEST AND THE APPLICATION.**
//!
//! A handler takes a `*Request`, never zig's `std.http.Server.Request`. What
//! it can do with one is what this file offers: the method, a response whole
//! or in parts, and (through http.zig, the edge) the target, a header, a
//! cookie, a query value and a body read up to a cap. Nothing else.
//!
//! **A NARROW DOOR IS A DECISION POINT** (Steve, 2026-10-07): the server
//! does what it does today, and anything more (a new header behaviour,
//! another way to read a body, a connection-level trick) means adding it
//! here, on purpose and in one place, rather than a handler reaching past
//! the door. It is also what the two hosts must agree on: on Linux and on
//! gopher-metal the same fields, the same limits, the same answers
//! (gopher-metal HOST.md).
//!
//! `raw` is the host's request underneath. Only the edge may touch it:
//! this file, http.zig, edge.zig and router.zig, where `route` makes the
//! Request from what the host hands it. `tools/lint_portable.py` refuses any
//! other file that names `std.http.Server.Request`.

const std = @import("std");

/// The host's request, as zig's HTTP server parses it.
pub const Raw = std.http.Server.Request;
pub const Method = std.http.Method;
/// A response's status and a header: plain data, zig's own spelling of it.
pub const Status = std.http.Status;
pub const Header = std.http.Header;

/// **WHAT A WHOLE RESPONSE MAY SAY:** a status and headers, nothing else (no
/// HTTP version, no reason phrase, no keep-alive: the host closes every
/// connection after its response). The same field names as zig's own, so a
/// handler's `.{ .status = .not_found }` reads as it always did.
pub const Options = struct {
    status: Status = .ok,
    extra_headers: []const Header = &.{},
};

/// **WHAT A RESPONSE IN PARTS MAY SAY:** headers, and whether the body ends
/// when the connection does (a live stream: no length, not chunked); otherwise
/// zig's server chunks it.
pub const StreamOptions = struct {
    extra_headers: []const Header = &.{},
    ends_with_connection: bool = false,
};
pub const BodyWriter = std.http.BodyWriter;
pub const Error = Raw.ExpectContinueError;

/// **WHAT THE HOST DOES BEFORE A RESPONSE'S FIRST BYTE** (gopher-metal
/// HOST.md, "Durability"): no response leaves before the writes ahead of it
/// are durable. Linux sets this (server.zig: a `syncfs` when the store has
/// written); gopher-metal leaves it null, since its io makes writes durable
/// before any byte is sent (`io.durable`). Called by `respond` and
/// `respondStreaming`, the only ways a response leaves.
pub var before_response: ?*const fn () void = null;

pub const Request = struct {
    raw: *Raw,

    pub fn method(r: *const Request) Method {
        return r.raw.head.method;
    }

    /// The whole response: status and headers in `options`, then `content`.
    pub fn respond(r: *Request, content: []const u8, options: Options) Error!void {
        if (before_response) |f| f();
        return r.raw.respond(content, .{ .status = options.status, .extra_headers = options.extra_headers });
    }

    /// A response written in parts (a live stream, a large download): the
    /// head now, the body through the writer this answers.
    pub fn respondStreaming(r: *Request, buffer: []u8, options: StreamOptions) Error!BodyWriter {
        if (before_response) |f| f();
        return r.raw.respondStreaming(buffer, .{ .respond_options = .{
            .extra_headers = options.extra_headers,
            .transfer_encoding = if (options.ends_with_connection) .none else null,
        } });
    }

    /// The connection closes after this response (`connection: close`).
    pub fn closeAfter(r: *Request) void {
        r.raw.head.keep_alive = false;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

var hook_calls: usize = 0;
fn countHook() void {
    hook_calls += 1;
}

test "a response, whole or in parts, calls the host's hook before it leaves" {
    hook_calls = 0;
    before_response = countHook;
    defer before_response = null;
    for (0..2) |i| {
        var reader: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nhost: x\r\n\r\n");
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var server = std.http.Server.init(&reader, &out.writer);
        var raw = try server.receiveHead();
        var req: Request = .{ .raw = &raw };
        if (i == 0) {
            try req.respond("hi", .{});
        } else {
            var buf: [64]u8 = undefined;
            var body = try req.respondStreaming(&buf, .{});
            try body.writer.writeAll("hi");
            try body.end();
        }
    }
    try testing.expectEqual(@as(usize, 2), hook_calls);
}
