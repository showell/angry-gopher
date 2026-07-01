//! sky — the day→dusk clock: the sky's colour (a daytime blue dimming to a deep dusk
//! blue, its lower band reddening as the sun crosses the horizon) and the setting sun's
//! screen placement. Pure functions of the STEP clock (safari.zig owns it) + the rider's
//! absolute heading. Faithful to sky.ts + sun.ts. zig owns every colour and position;
//! the blitter only paints the gradients it is handed — no clock or colour math on the
//! JS side. The sun draws BEHIND the mountains (the blitter paints it before the buffer,
//! whose first polys are the ranges), exactly as horizon.ts layers sun then mountains.

const std = @import("std");
const camera = @import("camera.zig");

// --- the sun as a clock (sun.ts): its height drops linearly with the step, so it scrubs
// on reverse and freezes on pause like everything else. Heights are PIXELS at the base
// focal, so they compare directly with the mountain silhouettes. ---
pub const SUN_BEARING: f32 = -2.2176; // its fixed world bearing (west-ish)
pub const SUN_RADIUS_PX: f32 = 46.0;
const SUN_START_PX: f32 = 244.0; // step-0 height (calibrated to the route's timing in TS)
const SUN_DROP_PX_PER_STEP: f32 = 0.41616 * (2.0 * SUN_RADIUS_PX) / 625.0;
const SUN_FULLY_SET_PX: f32 = -SUN_RADIUS_PX; // the whole disc is below the horizon
const WARMTH_FALLOFF_PX: f32 = 110.0; // how far from the horizon the sunset-red fades out
const VISIBLE_BEARING_LIMIT: f32 = 1.4; // beyond this off-heading the sun is off-screen

fn wrap(a: f32) f32 {
    var r = a;
    while (r > std.math.pi) r -= 2.0 * std.math.pi;
    while (r < -std.math.pi) r += 2.0 * std.math.pi;
    return r;
}

pub fn sunHeightPx(step: f32) f32 {
    return SUN_START_PX - SUN_DROP_PX_PER_STEP * step;
}

// How far "dusk" has progressed (0 = day, 1 = night). While the sun is up the darkening
// is a SQUARED ramp — barely moving while it is high, accelerating toward sunset — so the
// sky stays bright until around sunset; once the disc is fully set the rest fades linearly.
pub fn sunSetFraction(step: f32) f32 {
    const h = sunHeightPx(step);
    const dusk_at_set = 0.5 * (SUN_START_PX - SUN_FULLY_SET_PX) / SUN_START_PX;
    if (h >= SUN_FULLY_SET_PX) {
        const p = (SUN_START_PX - h) / (SUN_START_PX - SUN_FULLY_SET_PX);
        return @max(0.0, dusk_at_set * p * p);
    }
    return @min(1.0, dusk_at_set + (SUN_FULLY_SET_PX - h) / SUN_RADIUS_PX * (1.0 - dusk_at_set));
}

// How RED the afterglow is (0..1): peaks as the disc crosses the horizon, fades when it
// is high or deep below — drives the warm band the sky mixes into its lower edge.
pub fn sunsetWarmth(step: f32) f32 {
    return @max(0.0, 1.0 - @abs(sunHeightPx(step)) / WARMTH_FALLOFF_PX);
}

// --- sky colours (sky.ts): the upper sky dims all channels toward dusk (so it deepens
// rather than greying out); the red mixes only into the lower horizon band. ---
const DAY_SKY = [3]f32{ 142, 202, 230 }; // #8ecae6 — the established daytime sky
const DUSK_SKY = [3]f32{ 36, 58, 94 }; // deep dusk blue
const SUNSET_RED = [3]f32{ 222, 88, 52 }; // #de5834 — warm sunset glow
const SUNSET_GLOW: f32 = 0.85; // how strongly the red mixes in at peak warmth

fn lerp3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        @round(a[0] + (b[0] - a[0]) * t),
        @round(a[1] + (b[1] - a[1]) * t),
        @round(a[2] + (b[2] - a[2]) * t),
    };
}

fn pack(c: [3]f32) u32 {
    const r: u32 = @intFromFloat(c[0]);
    const g: u32 = @intFromFloat(c[1]);
    const b: u32 = @intFromFloat(c[2]);
    return (r << 16) | (g << 8) | b;
}

pub fn skyColor(step: f32) u32 {
    return pack(lerp3(DAY_SKY, DUSK_SKY, sunSetFraction(step)));
}

pub fn horizonColor(step: f32) u32 {
    const sky = lerp3(DAY_SKY, DUSK_SKY, sunSetFraction(step));
    return pack(lerp3(sky, SUNSET_RED, sunsetWarmth(step) * SUNSET_GLOW));
}

// --- the sun's screen placement for the rider's heading (drawSun, minus the canvas) ---
// `scale` = cam_focal / base focal squeezes the disc + glow vertically on a lean (1.0 in
// the static frame); the blitter multiplies its radii by it. `visible` is false when the
// sun is too far off-heading to be on-screen — the blitter then skips it entirely.
pub const SunPos = struct { visible: bool, x: f32, y: f32, scale: f32 };

pub fn sunPos(heading: f32, step: f32, cam_focal: f32) SunPos {
    const rel = wrap(SUN_BEARING - heading);
    if (@abs(rel) >= VISIBLE_BEARING_LIMIT) return .{ .visible = false, .x = 0, .y = 0, .scale = 0 };
    const v_scale = cam_focal / camera.FOCAL;
    return .{
        .visible = true,
        .x = camera.view_w / 2.0 + @tan(rel) * cam_focal, // centre follows the live width (peripheral FOV)
        .y = camera.H / 2.0 - sunHeightPx(step) * v_scale,
        .scale = v_scale,
    };
}
