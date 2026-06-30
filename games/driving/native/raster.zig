//! raster — the native software blitter. It is the zig port of blitter.js's blit() +
//! drawBackground + drawSun: it consumes the SAME draw-command buffer paint.zig fills
//! (tags 0,1,3,4,5,6) and writes RGB pixels into a framebuffer, applying the camera roll
//! (riderTilt) that the browser did with ctx.rotate(-tilt). No canvas, no allocator —
//! the platform-independent core of the Linux screensaver. A thin per-OS layer (a window
//! or a screensaver host) only has to hand us a framebuffer and call render().
//!
//! Coordinates in the buffer are DESIGN-space (what zig computed); the browser rotated
//! them via the canvas transform. We rotate each polygon vertex into screen space for the
//! scanline fill, and for gradients (whose geometry is design-space) we un-rotate each
//! filled pixel back to design space to evaluate the gradient — identical to how the
//! canvas evaluated user-space gradients under a rotated transform.

const std = @import("std");

pub const Fb = struct { px: []u32, w: usize, h: usize };
pub const SunPos = struct { visible: bool, x: f32, y: f32, scale: f32 };

const GRASS: u32 = 0x4a8f43;
const SUN_RADIUS_PX: f32 = 46.0; // matches blitter.js / sky.zig

// The design canvas (the coordinate space the draw commands live in) and the supersample
// factor. We rasterize into an SW×SH buffer and box-downsample to W×H — anti-aliasing the
// hard scanline edges (the browser canvas did this for us for free). SS is the one knob:
// higher = smoother edges + less temporal crawl, but SS² the pixel work. Callers size their
// big buffer to SW×SH and the display buffer to W×H.
pub const W: usize = 960;
pub const H: usize = 600;
pub const SS: usize = 2;
pub const SW: usize = W * SS;
pub const SH: usize = H * SS;

const Pt = struct { x: f32, y: f32 };

// per-frame transform context: DESIGN space (W×H, where the draw commands live) <-> the
// SS-supersampled PIXEL buffer, composing the camera roll (∓tilt about the design centre)
// with the ×SS scale. toPixel maps design→pixel (for rasterising vertices); toDesign maps
// pixel→design (for per-pixel gradient + background lookups, which stay in design space).
pub const Roll = struct {
    cx: f32 = @as(f32, W) / 2.0, // design centre
    cy: f32 = @as(f32, H) / 2.0,
    ct: f32, // cos(tilt)
    st: f32, // sin(tilt)
    ss: f32, // supersample scale
    inv_ss: f32, // 1/ss (multiply per pixel, never divide)

    // design point -> supersampled pixel (the canvas's R(-tilt) about centre, then ×ss).
    fn toPixel(self: Roll, dx: f32, dy: f32) Pt {
        const ex = dx - self.cx;
        const ey = dy - self.cy;
        const rx = self.cx + self.ct * ex + self.st * ey;
        const ry = self.cy - self.st * ex + self.ct * ey;
        return .{ .x = rx * self.ss, .y = ry * self.ss };
    }
    // supersampled pixel -> design point (×inv_ss, then the inverse roll R(+tilt)).
    fn toDesign(self: Roll, px: f32, py: f32) Pt {
        const ex = px * self.inv_ss - self.cx;
        const ey = py * self.inv_ss - self.cy;
        return .{ .x = self.cx + self.ct * ex - self.st * ey, .y = self.cy + self.st * ex + self.ct * ey };
    }
};

/// render fills `fb` (an SW×SH supersampled buffer) for one frame: background, sun (behind
/// the world), then every polygon command in `words` — the paint order blitter.js used.
/// Call downsample() to produce the W×H display image.
pub fn render(fb: Fb, words: []const u32, tilt: f32, sky_top: u32, sky_horizon: u32, sun: SunPos) void {
    const roll = rollFor(fb, tilt);
    drawBackground(fb, roll, sky_top, sky_horizon);
    if (sun.visible) drawSun(fb, roll, sun);
    walk(fb, roll, words);
}

// the per-frame design<->pixel transform for a given target size + camera roll. Exposed so
// the profiler (prof.zig) can drive the three render sub-phases individually.
pub fn rollFor(fb: Fb, tilt: f32) Roll {
    const ss = @as(f32, @floatFromInt(fb.w)) / @as(f32, W);
    return .{ .ct = @cos(tilt), .st = @sin(tilt), .ss = ss, .inv_ss = 1.0 / ss };
}

