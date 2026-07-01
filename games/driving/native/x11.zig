//! x11 — the Linux live-window layer for the native Safari renderer (the WSLg target).
//!
//! This is the per-platform shim: it owns a window and the event loop, nothing else. The
//! reusable core is raster.zig (it fills a pixel buffer) + the shared wasm geometry via
//! safari.zig; this file just shows that buffer in an X11 window and feeds key events —
//! the same shape a Win32 (BitBlt a DIB) or Cocoa (CGImage) layer would take.
//!
//! The framebuffer is 0x00RRGGBB per pixel, which is exactly an X11 32-bit TrueColor
//! pixel (red_mask 0xFF0000, …) on a little-endian default visual — so the XImage aliases
//! the framebuffer directly, no per-pixel conversion. We upload it into a Pixmap and let
//! XRender composite (scale) it onto the window.
//!
//! FILLING THE SCREEN (F toggles fullscreen). The world and physics are fixed on every screen —
//! only the CAMERA flexes. We match the window's aspect by WIDENING the render (view_w), which
//! opens the horizontal field of view (more peripheral vision) with the focal FROZEN, so object
//! sizes, depth, and the sun's vertical position — the whole sunset clock — are untouched. Height
//! stays 600. Then XRender uniform-scales that aspect-matched render to fill the window:
//!   • view_w = clamp(600·aspect, 960, VIEW_W_MAX) — never below the design FOV (so nothing the
//!     scene intends to show is cropped), never so wide the edges go fish-eye;
//!   • when the window aspect lands in that band it fills EXACTLY — no bars, no distortion;
//!   • outside the band (ultra-wide, or narrower than the design 1.6) it centres and letterboxes
//!     with plain black bars. No heroics — we don't try to invent scenery for the margins.
//!
//! We deliberately use the X-prefixed *function* forms (XDefaultScreen, XRootWindow, …)
//! rather than the DefaultScreen()-style macros, which zig's C translation can't handle.
//!
//! Built by ops/run_safari_x11 (zig build -Dwindow). Controls mirror the browser:
//! SPACE pause/resume · ↑/↓ step · J jump one intersection · F fullscreen · Q/Esc quit.

