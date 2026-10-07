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
pub const RespondOptions = Raw.RespondOptions;
pub const RespondStreamingOptions = Raw.RespondStreamingOptions;
pub const BodyWriter = std.http.BodyWriter;
pub const Error = Raw.ExpectContinueError;

pub const Request = struct {
    raw: *Raw,

    pub fn method(r: *const Request) Method {
        return r.raw.head.method;
    }

    /// The whole response: status and headers in `options`, then `content`.
    pub fn respond(r: *Request, content: []const u8, options: RespondOptions) Error!void {
        return r.raw.respond(content, options);
    }

    /// A response written in parts (a live stream, a large download): the
    /// head now, the body through the writer this answers.
    pub fn respondStreaming(r: *Request, buffer: []u8, options: RespondStreamingOptions) Error!BodyWriter {
        return r.raw.respondStreaming(buffer, options);
    }

    /// The connection closes after this response (`connection: close`).
    pub fn closeAfter(r: *Request) void {
        r.raw.head.keep_alive = false;
    }
};