/// downsample box-averages each SS×SS block of `src` (SW×SH) into `dst` (W×H) — the
/// anti-aliasing resolve. dst pixels are 0x00RRGGBB, ready to blit / encode. SS is comptime
/// so the /n averaging becomes a shift (SS=2) or a magic-multiply (SS=3), not a runtime
/// integer divide — that divide was the whole frame's bottleneck (instrumented).
pub fn downsample(src: Fb, dst: Fb) void {
    const n: u32 = SS * SS; // comptime: divisor folds to a shift/magic-multiply
    var dy: usize = 0;
    while (dy < dst.h) : (dy += 1) {
        var dx: usize = 0;
        while (dx < dst.w) : (dx += 1) {
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            inline for (0..SS) |sy| {
                const row = (dy * SS + sy) * src.w + dx * SS;
                inline for (0..SS) |sx| {
                    const p = src.px[row + sx];
                    r += (p >> 16) & 0xff;
                    g += (p >> 8) & 0xff;
                    b += p & 0xff;
                }
            }
            dst.px[dy * dst.w + dx] = ((r / n) << 16) | ((g / n) << 8) | (b / n);
        }
    }
}

// ---- background: vertical sky gradient (above the design mid-line) + grass. ----
// The sky colour depends ONLY on design-Y. With no camera roll (st == 0 — the straight-
// driving case; riderTilt() snaps its sub-pixel residue to exactly 0 at the source) design-Y
// is constant across each row, so we compute one colour per row and @memset it: ~SH colour
// evals instead of SW·SH, BIT-IDENTICAL. A real turn rolls the camera and takes the per-pixel
// walk — those frames are slow + brief (the rider corners slowly), where a dropped frame is
// fine. design-Y is linear across a row, so the walk steps it incrementally, no per-px divide.
pub fn drawBackground(fb: Fb, roll: Roll, sky_top: u32, sky_horizon: u32) void {
    const half = roll.cy; // design H/2
    const inv_half = 1.0 / half;
    if (roll.st == 0.0) {
        // upright: y = (py+0.5)·inv_ss across the whole row → one colour, memset it.
        var py: usize = 0;
        while (py < fb.h) : (py += 1) {
            const y = (@as(f32, @floatFromInt(py)) + 0.5) * roll.inv_ss;
            const row = py * fb.w;
            @memset(fb.px[row .. row + fb.w], skyColor(y, half, inv_half, sky_top, sky_horizon));
        }
        return;
    }
    const delta = roll.st * roll.inv_ss; // d(design.y)/d(px)
    var py: usize = 0;
    while (py < fb.h) : (py += 1) {
        const ey = (@as(f32, @floatFromInt(py)) + 0.5) * roll.inv_ss - roll.cy;
        const row_base = roll.cy + roll.ct * ey - roll.st * roll.cx; // design.y at px=0
        var y = row_base + delta * 0.5; // design.y at the first pixel centre
        const row = py * fb.w;
        var px: usize = 0;
        while (px < fb.w) : (px += 1) {
            fb.px[row + px] = skyColor(y, half, inv_half, sky_top, sky_horizon);
            y += delta;
        }
    }
}

// the sky/grass colour at design-Y `y`. createLinearGradient(0,0,0,H/2): stops skyTop@0,
// skyTop@0.2, horizon@1; below the mid-line (y >= half) it's grass.
fn skyColor(y: f32, half: f32, inv_half: f32, sky_top: u32, sky_horizon: u32) u32 {
    if (y >= half) return GRASS;
    const t = y * inv_half;
    if (t <= 0.2) return sky_top;
    const fr = (t - 0.2) / 0.8;
    return lerpRgb(sky_top, sky_horizon, if (fr > 1.0) 1.0 else fr);
}

// ---- the setting sun: warm radial glow + the disc, clipped to the sky (design top half). ----
// Bounded to the glow's pixel box (not the whole sky). The glow colour is a smooth function
// of the design radius r, so we bake it into a per-frame LUT indexed by r² — the hot loop
// then needs NO sqrt, just dx²+dy² and a table lookup (the per-pixel sqrt was the cost at
// SS²). Upright (st==0 — the long sunset segment) is a fast path: design-Y is constant per
// row (one horizon test) and design-X steps by inv_ss, no per-pixel un-rotation. The disc is
// small and crisp, so it keeps the exact sqrt (only for its handful of pixels).
const GLOW_LUT_N: usize = 1024;
var glow_lut: [GLOW_LUT_N]Rgba = undefined;
const SunShade = struct { glow_outer2: f32, disc_inner: f32, disc_outer: f32, disc_outer2: f32, lut_scale: f32 };