const std = @import("std");
const safari = @import("safari");
const raster = @import("raster.zig");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/extensions/Xrender.h");
    @cInclude("X11/Xatom.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

const FRAME_NS: u64 = 16_666_000; // 60 fps budget
const MAX_SCALE: f64 = 2.5; // don't blow the render past this — beyond it we centre + letterbox rather than soften

const H: usize = raster.H; // 600 — frozen (vertical FOV + sunset composition never change)
const SS: usize = raster.SS; // supersample factor
const VIEW_W_MIN: usize = raster.W; // 960 — the design width; never render a NARROWER FOV than this
const VIEW_W_MAX: usize = 1280; // widest peripheral view before the sides letterbox (FOV maxes ~86°)
const SW_MAX: usize = VIEW_W_MAX * SS;
const SH: usize = H * SS;

// Static render targets, sized for the WIDEST view; a narrower view uses a dense sub-slice
// (stride = the active view_w), so no allocator and no per-resize reallocation of the big buffers.
var big_px: [SW_MAX * SH]u32 = undefined; // supersampled render target (anti-aliasing)
var fb_px: [VIEW_W_MAX * H]u32 = undefined; // the downsampled frame the XImage aliases

// XFixed is 16.16 fixed-point; XDoubleToFixed is a macro zig can't translate, so do it by hand.
fn xfixed(v: f64) c.XFixed {
    return @intFromFloat(v * 65536.0 + 0.5);
}

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

// the render width that matches this window's aspect at the fixed height, clamped to the band.
fn chooseViewW(win_w: c_uint, win_h: c_uint) usize {
    const aspect = @as(f64, @floatFromInt(win_w)) / @as(f64, @floatFromInt(win_h));
    var vw: f64 = @as(f64, H) * aspect;
    if (vw < @as(f64, VIEW_W_MIN)) vw = @as(f64, VIEW_W_MIN);
    if (vw > @as(f64, VIEW_W_MAX)) vw = @as(f64, VIEW_W_MAX);
    return @intFromFloat(@round(vw));
}

// the scaled scene's screen placement + XRender dest→source transform, for a given view width.
const Placement = struct { s: f64, off_x: f64, off_y: f64 };
fn placement(view_w: usize, win_w: c_uint, win_h: c_uint) Placement {
    const vw: f64 = @floatFromInt(view_w);
    const sw: f64 = @floatFromInt(win_w);
    const sh: f64 = @floatFromInt(win_h);
    const s = @min(@min(sw / vw, sh / @as(f64, H)), MAX_SCALE);
    return .{ .s = s, .off_x = (sw - vw * s) / 2.0, .off_y = (sh - @as(f64, H) * s) / 2.0 };
}

// Per-view-width server objects. Rebuilt only on resize (rare), not per frame: the scene Pixmap
// and its Picture are sized to the active view_w, and the XImage aliases the dense fb_px sub-slice.
const Target = struct {
    view_w: usize,
    image: *c.XImage,
    pixmap: c.Pixmap,
    src_pic: c.Picture,
};

fn buildTarget(display: ?*c.Display, root: c.Window, visual: ?*c.Visual, depth: c_uint, fmt: [*c]c.XRenderPictFormat, view_w: usize) !Target {
    safari.setViewW(@floatFromInt(view_w)); // widen the camera to match — the ONLY dynamic thing
    const vw: c_uint = @intCast(view_w);
    const image = c.XCreateImage(display, visual, depth, c.ZPixmap, 0, @ptrCast(&fb_px), vw, @intCast(H), 32, 0) orelse
        return error.NoImage;
    const pixmap = c.XCreatePixmap(display, root, vw, @intCast(H), depth);
    var attrs: c.XRenderPictureAttributes = std.mem.zeroes(c.XRenderPictureAttributes);
    attrs.repeat = c.RepeatPad; // clamp at the edges so bilinear never samples past the scene
    const src_pic = c.XRenderCreatePicture(display, pixmap, fmt, c.CPRepeat, &attrs);
    _ = c.XRenderSetPictureFilter(display, src_pic, "bilinear", null, 0); // smooth up-scale
    return .{ .view_w = view_w, .image = image, .pixmap = pixmap, .src_pic = src_pic };
}

fn freeTarget(display: ?*c.Display, t: Target) void {
    c.XRenderFreePicture(display, t.src_pic);
    _ = c.XFreePixmap(display, t.pixmap);
    t.image.*.data = null; // the pixels are our static fb_px — don't let the destructor free them
    if (t.image.*.f.destroy_image) |di| _ = di(t.image); // XDestroyImage is a macro zig can't translate
}

pub fn main() !void {
    const display = c.XOpenDisplay(null) orelse {
        std.debug.print("cannot open X display (is DISPLAY set? WSLg should set :0)\n", .{});
        return error.NoDisplay;
    };
    const screen = c.XDefaultScreen(display);
    const root = c.XRootWindow(display, screen);
    const black = c.XBlackPixel(display, screen);

    const win = c.XCreateSimpleWindow(display, root, 0, 0, @intCast(VIEW_W_MIN), @intCast(H), 0, black, black);
    _ = c.XStoreName(display, win, "Safari Drive");
    _ = c.XSelectInput(display, win, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

    // let the window manager's close button quit us cleanly instead of an X error.
    var wm_delete = c.XInternAtom(display, "WM_DELETE_WINDOW", c.False);
    _ = c.XSetWMProtocols(display, win, &wm_delete, 1);

    // fullscreen is an EWMH window-manager state we toggle at runtime (F) via a client message.
    const net_wm_state = c.XInternAtom(display, "_NET_WM_STATE", c.False);
    const net_wm_state_fs = c.XInternAtom(display, "_NET_WM_STATE_FULLSCREEN", c.False);

    _ = c.XMapWindow(display, win);

    const gc = c.XDefaultGC(display, screen);
    const visual = c.XDefaultVisual(display, screen);
    const depth: c_uint = @intCast(c.XDefaultDepth(display, screen));
    const fmt = c.XRenderFindVisualFormat(display, visual) orelse {
        std.debug.print("XRenderFindVisualFormat failed (no RENDER extension?)\n", .{});
        return error.NoRender;
    };
    const dst_pic = c.XRenderCreatePicture(display, win, fmt, 0, null);

    var win_w: c_uint = VIEW_W_MIN;
    var win_h: c_uint = H;
    var target = try buildTarget(display, root, visual, depth, fmt, chooseViewW(win_w, win_h));

    var auto = true;
    var dirty = true; // re-render only when something changed (a step, an expose, or auto-advancing)
    var clear = true; // repaint the black letterbox bars once after a resize/expose (not every frame)
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
                        c.XK_f => { // toggle fullscreen: ask the WM to add/remove _NET_WM_STATE_FULLSCREEN
                            var xev: c.XEvent = std.mem.zeroes(c.XEvent);
                            xev.type = c.ClientMessage;
                            xev.xclient.window = win;
                            xev.xclient.message_type = net_wm_state;
                            xev.xclient.format = 32;
                            xev.xclient.data.l[0] = 2; // _NET_WM_STATE_TOGGLE
                            xev.xclient.data.l[1] = @intCast(net_wm_state_fs);
                            xev.xclient.data.l[3] = 1; // source: a normal application
                            _ = c.XSendEvent(display, root, c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &xev);
                        },
                        c.XK_q, c.XK_Escape => running = false,
                        else => {},
                    }
                },
                c.Expose => {
                    dirty = true;
                    clear = true;
                },
                c.ConfigureNotify => { // window resized (incl. entering/leaving fullscreen): re-fit
                    win_w = @intCast(ev.xconfigure.width);
                    win_h = @intCast(ev.xconfigure.height);
                    const vw = chooseViewW(win_w, win_h);
                    if (vw != target.view_w) {
                        freeTarget(display, target);
                        target = try buildTarget(display, root, visual, depth, fmt, vw);
                    }
                    dirty = true;
                    clear = true;
                },
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
            renderToFb(target.view_w);
            _ = c.XPutImage(display, target.pixmap, gc, target.image, 0, 0, 0, 0, @intCast(target.view_w), @intCast(H));
            blit(display, target.src_pic, dst_pic, target.view_w, win_w, win_h, clear);
            _ = c.XFlush(display);
            dirty = false;
            clear = false;
        }

        // pace to the frame budget: sleep only the time LEFT after the work, not a fixed
        // amount, so motion is even regardless of render cost.
        const elapsed = nowNs() - frame_start;
        if (elapsed < FRAME_NS) _ = c.usleep(@intCast((FRAME_NS - elapsed) / 1000));
    }

    freeTarget(display, target);
    c.XRenderFreePicture(display, dst_pic);
    _ = c.XCloseDisplay(display);
}

