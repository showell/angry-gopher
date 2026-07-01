//! mountains — the far backdrop ranges as screen-space silhouettes. Each range is a
//! pure function from absolute bearing (radians, 0 = north, + = clockwise) to a
//! height in pixels above the horizon; we sample it per column across the screen and
//! fill the silhouette. Drawn FIRST (farthest, behind the road). Mirrors mountain.ts:
//! the light DIMS the rock + snow toward dusk (a `dusk` fraction, 0 = day … 1 = night,
//! handed down from the sunset clock); the rolling LAND stays put, matching the grass.

const std = @import("std");
const camera = @import("camera.zig");
const paint = @import("paint.zig");
const sky = @import("sky.zig");

const ROCK: u32 = 0x5b6a8f; // northern range
const ROCK_WEST: u32 = 0x39435f; // westward (sunset) range — off-screen looking north
const LAND: u32 = 0x4a8f43; // foreground rolling land (matches the grass)

const ROCK_NIGHT_DIM: f32 = 0.5; // rock fades to this fraction of its day brightness by night — stays below the snow
const SNOW_DAY = [3]f32{ 238, 243, 248 }; // day snow ≈ #eef3f8
const SNOW_NIGHT = [3]f32{ 70, 84, 104 }; // snow loses its glare toward dusk

const WEST_RANGE_BEARING: f32 = -2.0416;
const SNOW_THRESHOLD: f32 = 124.0; // only ridge taller than this gets snow
const SNOW_DIP: f32 = 10.0; // how far the snowline dips under the summit
const STEP: f32 = 2.0; // column sampling step (px), like mountain.ts
// The camera rolls with the rider's lean (up to MAX_LEAN≈20°), so the rotated viewport sees
// design-x beyond [0,W] at the corners (~74px at 20°). Trace the silhouette this far past each
// edge so a lean never reveals sky past the backdrop's end. Same idea as drawBackground's BIG margin.
const ROLL_MARGIN: f32 = 200.0;

// darken a 0xRRGGBB toward dusk; the multiplier keeps the rock always below the
// (also-dimming) snow. Mirrors dimmed() in mountain.ts.
fn dimmed(color: u32, dusk: f32) u32 {
    const f = 1.0 - ROCK_NIGHT_DIM * dusk;
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt((color >> 16) & 255)) * f));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt((color >> 8) & 255)) * f));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color & 255)) * f));
    return (r << 16) | (g << 8) | b;
}

// the snow's colour for this dusk fraction: lerp day → night. Mirrors snowColor().
fn snowColor(dusk: f32) u32 {
    const r: u32 = @intFromFloat(@round(SNOW_DAY[0] + (SNOW_NIGHT[0] - SNOW_DAY[0]) * dusk));
    const g: u32 = @intFromFloat(@round(SNOW_DAY[1] + (SNOW_NIGHT[1] - SNOW_DAY[1]) * dusk));
    const b: u32 = @intFromFloat(@round(SNOW_DAY[2] + (SNOW_NIGHT[2] - SNOW_DAY[2]) * dusk));
    return (r << 16) | (g << 8) | b;
}

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

// the screen column x maps to a bearing through the LIVE focal — a smaller cam_focal (lean/focus pull-in)
// widens the angular span across the screen, exactly as the projection does. Mirrors mountain.ts bearingAt.
fn bearingAt(x: f32, heading: f32, cam_focal: f32) f32 {
    return heading + std.math.atan((x - camera.view_w / 2.0) / cam_focal); // centre follows the live width
}

// the silhouette crest height (px above the horizon) at a bearing — the tallest of the ranges + the land.
// Mirrors horizonCrestPx in mountain.ts.
pub fn horizonCrestPx(bearing: f32) f32 {
    return @max(westRange(bearing), @max(northRange(bearing), groundBase(bearing)));
}