pub fn drawSun(fb: Fb, roll: Roll, sun: SunPos) void {
    const half = roll.cy;
    const glow_inner = 8.0 * sun.scale;
    const glow_outer = 340.0 * sun.scale;
    const disc_inner = 4.0 * sun.scale;
    const disc_outer = SUN_RADIUS_PX * sun.scale;
    const glow_outer2 = glow_outer * glow_outer;

    // bake glowColor(r) into glow_lut, indexed by r² scaled into [0, N). Rebuilt each frame
    // (the radii scale with the sun); N·(one sqrt) is nothing against the SS² pixel loop.
    const lut_scale = @as(f32, @floatFromInt(GLOW_LUT_N - 1)) / glow_outer2;
    const span = glow_outer - glow_inner;
    const inv_span: f32 = if (span > 1e-6) 1.0 / span else 0.0;
    var i: usize = 0;
    while (i < GLOW_LUT_N) : (i += 1) {
        const r = @sqrt(@as(f32, @floatFromInt(i)) / lut_scale);
        glow_lut[i] = glowColor(clamp01((r - glow_inner) * inv_span));
    }
    const shade = SunShade{ .glow_outer2 = glow_outer2, .disc_inner = disc_inner, .disc_outer = disc_outer, .disc_outer2 = disc_outer * disc_outer, .lut_scale = lut_scale };

    const center = roll.toPixel(sun.x, sun.y);
    const r_px = glow_outer * roll.ss;
    const ylo: i64 = @max(0, @as(i64, @intFromFloat(@floor(center.y - r_px))));
    const yhi: i64 = @min(@as(i64, @intCast(fb.h)) - 1, @as(i64, @intFromFloat(@ceil(center.y + r_px))));
    const xlo: i64 = @max(0, @as(i64, @intFromFloat(@floor(center.x - r_px))));
    const xhi: i64 = @min(@as(i64, @intCast(fb.w)) - 1, @as(i64, @intFromFloat(@ceil(center.x + r_px))));

    if (roll.st == 0.0) {
        var py: i64 = ylo;
        while (py <= yhi) : (py += 1) {
            const des_y = (@as(f32, @floatFromInt(py)) + 0.5) * roll.inv_ss;
            if (des_y >= half) continue; // whole row below the horizon (design-Y constant per row)
            const dy = des_y - sun.y;
            const dyy = dy * dy;
            const row = @as(usize, @intCast(py)) * fb.w;
            var dx = (@as(f32, @floatFromInt(xlo)) + 0.5) * roll.inv_ss - sun.x;
            var px: i64 = xlo;
            while (px <= xhi) : (px += 1) {
                sunPixel(fb, row + @as(usize, @intCast(px)), dx * dx + dyy, shade);
                dx += roll.inv_ss;
            }
        }
        return;
    }
    // rolled (turning): un-rotate each pixel to design space, then the same r²-keyed shade.
    var py: i64 = ylo;
    while (py <= yhi) : (py += 1) {
        var px: i64 = xlo;
        while (px <= xhi) : (px += 1) {
            const d = roll.toDesign(@as(f32, @floatFromInt(px)) + 0.5, @as(f32, @floatFromInt(py)) + 0.5);
            if (d.y >= half) continue; // sky-only clip
            const dx = d.x - sun.x;
            const dy = d.y - sun.y;
            sunPixel(fb, @as(usize, @intCast(py)) * fb.w + @as(usize, @intCast(px)), dx * dx + dy * dy, shade);
        }
    }
}

// shade one sun pixel from its design radius² : the LUT'd glow, then the exact disc on top.
fn sunPixel(fb: Fb, idx: usize, r2: f32, s: SunShade) void {
    if (r2 < s.glow_outer2) {
        var b: usize = @intFromFloat(r2 * s.lut_scale);
        if (b >= GLOW_LUT_N) b = GLOW_LUT_N - 1;
        const c = glow_lut[b];
        blend(fb, idx, c.r, c.g, c.b, c.a);
    }
    if (r2 <= s.disc_outer2) {
        const r = @sqrt(r2);
        const t = clamp01((r - s.disc_inner) / (s.disc_outer - s.disc_inner));
        const c = lerpRgb(0xffe6a3, 0xff9d5c, t);
        blend(fb, idx, chan(c, 16), chan(c, 8), chan(c, 0), 1.0);
    }
}

