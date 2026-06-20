//! driving: serves /driving — the standalone first-person driving toy. A
//! minimal surface: no auth, no state.

const std = @import("std");
const http = @import("http.zig");

// The driving bundle, baked into the binary (wired in build.zig). Produced by
// `ops/build_driving`; gitignored build output that must exist to compile.
const app_js = @embedFile("driving_app_js");

// A near-empty shell: app.js builds its own canvas + DOM.
const page =
    "<!DOCTYPE html>\n" ++
    "<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
    "<title>Driving</title></head><body>" ++
    "<script src=\"/driving/app.js\"></script>" ++
    "</body></html>";

/// handle dispatches /driving/* — the route table, a switch on the path tail.
pub fn handle(req: *std.http.Server.Request, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try req.respond(page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/app.js")) {
        try req.respond(app_js, .{ .extra_headers = &.{http.js_ct} });
    } else {
        try http.notFound(req);
    }
}
