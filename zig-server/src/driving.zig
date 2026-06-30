//! driving: serves /driving — the Safari Screensaver, a standalone first-person
//! driving toy. A minimal surface: no auth, no state.
//!
//! The official implementation is a zig→WASM core + a plain-JS blitter: zig
//! computes ALL the geometry + the perspective projection and writes a flat
//! draw-command buffer into linear memory; the blitter just fills the polygons
//! it emits (no TS, no bundler). It REPLACED an earlier pure-TypeScript client
//! (games/driving/main.ts); the .ts source is kept as the port reference +
//! lineage (see HISTORY.md), but it is no longer built or served.

const std = @import("std");
const build_options = @import("build_options");
const http = @import("http.zig");
const mem_meter = @import("mem_meter.zig");

// The Safari camera's zig→WASM core (ops/build_safari_wasm — a gitignored build
// output that must exist to compile) + its dumb plain-JS blitter (build.zig).
const safari_wasm = @embedFile("safari_wasm");
const safari_blitter_js = @embedFile("safari_blitter_js");

// A near-empty shell: the blitter builds its own canvas + DOM, then fetches +
// instantiates safari.wasm and fills the polygons zig writes.
const page =
    "<!DOCTYPE html>\n" ++
    "<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
    "<title>Safari Screensaver</title></head><body>" ++
    "<script src=\"/driving/blitter.js\"></script>" ++
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
    } else if (std.mem.eql(u8, sub, "/blitter.js")) {
        try req.respond(safari_blitter_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.eql(u8, sub, "/safari.wasm")) {
        try req.respond(safari_wasm, .{ .extra_headers = &.{http.wasm_ct} });
    } else {
        try http.notFound(req);
    }
}