// the glow's 3-stop gradient: warm core -> mid -> transparent edge (matches drawSun).
const Rgba = struct { r: f32, g: f32, b: f32, a: f32 };
fn glowColor(t: f32) Rgba {
    // stops: 0 -> (255,201,128,0.85); 0.4 -> (255,150,92,0.32); 1 -> (255,150,92,0).
    if (t <= 0.4) {
        const fr = t / 0.4;
        return .{ .r = lerpf(255, 255, fr), .g = lerpf(201, 150, fr), .b = lerpf(128, 92, fr), .a = lerpf(0.85, 0.32, fr) };
    }
    const fr = (t - 0.4) / 0.6;
    return .{ .r = 255, .g = 150, .b = 92, .a = lerpf(0.32, 0.0, fr) };
}

// ---- the draw-command walk: one fill per polygon, in paint order. ----
pub fn walk(fb: Fb, roll: Roll, words: []const u32) void {
    var w: usize = 0;
    while (w < words.len) {
        const tag = words[w];
        w += 1;
        switch (tag) {
            3 => { // alpha disc — a tower beacon's blinking glow
                const color = words[w];
                const x = f(words[w + 1]);
                const y = f(words[w + 2]);
                const r = f(words[w + 3]);
                const alpha = f(words[w + 4]);
                w += 5;
                if (r >= 0.5 and alpha >= 0.02) discFill(fb, roll, x, y, r, color, alpha);
            },
            4 => { // radial-gradient polygon — truck headlights / brake glow (rgba)
                const c0 = words[w];
                const c1 = words[w + 1];
                const cx = f(words[w + 2]);
                const cy = f(words[w + 3]);
                const r = f(words[w + 4]);
                const n = words[w + 5];
                w += 6;
                const sh = Shader{ .radial = .{ .c0 = c0, .c1 = c1, .cx = cx, .cy = cy, .r = r } };
                w = fillPoly(fb, roll, words, w, n, sh, r >= 0.5);
            },
            5 => { // 2-stop linear-gradient polygon — the bull's flat shading panels
                const c0 = words[w];
                const c1 = words[w + 1];
                const o0 = f(words[w + 2]);
                const o1 = f(words[w + 3]);
                const ax = f(words[w + 4]);
                const ay = f(words[w + 5]);
                const bx = f(words[w + 6]);
                const by = f(words[w + 7]);
                const n = words[w + 8];
                w += 9;
                const sh = Shader{ .linear = .{ .c0 = c0, .c1 = c1, .o0 = stopAt(o0, 0), .o1 = stopAt(o1, stopAt(o0, 0)), .ax = ax, .ay = ay, .bx = bx, .by = by } };
                w = fillPoly(fb, roll, words, w, n, sh, true);
            },
            6 => { // 2-stop radial-(ellipse)-gradient polygon — the bull's rounded muscle shading
                const c0 = words[w];
                const c1 = words[w + 1];
                const o0 = f(words[w + 2]);
                const o1 = f(words[w + 3]);
                const cx = f(words[w + 4]);
                const cy = f(words[w + 5]);
                const ux = f(words[w + 6]);
                const uy = f(words[w + 7]);
                const vx = f(words[w + 8]);
                const vy = f(words[w + 9]);
                const n = words[w + 10];
                w += 11;
                const det = ux * vy - uy * vx;
                const sh = if (@abs(det) < 1e-4)
                    Shader{ .solidAlpha = .{ .rgba = c0 } } // degenerate -> solid stop-0 colour
                else
                    Shader{ .ellipse = .{ .c0 = c0, .c1 = c1, .o0 = stopAt(o0, 0), .o1 = stopAt(o1, stopAt(o0, 0)), .cx = cx, .cy = cy, .ux = ux, .uy = uy, .vx = vx, .vy = vy, .det = det } };
                w = fillPoly(fb, roll, words, w, n, sh, true);
            },
            1 => { // round (horizontal cylinder) gradient, with a per-poly shade strength
                const color = words[w];
                const strength = f(words[w + 1]);
                const n = words[w + 2];
                w += 3;
                // gradient axis spans the polygon's DESIGN x-extent (computed pre-rotation).
                var minx: f32 = std.math.inf(f32);
                var maxx: f32 = -std.math.inf(f32);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const x = f(words[w + i * 2]);
                    if (x < minx) minx = x;
                    if (x > maxx) maxx = x;
                }
                // strength scales the shade factors: 1 → 0.6/1.25 (full), 0 → flat (= solid).
                const sh = if (strength <= 0.0 or maxx - minx < 1.0)
                    Shader{ .solid = color }
                else
                    Shader{ .round = .{ .lo = shadeClamp(color, 1.0 - 0.4 * strength), .mid = shadeClamp(color, 1.0 + 0.25 * strength), .minx = minx, .maxx = maxx } };
                w = fillPoly(fb, roll, words, w, n, sh, true);
            },
            else => { // tag 0 = solid
                const color = words[w];
                const n = words[w + 1];
                w += 2;
                w = fillPoly(fb, roll, words, w, n, Shader{ .solid = color }, true);
            },
        }
    }
}

