//! x11 — the Linux live-window layer for the native Safari renderer (the WSLg target).
//!
//! This is the per-platform shim: it owns a window and the event loop, nothing else. The
//! reusable core is raster.zig (it fills a pixel buffer) + the shared wasm geometry via
//! safari.zig; this file just shows that buffer in an X11 window and feeds key events —
//! the same ~120-line shape a Win32 (BitBlt a DIB) or Cocoa (CGImage) layer would take.
//!
//! The framebuffer is 0x00RRGGBB per pixel, which is exactly an X11 32-bit TrueColor
//! pixel (red_mask 0xFF0000, …) on a little-endian default visual — so the XImage aliases
//! the framebuffer directly, no per-pixel conversion. We XPutImage it each frame.
//!
//! We deliberately use the X-prefixed *function* forms (XDefaultScreen, XRootWindow, …)
//! rather than the DefaultScreen()-style macros, which zig's C translation can't handle.
//!
//! Built by ops/run_safari_x11 (zig build -Dwindow). Controls mirror the browser:
//! SPACE pause/resume · ↑/↓ step · J jump one intersection · Q/Esc quit.

const std = @import("std");
const safari = @import("safari");
const raster = @import("raster.zig");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

const FRAME_NS: u64 = 16_666_000; // 60 fps budget

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

const W = raster.W;
const H = raster.H;

var big_px: [raster.SW * raster.SH]u32 = undefined; // supersampled render target (anti-aliasing)
var fb_px: [W * H]u32 = undefined; // the downsampled framebuffer the XImage aliases

pub fn main() !void {
    const display = c.XOpenDisplay(null) orelse {
        std.debug.print("cannot open X display (is DISPLAY set? WSLg should set :0)\n", .{});
        return error.NoDisplay;
    };
    const screen = c.XDefaultScreen(display);
    const root = c.XRootWindow(display, screen);
    const black = c.XBlackPixel(display, screen);

    const win = c.XCreateSimpleWindow(display, root, 0, 0, W, H, 0, black, black);
    _ = c.XStoreName(display, win, "Safari Drive");
    _ = c.XSelectInput(display, win, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

    // let the window manager's close button quit us cleanly instead of an X error.
    var wm_delete = c.XInternAtom(display, "WM_DELETE_WINDOW", c.False);
    _ = c.XSetWMProtocols(display, win, &wm_delete, 1);
    _ = c.XMapWindow(display, win);

    const gc = c.XDefaultGC(display, screen);
    const visual = c.XDefaultVisual(display, screen);
    const depth: c_uint = @intCast(c.XDefaultDepth(display, screen));
    const image = c.XCreateImage(display, visual, depth, c.ZPixmap, 0, @ptrCast(&fb_px), W, H, 32, 0) orelse {
        std.debug.print("XCreateImage failed\n", .{});
        return error.NoImage;
    };

    var auto = true;
    var dirty = true; // re-render only when something changed (a step, an expose, or auto-advancing)
    var running = true;
    while (running) {
        const frame_start = nowNs();
        while (c.XPending(display) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(display, &ev);
            switch (ev.type) {
                c.KeyPress => {
                    const ks = c.XLookupKeysym(&ev.xkey, 0);
                    switch (ks) {
                        c.XK_space => auto = !auto,
                        c.XK_Up => {
                            auto = false;
                            safari.advance();
                            dirty = true;
                        },
                        c.XK_Down => {
                            auto = false;
                            safari.back();
                            dirty = true;
                        },
                        c.XK_j => { // jump one intersection: drive until the segment index changes
                            auto = false;
                            const from = safari.riderSeg();
                            var guard: usize = 0;
                            while (safari.riderSeg() == from and guard < 200000) : (guard += 1) safari.advance();
                            dirty = true;
                        },
                        c.XK_q, c.XK_Escape => running = false,
                        else => {},
                    }
                },
                c.Expose => dirty = true,
                c.ClientMessage => {
                    if (@as(c.Atom, @intCast(ev.xclient.data.l[0])) == wm_delete) running = false;
                },
                else => {},
            }
        }

        if (auto) {
            safari.advance();
            dirty = true;
        }
        if (dirty) {
            renderToFb();
            _ = c.XPutImage(display, win, gc, image, 0, 0, 0, 0, W, H);
            _ = c.XFlush(display);
            dirty = false;
        }

        // pace to the frame budget: sleep only the time LEFT after the work, not a fixed
        // amount, so motion is even regardless of render cost.
        const elapsed = nowNs() - frame_start;
        if (elapsed < FRAME_NS) _ = c.usleep(@intCast((FRAME_NS - elapsed) / 1000));
    }

    _ = c.XCloseDisplay(display);
}

// rasterize the current rider frame into the framebuffer (the same call the PNG harness
// makes, minus the file write): render supersampled, then downsample (anti-alias) to fb_px.
fn renderToFb() void {
    _ = safari.renderFrame();
    const sun = raster.SunPos{
        .visible = safari.sunVisible() == 1,
        .x = safari.sunX(),
        .y = safari.sunY(),
        .scale = safari.sunScale(),
    };
    const big = raster.Fb{ .px = &big_px, .w = raster.SW, .h = raster.SH };
    const fb = raster.Fb{ .px = &fb_px, .w = W, .h = H };
    raster.render(big, safari.frameWords(), safari.riderTilt(), safari.skyTop(), safari.skyHorizon(), sun);
    raster.downsample(big, fb);
}
