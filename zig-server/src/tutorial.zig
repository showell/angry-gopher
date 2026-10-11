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

/// **THE DOCUMENT AROUND ITS ONE SCRIPT TAG**, cut at compile time: the
/// handler puts the tag back naming the script by its bytes. A document
/// without the tag, exactly once, does not build.
const script_tag = "<script src=\"/tutorial/tutorial.js\"></script>";
const tag_at = blk: {
    @setEvalBranchQuota(1_000_000);
    const at = std.mem.indexOf(u8, tutorial_html, script_tag) orelse @compileError("tutorial.html names no " ++ script_tag);
    if (std.mem.indexOfPos(u8, tutorial_html, at + 1, script_tag) != null) @compileError("tutorial.html names " ++ script_tag ++ " twice");
    break :blk at;
};
const tutorial_before = tutorial_html[0..tag_at];
const tutorial_after = tutorial_html[tag_at + script_tag.len ..];

/// handle dispatches /tutorial* — `sub` is the path after "/tutorial".
pub fn handle(req: *Request, alloc: std.mem.Allocator, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        const body = try std.mem.concat(alloc, u8, &.{ tutorial_before, try http.scriptTag(alloc, "/tutorial/tutorial.js", tutorial_js), tutorial_after });
        return req.respond(body, .{ .extra_headers = &.{http.html_ct} });
    }
    if (std.mem.eql(u8, sub, "/tutorial.js")) {
        return http.serveEmbedded(req, tutorial_js, http.js_ct);
    }
    return http.notFound(req);
}