// ---- the shaders: how a filled pixel gets its colour, given its DESIGN coordinate. ----
const Shader = union(enum) {
    solid: u32, // 0xRRGGBB opaque
    solidAlpha: struct { rgba: u32 }, // 0xAARRGGBB (degenerate ellipse)
    round: struct { lo: u32, mid: u32, minx: f32, maxx: f32 }, // lo/mid = shadeClamp(color,.6/1.25), hoisted per-poly
    radial: struct { c0: u32, c1: u32, cx: f32, cy: f32, r: f32 },
    linear: struct { c0: u32, c1: u32, o0: f32, o1: f32, ax: f32, ay: f32, bx: f32, by: f32 },
    ellipse: struct { c0: u32, c1: u32, o0: f32, o1: f32, cx: f32, cy: f32, ux: f32, uy: f32, vx: f32, vy: f32, det: f32 },
};

// scratch for one polygon's screen-space vertices and a scanline's edge crossings.
var sp: [1024]Pt = undefined;
var xs: [1024]f32 = undefined;

// fillPoly reads `n` design-space points starting at word `w`, rotates them to screen
// space, scanline-fills the polygon under `shader`, and returns the word index past the
// points. `do_fill=false` consumes the points without drawing (e.g. a degenerate beam).
fn fillPoly(fb: Fb, roll: Roll, words: []const u32, w: usize, n: u32, shader: Shader, do_fill: bool) usize {
    const count: usize = @intCast(n);
    var i: usize = 0;
    while (i < count and i < sp.len) : (i += 1) {
        sp[i] = roll.toPixel(f(words[w + i * 2]), f(words[w + i * 2 + 1]));
    }
    const nv = @min(count, sp.len);
    const end = w + count * 2;
    if (!do_fill or nv < 3) return end;

    var miny: f32 = std.math.inf(f32);
    var maxy: f32 = -std.math.inf(f32);
    for (sp[0..nv]) |p| {
        if (p.y < miny) miny = p.y;
        if (p.y > maxy) maxy = p.y;
    }
    var y: i64 = @max(0, @as(i64, @intFromFloat(@floor(miny))));
    const ylast: i64 = @min(@as(i64, @intCast(fb.h)) - 1, @as(i64, @intFromFloat(@ceil(maxy))));
    const upright = roll.st == 0.0; // no roll → design = pixel·inv_ss, no per-pixel un-rotation
    while (y <= ylast) : (y += 1) {
        const yc = @as(f32, @floatFromInt(y)) + 0.5;
        var nx: usize = 0;
        var k: usize = 0;
        while (k < nv) : (k += 1) {
            const a = sp[k];
            const b = sp[(k + 1) % nv];
            const lo = @min(a.y, b.y);
            const hi = @max(a.y, b.y);
            if (yc >= lo and yc < hi) { // half-open: each crossing counted once
                const t = (yc - a.y) / (b.y - a.y);
                if (nx < xs.len) {
                    xs[nx] = a.x + t * (b.x - a.x);
                    nx += 1;
                }
            }
        }
        insertionSort(xs[0..nx]);
        const solid_color: ?u32 = switch (shader) {
            .solid => |cc| cc & 0xffffff,
            else => null,
        };
        var s: usize = 0;
        while (s + 1 < nx) : (s += 2) {
            var xa: i64 = @intFromFloat(@ceil(xs[s] - 0.5));
            var xb: i64 = @intFromFloat(@floor(xs[s + 1] - 0.5));
            if (xa < 0) xa = 0;
            if (xb > @as(i64, @intCast(fb.w)) - 1) xb = @as(i64, @intCast(fb.w)) - 1;
            const rowbase = @as(usize, @intCast(y)) * fb.w;
            // Solid fills (mountains/road/most critters) don't use the per-pixel design
            // coord — tight store loop, no toDesign/shade call. This is the bulk of the area.
            if (solid_color) |sc| {
                var x: i64 = xa;
                while (x <= xb) : (x += 1) fb.px[rowbase + @as(usize, @intCast(x))] = sc;
                continue;
            }
            if (upright) {
                // design.y is constant across the scanline; design.x = (x+0.5)·inv_ss (exact,
                // = toDesign at st==0) — one multiply, no rotation. Common case (straight road).
                const dy = yc * roll.inv_ss;
                var x: i64 = xa;
                while (x <= xb) : (x += 1) {
                    const dx = (@as(f32, @floatFromInt(x)) + 0.5) * roll.inv_ss;
                    shadePixel(fb, rowbase + @as(usize, @intCast(x)), shader, .{ .x = dx, .y = dy });
                }
            } else {
                var x: i64 = xa;
                while (x <= xb) : (x += 1) {
                    const d = roll.toDesign(@as(f32, @floatFromInt(x)) + 0.5, yc);
                    shadePixel(fb, rowbase + @as(usize, @intCast(x)), shader, d);
                }
            }
        }
    }
    return end;
}

