//! prof — a deterministic per-phase profiler for the native renderer's hot path.
//!
//! The live X11 frame is ~30ms at SS=2 and we want to know WHERE it goes, without
//! polluting the hot path with timer globals (that swapped-label mistake once pointed me
//! at the wrong phase entirely). So this is a separate target: it drives the same 19-scene
//! route the PNG harness does and, for each scene, times the three render sub-phases
//! (drawBackground, drawSun, walk) plus downsample IN ISOLATION over many iterations,
//! reporting the average ms each. The phases are the same public functions render() calls,
//! so the numbers reflect the real cost — just attributed.
//!
//! Built + run by ops/prof_safari_native. Argless + deterministic, like the harness.

const std = @import("std");
const raster = @import("raster.zig");
const safari = @import("safari");

const W = raster.W;
const H = raster.H;
const ITERS = 20; // averaged per phase per scene — enough to settle, keeps total runtime sane

var big_px: [raster.SW * raster.SH]u32 = undefined;
var disp_px: [W * H]u32 = undefined;

const Phase = struct { bg: f64, sun: f64, walk: f64, down: f64, sun_vis: bool };

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const stdout = std.debug;
    stdout.print("phase profile  (SS={d}, {d}x{d} -> {d}x{d}, {d} iters/phase, ms)\n", .{ raster.SS, raster.SW, raster.SH, W, H, ITERS });
    stdout.print("seg   bg    sun   walk  down  | render(bg+sun+walk)\n", .{});

    var worst_seg: u32 = 0;
    var worst_render: f64 = 0;

    var seg: u32 = 0;
    const p0 = profileSeg(io);
    report(0, p0, &worst_seg, &worst_render);
    var prev = safari.riderSeg();
    var guard: usize = 0;
    while (guard < 2_000_000) : (guard += 1) {
        safari.advance();
        const s = safari.riderSeg();
        if (s > prev) {
            seg = s;
            const p = profileSeg(io);
            report(seg, p, &worst_seg, &worst_render);
            prev = s;
        } else if (s < prev) break; // route reset at the terminus
    }

    stdout.print("\nworst scene: seg {d:0>2}  render = {d:.1} ms  ({d:.0} fps cap)\n", .{ worst_seg, worst_render, 1000.0 / worst_render });
}

// time each render sub-phase of the CURRENT rider frame in isolation.
fn profileSeg(io: std.Io) Phase {
    _ = safari.renderFrame();
    const sun = raster.SunPos{
        .visible = safari.sunVisible() == 1,
        .x = safari.sunX(),
        .y = safari.sunY(),
        .scale = safari.sunScale(),
    };
    const big = raster.Fb{ .px = &big_px, .w = raster.SW, .h = raster.SH };
    const disp = raster.Fb{ .px = &disp_px, .w = W, .h = H };
    const roll = raster.rollFor(big, safari.riderTilt());
    const words = safari.frameWords();
    const top = safari.skyTop();
    const horizon = safari.skyHorizon();

    return .{
        .bg = avgMs(io, struct {
            fn run(b: raster.Fb, r: raster.Roll, t: u32, h: u32) void {
                raster.drawBackground(b, r, t, h);
            }
        }.run, .{ big, roll, top, horizon }),
        .sun = if (sun.visible) avgMs(io, struct {
            fn run(b: raster.Fb, r: raster.Roll, s: raster.SunPos) void {
                raster.drawSun(b, r, s);
            }
        }.run, .{ big, roll, sun }) else 0,
        .walk = avgMs(io, struct {
            fn run(b: raster.Fb, r: raster.Roll, wds: []const u32) void {
                raster.walk(b, r, wds);
            }
        }.run, .{ big, roll, words }),
        .down = avgMs(io, struct {
            fn run(s: raster.Fb, d: raster.Fb) void {
                raster.downsample(s, d);
            }
        }.run, .{ big, disp }),
        .sun_vis = sun.visible,
    };
}

// run `f(args...)` ITERS times, return the average wall-clock in ms. A volatile sink on the
// buffer keeps the optimizer from hoisting the calls out as dead.
fn avgMs(io: std.Io, comptime f: anytype, args: anytype) f64 {
    const t0 = std.Io.Timestamp.now(io, .awake);
    var i: usize = 0;
    while (i < ITERS) : (i += 1) @call(.auto, f, args);
    std.mem.doNotOptimizeAway(big_px[0]);
    const t1 = std.Io.Timestamp.now(io, .awake);
    const ns: i96 = t1.toNanoseconds() - t0.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / @as(f64, ITERS) / 1_000_000.0;
}

fn report(seg: u32, p: Phase, worst_seg: *u32, worst_render: *f64) void {
    const render_ms = p.bg + p.sun + p.walk;
    std.debug.print("{d:0>2}  {d:5.1} {d:5.1} {d:5.1} {d:5.1}  | {d:5.1}{s}\n", .{
        seg, p.bg, p.sun, p.walk, p.down, render_ms, if (p.sun_vis) " (sun)" else "",
    });
    if (render_ms > worst_render.*) {
        worst_render.* = render_ms;
        worst_seg.* = seg;
    }
}
