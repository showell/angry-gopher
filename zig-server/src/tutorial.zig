//! tutorial: /tutorial — the Lyn Rummy beginner tutorial. Public + ungated:
//! the audience is people who haven't made an account yet, so there is no
//! identity, no session, and no per-user state. The page is a free-standing
//! HTML document (games/lynrummy/tutorial/) whose figures and drag-to-meld
//! widgets are hydrated client-side by tutorial.js.
//!
//!   GET /tutorial              the document
//!   GET /tutorial/tutorial.js  the embedded client bundle

const std = @import("std");
const http = @import("http.zig");

const Request = std.http.Server.Request;

const tutorial_html = @embedFile("tutorial_html");
const tutorial_js = @embedFile("tutorial_js");

/// handle dispatches /tutorial* — `sub` is the path after "/tutorial".
pub fn handle(req: *Request, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        return req.respond(tutorial_html, .{ .extra_headers = &.{http.html_ct} });
    }
    if (std.mem.eql(u8, sub, "/tutorial.js")) {
        return req.respond(tutorial_js, .{ .extra_headers = &.{http.js_ct} });
    }
    return http.notFound(req);
}
