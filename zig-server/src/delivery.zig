//! delivery: serves /delivery — the delivery-router sim (capacitated vehicle
//! routing over a winking, not-to-scale Seattle road network). A minimal
//! surface like /driving: no auth, no state. All logic runs client-side; the
//! server just ships the bundle.

const std = @import("std");
const http = @import("http.zig");

// The delivery bundle, baked into the binary (wired in build.zig). Produced by
// `ops/build_delivery`; gitignored build output that must exist to compile.
const app_js = @embedFile("delivery_app_js");

// A near-empty shell: app.js builds its own canvas + DOM.
const page =
    "<!DOCTYPE html>\n" ++
    "<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
    "<title>Delivery Router</title>" ++
    "<style>html,body{margin:0;height:100%;background:#0d1b2a;overflow:hidden}canvas{display:block}</style>" ++
    "</head><body>" ++
    "<script src=\"/delivery/app.js\"></script>" ++
    "</body></html>";

/// handle dispatches /delivery/* — the route table, a switch on the path tail.
pub fn handle(req: *std.http.Server.Request, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try req.respond(page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/app.js")) {
        try req.respond(app_js, .{ .extra_headers = &.{http.js_ct} });
    } else {
        try http.notFound(req);
    }
}
