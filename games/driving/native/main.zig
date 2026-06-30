//! main — the native Safari renderer (Linux first). It reuses the EXACT same zig core the
//! WASM build does (world, rider, render, sky, paint via safari.zig — the wasm ABI module,
//! whose export fns are just normal functions when called from zig), then blits the
//! draw-command buffer with the native software rasterizer (raster.zig) instead of the
//! browser canvas. This proves "the blitting in zig" end to end with no canvas dependency.
//!
//! For now it is a headless verification harness, not a live window: it drives the full
//! 19-segment route and writes one canonical frame per segment (the segment START, like
//! the J key) to games/driving/snap/native/segNN.png — argless + deterministic, so the
//! output is a stable contact sheet to eyeball against the browser. The live fullscreen
//! window (the windowing-toolchain decision) is the next step on top of this same core.
//!
//! The output directory is created by ops/build_safari_native before this runs.

const std = @import("std");
const safari = @import("safari"); // the wasm core, added as a named module by build.zig
const raster = @import("raster.zig");
const png = @import("png.zig");

const W = 960;
const H = 600;

// the framebuffer + PNG scratch — static .bss (no allocator), like the rest of the core.
var fb_px: [W * H]u32 = undefined;
var raw_buf: [H * (1 + W * 3)]u8 = undefined; // filtered scanlines
var zlib_buf: [H * (1 + W * 3) + 1024]u8 = undefined; // deflate stream (stored blocks)
var out_buf: [H * (1 + W * 3) + 2048]u8 = undefined; // the assembled PNG file

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const fb = raster.Fb{ .px = &fb_px, .w = W, .h = H };
    const dir = "games/driving/snap/native";

    // snapshot the opening frame (start of segment 0), then drive the route and snapshot
    // each time the rider crosses into a new segment — one frame per scene.
    try snap(io, fb, dir, 0);
    var prev = safari.riderSeg();
    var guard: usize = 0;
    while (guard < 2_000_000) : (guard += 1) {
        safari.advance();
        const s = safari.riderSeg();
        if (s > prev) {
            try snap(io, fb, dir, s);
            prev = s;
        } else if (s < prev) {
            break; // the ride reset at the terminus — the whole route is captured
        }
    }
    std.debug.print("done: snapshots in {s}\n", .{dir});
}

fn snap(io: std.Io, fb: raster.Fb, dir: []const u8, seg: u32) !void {
    _ = safari.renderFrame(); // fills paint's draw buffer for the current rider state
    const sun = raster.SunPos{
        .visible = safari.sunVisible() == 1,
        .x = safari.sunX(),
        .y = safari.sunY(),
        .scale = safari.sunScale(),
    };
    raster.render(fb, safari.frameWords(), safari.riderTilt(), safari.skyTop(), safari.skyHorizon(), sun);

    const bytes = png.encode(&fb_px, W, H, &raw_buf, &zlib_buf, &out_buf);
    var namebuf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&namebuf, "{s}/seg{d:0>2}.png", .{ dir, seg });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    std.debug.print("  seg {d:0>2}  clock {d}\n", .{ seg, safari.clock() });
}
