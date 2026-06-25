//! driving: serves /driving — the standalone first-person driving toy. A
//! minimal surface: no auth, no state.

const std = @import("std");
const build_options = @import("build_options");
const http = @import("http.zig");
const mem_meter = @import("mem_meter.zig");

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
    // -Dfake_leak only: leak a few bytes per hit on the metered base allocator and
    // drop the pointer, so /debug/mem climbs ~linearly and the stress harness's
    // detector can be validated against a known leak. Compiled out of normal builds
    // entirely — driving has no allocator and no leak in prod.
    if (build_options.fake_leak) {
        if (mem_meter.base().alloc(u8, 64)) |bytes| {
            std.mem.doNotOptimizeAway(bytes.ptr); // never freed — that's the point
        } else |_| {}
    }

    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try req.respond(page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/app.js")) {
        try req.respond(app_js, .{ .extra_headers = &.{http.js_ct} });
    } else {
        try http.notFound(req);
    }
}