// composite the aspect-matched scene onto the window: uniform, capped scale, centred. When `clear`
// (first frame after a resize/expose) paint the black letterbox bars first; between resizes the
// scene rect is fixed, so the static bars need no per-frame repaint. The transform maps DEST pixels
// back to SOURCE (XRender's convention) and bakes in the centring offset.
fn blit(display: ?*c.Display, src_pic: c.Picture, dst_pic: c.Picture, view_w: usize, win_w: c_uint, win_h: c_uint, clear: bool) void {
    const p = placement(view_w, win_w, win_h);
    const inv = 1.0 / p.s;

    // src = ( (dst_x - off_x)/s , (dst_y - off_y)/s )
    var t: c.XTransform = std.mem.zeroes(c.XTransform);
    t.matrix[0][0] = xfixed(inv);
    t.matrix[0][2] = xfixed(-p.off_x * inv);
    t.matrix[1][1] = xfixed(inv);
    t.matrix[1][2] = xfixed(-p.off_y * inv);
    t.matrix[2][2] = xfixed(1.0);
    _ = c.XRenderSetPictureTransform(display, src_pic, &t);

    if (clear) { // black letterbox — only when the bars might be stale (resize/expose)
        var blk = c.XRenderColor{ .red = 0, .green = 0, .blue = 0, .alpha = 0xffff };
        _ = c.XRenderFillRectangle(display, c.PictOpSrc, dst_pic, &blk, 0, 0, win_w, win_h);
    }
    const rx: c_int = @intFromFloat(@round(p.off_x));
    const ry: c_int = @intFromFloat(@round(p.off_y));
    const rw: c_uint = @intFromFloat(@round(@as(f64, @floatFromInt(view_w)) * p.s));
    const rh: c_uint = @intFromFloat(@round(@as(f64, H) * p.s));
    _ = c.XRenderComposite(display, c.PictOpSrc, src_pic, 0, dst_pic, rx, ry, 0, 0, rx, ry, rw, rh);
}

// rasterize the current rider frame into the framebuffer (the same call the PNG harness makes,
// minus the file write): render supersampled at the active view width, then downsample (anti-alias).
fn renderToFb(view_w: usize) void {
    _ = safari.renderFrame();
    const sun = raster.SunPos{
        .visible = safari.sunVisible() == 1,
        .x = safari.sunX(),
        .y = safari.sunY(),
        .scale = safari.sunScale(),
    };
    const bw = view_w * SS;
    const big = raster.Fb{ .px = big_px[0 .. bw * SH], .w = bw, .h = SH };
    const fb = raster.Fb{ .px = fb_px[0 .. view_w * H], .w = view_w, .h = H };
    raster.render(big, safari.frameWords(), safari.riderTilt(), safari.skyTop(), safari.skyHorizon(), sun);
    raster.downsample(big, fb);
}