// Has the sun dropped fully BEHIND the western range (dusk arrived)? True once the whole disc is below the
// crest at the sun's bearing — the moment the truck's headlights switch on. Mirrors sunBehindMountains.
pub fn sunBehindMountains(step: f32) bool {
    return sky.sunHeightPx(step) + sky.SUN_RADIUS_PX < horizonCrestPx(sky.SUN_BEARING);
}

// trace a range's crest left→right, then close down to the horizon — one filled
// silhouette polygon. `v_scale` (= cam_focal / FOCAL) squeezes the heights vertically by the same factor
// the pull-in squeezes them horizontally, so it reads as a real focal change (mountain.ts's vScale).
fn silhouette(comptime f: fn (f32) f32, heading: f32, cam_focal: f32, v_scale: f32, color: u32) void {
    var pts: [2048]camera.ScreenPt = undefined; // (view_w + 2·margin)/STEP columns + 2 — sized for the widest view
    var n: usize = 0;
    var x: f32 = -ROLL_MARGIN;
    while (x <= camera.view_w + ROLL_MARGIN) : (x += STEP) {
        pts[n] = .{ .x = x, .y = camera.H / 2.0 - f(bearingAt(x, heading, cam_focal)) * v_scale };
        n += 1;
    }
    pts[n] = .{ .x = camera.view_w + ROLL_MARGIN, .y = camera.H / 2.0 };
    n += 1;
    pts[n] = .{ .x = -ROLL_MARGIN, .y = camera.H / 2.0 };
    n += 1;
    paint.pushPoly(color, pts[0..n]);
}

// the snowcap: the band between the snowline (bottom) and the crest (top) over the
// contiguous central hump where the north range rises above its snowline. Top edge
// L→R, bottom edge R→L. (mountain.ts clips the range to the cap; this builds the
// band directly, the same shape without a clip primitive.)
fn drawSnow(heading: f32, cam_focal: f32, v_scale: f32, snow: u32) void {
    const peak = snowPeakHeight();
    var pts: [2048]camera.ScreenPt = undefined; // top edge + bottom edge = 2·(view_w/STEP), sized for the widest view
    var xs: [1024]f32 = undefined;
    var m: usize = 0;
    var x: f32 = 0;
    while (x <= camera.view_w) : (x += STEP) {
        const b = bearingAt(x, heading, cam_focal);
        if (northRange(b) > snowlineAt(b, peak) + 0.01) {
            xs[m] = x;
            m += 1;
        }
    }
    if (m < 2) return;
    var n: usize = 0;
    var i: usize = 0;
    while (i < m) : (i += 1) { // top edge: crest
        const b = bearingAt(xs[i], heading, cam_focal);
        pts[n] = .{ .x = xs[i], .y = camera.H / 2.0 - northRange(b) * v_scale };
        n += 1;
    }
    i = m;
    while (i > 0) { // bottom edge: snowline, reversed
        i -= 1;
        const b = bearingAt(xs[i], heading, cam_focal);
        pts[n] = .{ .x = xs[i], .y = camera.H / 2.0 - snowlineAt(b, peak) * v_scale };
        n += 1;
    }
    paint.pushPoly(snow, pts[0..n]);
}

/// draw the backdrop for the rider's absolute look `heading`, with the day→night `dusk`
/// fraction dimming the light: the westward range, the snowcapped northern range, and the
/// rolling land — back to front. The rock + snow dim toward dusk; the land does not.
pub fn draw(heading: f32, dusk: f32, cam_focal: f32) void {
    const v_scale = cam_focal / camera.FOCAL; // squeeze the heights to match the horizontal pull-in
    silhouette(westRange, heading, cam_focal, v_scale, dimmed(ROCK_WEST, dusk));
    silhouette(northRange, heading, cam_focal, v_scale, dimmed(ROCK, dusk));
    drawSnow(heading, cam_focal, v_scale, snowColor(dusk));
    silhouette(groundBase, heading, cam_focal, v_scale, LAND);
}