fn shadePixel(fb: Fb, idx: usize, shader: Shader, d: Pt) void {
    switch (shader) {
        .solid => |c| fb.px[idx] = c & 0xffffff,
        .solidAlpha => |s| {
            const a = @as(f32, @floatFromInt((s.rgba >> 24) & 0xff)) / 255.0;
            blend(fb, idx, chan(s.rgba, 16), chan(s.rgba, 8), chan(s.rgba, 0), a);
        },
        .round => |s| {
            // canvas interpolates the (clamped) stop colours shade(c,0.6)->shade(c,1.25)->shade(c,0.6);
            // lo/mid are per-poly constants (hoisted into the shader), so the loop is just lerp+pack.
            const frac = clamp01((d.x - s.minx) / (s.maxx - s.minx));
            const c = if (frac < 0.5) lerpRgb(s.lo, s.mid, frac / 0.5) else lerpRgb(s.mid, s.lo, (frac - 0.5) / 0.5);
            fb.px[idx] = c;
        },
        .radial => |s| {
            const r = @sqrt((d.x - s.cx) * (d.x - s.cx) + (d.y - s.cy) * (d.y - s.cy));
            const t = clamp01(r / s.r);
            blendStops(fb, idx, s.c0, s.c1, t, 0.0, 1.0);
        },
        .linear => |s| {
            const dxv = s.bx - s.ax;
            const dyv = s.by - s.ay;
            const len2 = dxv * dxv + dyv * dyv;
            const p = if (len2 < 1e-6) 0.0 else ((d.x - s.ax) * dxv + (d.y - s.ay) * dyv) / len2;
            blendStops(fb, idx, s.c0, s.c1, clamp01(p), s.o0, s.o1);
        },
        .ellipse => |s| {
            // invert [ux vx; uy vy] to map the design point into unit (gradient) space.
            const ex = d.x - s.cx;
            const ey = d.y - s.cy;
            const u = (s.vy * ex - s.vx * ey) / s.det;
            const v = (-s.uy * ex + s.ux * ey) / s.det;
            const r = @sqrt(u * u + v * v);
            blendStops(fb, idx, s.c0, s.c1, clamp01(r), s.o0, s.o1);
        },
    }
}

// blend a 2-stop rgba gradient (stops at o0->c0, o1->c1) sampled at param p, over fb[idx].
fn blendStops(fb: Fb, idx: usize, c0: u32, c1: u32, p: f32, o0: f32, o1: f32) void {
    var c: u32 = undefined;
    if (p <= o0) {
        c = c0;
    } else if (p >= o1 or o1 <= o0) {
        c = c1;
    } else {
        c = lerpRgba(c0, c1, (p - o0) / (o1 - o0));
    }
    const a = @as(f32, @floatFromInt((c >> 24) & 0xff)) / 255.0;
    blend(fb, idx, chan(c, 16), chan(c, 8), chan(c, 0), a);
}

