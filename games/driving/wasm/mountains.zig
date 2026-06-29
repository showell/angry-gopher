//! mountains — the far backdrop ranges as screen-space silhouettes. Each range is a
//! pure function from absolute bearing (radians, 0 = north, + = clockwise) to a
//! height in pixels above the horizon; we sample it per column across the screen and
//! fill the silhouette. Drawn FIRST (farthest, behind the road). Mirrors mountain.ts
//! at full DAY brightness — the dusk dimming + the sun ride with the deferred sunset
//! clock, so there is no `step` here yet.

const std = @import("std");
const camera = @import("camera.zig");
const paint = @import("paint.zig");

const ROCK: u32 = 0x5b6a8f; // northern range
const ROCK_WEST: u32 = 0x39435f; // westward (sunset) range — off-screen looking north
const LAND: u32 = 0x4a8f43; // foreground rolling land (matches the grass)
const SNOW: u32 = 0xeef3f8; // day snow ≈ rgb(238,243,248)

const WEST_RANGE_BEARING: f32 = -2.0416;
const SNOW_THRESHOLD: f32 = 124.0; // only ridge taller than this gets snow
const SNOW_DIP: f32 = 10.0; // how far the snowline dips under the summit
const STEP: f32 = 2.0; // column sampling step (px), like mountain.ts

fn wrap(a: f32) f32 {
    var b = a;
    while (b > std.math.pi) b -= 2.0 * std.math.pi;
    while (b < -std.math.pi) b += 2.0 * std.math.pi;
    return b;
}

// One range: a smooth envelope (tallest at centre, tapering to open sky at its
// edges) times a fixed rugged ridge line.
fn range(bearing: f32, center: f32, half: f32, peak: f32, freq_a: f32, freq_b: f32) f32 {
    const b = wrap(bearing - center);
    const t = b / half;
    if (@abs(t) >= 1.0) return 0.0;
    const envelope = @cos(t * std.math.pi / 2.0);
    const ridge = 0.6 + 0.24 * @cos(b * freq_a) + 0.16 * @cos(b * freq_b + 1.0);
    return peak * envelope * ridge;
}

fn groundBase(bearing: f32) f32 {
    return 18.0 + 12.0 * @sin(wrap(bearing) * 0.9 + 1.9);
}
fn northRange(bearing: f32) f32 {
    return range(bearing, 0.0, 0.95, 150.0, 8.0, 21.0);
}
fn westRange(bearing: f32) f32 {
    return range(bearing, WEST_RANGE_BEARING, 0.72, 120.0, 11.0, 27.0);
}

// the north range's tallest hump, for normalizing the snowline dip.
fn snowPeakHeight() f32 {
    var vm: f32 = -1.0;
    var b: f32 = -0.5;
    while (b <= 0.5) : (b += 0.01) vm = @max(vm, northRange(b));
    return vm;
}
fn snowlineAt(bearing: f32, peak: f32) f32 {
    const num = northRange(bearing) - SNOW_THRESHOLD;
    const above = @max(@as(f32, 0.0), @min(@as(f32, 1.0), num / (peak - SNOW_THRESHOLD)));
    return SNOW_THRESHOLD - SNOW_DIP * above;
}

fn bearingAt(x: f32, heading: f32) f32 {
    return heading + std.math.atan((x - camera.W / 2.0) / camera.FOCAL);
}

// trace a range's crest left→right, then close down to the horizon — one filled
// silhouette polygon.
fn silhouette(comptime f: fn (f32) f32, heading: f32, color: u32) void {
    var pts: [512]camera.ScreenPt = undefined;
    var n: usize = 0;
    var x: f32 = 0;
    while (x <= camera.W) : (x += STEP) {
        pts[n] = .{ .x = x, .y = camera.H / 2.0 - f(bearingAt(x, heading)) };
        n += 1;
    }
    pts[n] = .{ .x = camera.W, .y = camera.H / 2.0 };
    n += 1;
    pts[n] = .{ .x = 0, .y = camera.H / 2.0 };
    n += 1;
    paint.pushPoly(color, pts[0..n]);
}

// the snowcap: the band between the snowline (bottom) and the crest (top) over the
// contiguous central hump where the north range rises above its snowline. Top edge
// L→R, bottom edge R→L. (mountain.ts clips the range to the cap; this builds the
// band directly, the same shape without a clip primitive.)
fn drawSnow(heading: f32) void {
    const peak = snowPeakHeight();
    var pts: [1024]camera.ScreenPt = undefined;
    var xs: [512]f32 = undefined;
    var m: usize = 0;
    var x: f32 = 0;
    while (x <= camera.W) : (x += STEP) {
        const b = bearingAt(x, heading);
        if (northRange(b) > snowlineAt(b, peak) + 0.01) {
            xs[m] = x;
            m += 1;
        }
    }
    if (m < 2) return;
    var n: usize = 0;
    var i: usize = 0;
    while (i < m) : (i += 1) { // top edge: crest
        const b = bearingAt(xs[i], heading);
        pts[n] = .{ .x = xs[i], .y = camera.H / 2.0 - northRange(b) };
        n += 1;
    }
    i = m;
    while (i > 0) { // bottom edge: snowline, reversed
        i -= 1;
        const b = bearingAt(xs[i], heading);
        pts[n] = .{ .x = xs[i], .y = camera.H / 2.0 - snowlineAt(b, peak) };
        n += 1;
    }
    paint.pushPoly(SNOW, pts[0..n]);
}

/// draw the backdrop for the rider's absolute look `heading`: the westward range, the
/// snowcapped northern range, and the rolling land — back to front.
pub fn draw(heading: f32) void {
    silhouette(westRange, heading, ROCK_WEST);
    silhouette(northRange, heading, ROCK);
    drawSnow(heading);
    silhouette(groundBase, heading, LAND);
}