fn discFill(fb: Fb, roll: Roll, dx: f32, dy: f32, r_design: f32, color: u32, alpha: f32) void {
    const c = roll.toPixel(dx, dy); // rotation preserves the radius; scale it to pixel space
    const r = r_design * roll.ss;
    var y: i64 = @max(0, @as(i64, @intFromFloat(@floor(c.y - r))));
    const ylast: i64 = @min(@as(i64, @intCast(fb.h)) - 1, @as(i64, @intFromFloat(@ceil(c.y + r))));
    const rr = r * r;
    while (y <= ylast) : (y += 1) {
        var x: i64 = @max(0, @as(i64, @intFromFloat(@floor(c.x - r))));
        const xlast: i64 = @min(@as(i64, @intCast(fb.w)) - 1, @as(i64, @intFromFloat(@ceil(c.x + r))));
        while (x <= xlast) : (x += 1) {
            const ex = @as(f32, @floatFromInt(x)) + 0.5 - c.x;
            const ey = @as(f32, @floatFromInt(y)) + 0.5 - c.y;
            if (ex * ex + ey * ey <= rr) {
                const idx = @as(usize, @intCast(y)) * fb.w + @as(usize, @intCast(x));
                blend(fb, idx, chan(color, 16), chan(color, 8), chan(color, 0), alpha);
            }
        }
    }
}

// ---- small colour + math helpers ----
fn f(word: u32) f32 {
    return @bitCast(word);
}
fn chan(color: u32, comptime shift: u5) f32 {
    return @floatFromInt((color >> shift) & 0xff);
}
fn clamp01(x: f32) f32 {
    return if (x < 0.0) 0.0 else if (x > 1.0) 1.0 else x;
}
fn lerpf(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
fn stopAt(o: f32, lo: f32) f32 {
    return if (o < lo) lo else if (o > 1.0) 1.0 else o;
}
fn pack(r: f32, g: f32, b: f32) u32 {
    return (@as(u32, @intFromFloat(r + 0.5)) << 16) | (@as(u32, @intFromFloat(g + 0.5)) << 8) | @as(u32, @intFromFloat(b + 0.5));
}
fn lerpRgb(a: u32, b: u32, t: f32) u32 {
    return pack(lerpf(chan(a, 16), chan(b, 16), t), lerpf(chan(a, 8), chan(b, 8), t), lerpf(chan(a, 0), chan(b, 0), t));
}
// lerp 0xAARRGGBB including alpha, returning a packed 0xAARRGGBB.
fn lerpRgba(a: u32, b: u32, t: f32) u32 {
    const av = lerpf(@floatFromInt((a >> 24) & 0xff), @floatFromInt((b >> 24) & 0xff), t);
    const rv = lerpf(chan(a, 16), chan(b, 16), t);
    const gv = lerpf(chan(a, 8), chan(b, 8), t);
    const bv = lerpf(chan(a, 0), chan(b, 0), t);
    return (@as(u32, @intFromFloat(av + 0.5)) << 24) | pack(rv, gv, bv);
}
fn shadeClamp(color: u32, fac: f32) u32 {
    const r = @min(255.0, chan(color, 16) * fac);
    const g = @min(255.0, chan(color, 8) * fac);
    const b = @min(255.0, chan(color, 0) * fac);
    return pack(r, g, b);
}
// alpha-composite src (r,g,b in 0..255, a in 0..1) over fb[idx].
fn blend(fb: Fb, idx: usize, r: f32, g: f32, b: f32, a: f32) void {
    if (a <= 0.0) return;
    const dst = fb.px[idx];
    const inv = 1.0 - a;
    const or_ = r * a + chan(dst, 16) * inv;
    const og = g * a + chan(dst, 8) * inv;
    const ob = b * a + chan(dst, 0) * inv;
    fb.px[idx] = pack(or_, og, ob);
}
fn insertionSort(a: []f32) void {
    var i: usize = 1;
    while (i < a.len) : (i += 1) {
        const key = a[i];
        var j: usize = i;
        while (j > 0 and a[j - 1] > key) : (j -= 1) a[j] = a[j - 1];
        a[j] = key;
    }
}
