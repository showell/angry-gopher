//! safari — the WASM ABI shim: the ONE module the browser can see. It owns the
//! static world AND the live rider state (the camera is now the full rider state, not
//! a scalar), plus a history stack so the blitter can step backward frame by frame.
//! Everything upstream (geom, camera, world, rider, scene bits, paint) is pure.
//!
//! The blitter drives it: advance() each auto frame (or on ↑), back() on ↓, then
//! renderFrame() + riderTilt() to draw — the dumb plain-JS side fills the polygons
//! and rolls the canvas by the bike's lean.

const world = @import("world.zig");
const rider = @import("rider.zig");
const render = @import("render.zig");
const camera = @import("camera.zig");
const sky = @import("sky.zig");
const paint = @import("paint.zig");

var the_world: world.World = undefined;
var cur: rider.RiderState = undefined;
var ready = false;

// the animation clock (TS step = riderHistory.length - 1): advance()++ / back()-- so it
// scrubs on reverse and freezes on pause, driving the day→dusk sky, sun, and mountain
// dimming. Floors at 0. f32 so the sun's linear descent reads it directly.
var step_clock: f32 = 0;

// the sun's screen placement for the current frame, recomputed in renderFrame from the
// rider's heading + the clock; the blitter reads it to paint the disc behind the ranges.
var sun: sky.SunPos = .{ .visible = false, .x = 0, .y = 0, .scale = 0 };

// history stack (ring) of prior states, so ↓ can step backward. Bounded — back works
// within the last HIST_CAP frames, ample for inspection; older frames drop.
const HIST_CAP = 8192;
var hist: [HIST_CAP]rider.RiderState = undefined;
var hist_head: usize = 0;
var hist_count: usize = 0;

fn ensure() void {
    if (ready) return;
    the_world = world.buildWorld();
    cur = rider.initialRiderState();
    ready = true;
}

/// advance steps the rider one frame (getNextRiderState), pushing the prior state so
/// back() can return to it.
export fn advance() void {
    ensure();
    hist[hist_head] = cur;
    hist_head = (hist_head + 1) % HIST_CAP;
    if (hist_count < HIST_CAP) hist_count += 1;
    cur = rider.getNextRiderState(cur, &the_world);
    step_clock += 1;
}

/// back pops one frame off the history stack (a no-op at the bottom).
export fn back() void {
    ensure();
    if (hist_count == 0) return;
    hist_head = (hist_head + HIST_CAP - 1) % HIST_CAP;
    hist_count -= 1;
    cur = hist[hist_head];
    if (step_clock > 0) step_clock -= 1;
}

/// renderFrame fills the draw buffer for the current rider state and returns the byte
/// length. The camera pose is the rider's segment + along/across/yaw — so his drift
/// and heading through a turn show directly; the blitter adds the roll from tilt.
export fn renderFrame() u32 {
    ensure();
    paint.reset();
    render.frame(&the_world, cur.segment, cur.along, cur.across, cur.yaw, cur.heading, step_clock, cur.v);
    // the sun's placement for the rider's absolute heading + clock, for the blitter to
    // paint behind the ranges (the buffer's first polys). The same continuous heading the
    // mountains use, so the sun doesn't snap across the loop seam.
    sun = sky.sunPos(cur.heading, step_clock, camera.FOCAL);
    return paint.byteLen();
}

/// riderTilt is the bike's lean — the blitter rolls the canvas by it (camera bank).
export fn riderTilt() f32 {
    ensure();
    return cur.tilt;
}

/// bufPtr is the byte offset of the draw buffer in linear memory.
export fn bufPtr() u32 {
    return paint.ptr();
}

/// bufHighWater is the most bytes any frame has used this run (instrumentation); if it
/// ever equals bufCap() the draw buffer overflowed and commands were silently dropped.
export fn bufHighWater() u32 {
    return paint.highWaterBytes();
}

/// bufCap is the fixed draw-buffer size — the ceiling bufHighWater() must stay under.
export fn bufCap() u32 {
    return paint.capBytes();
}

/// clock is the animation step `t` — the count of advances (minus backs). It's the clock
/// driving the sun/sky/beacons, AND the index Steve reports to pin a frame for path sims.
export fn clock() u32 {
    return @intFromFloat(step_clock);
}

// --- the day→dusk sky, for the blitter's background gradient + sun. zig owns every
// colour and the sun's position; the blitter just paints the gradients it is handed. ---

/// skyTop / skyHorizon are the upper-sky and lower-horizon-band colours (0xRRGGBB) for
/// the current clock — the two stops of the background gradient. They dim toward dusk and
/// the horizon reddens at sunset.
export fn skyTop() u32 {
    ensure();
    return sky.skyColor(step_clock);
}
export fn skyHorizon() u32 {
    ensure();
    return sky.horizonColor(step_clock);
}

/// sunVisible is 1 when the sun is on-screen for the current heading (else the blitter
/// skips it); sunX/sunY are its screen centre and sunScale its size factor (vertical
/// squeeze on a lean — 1.0 in the static frame). Set by the last renderFrame().
export fn sunVisible() u32 {
    return if (sun.visible) 1 else 0;
}
export fn sunX() f32 {
    return sun.x;
}
export fn sunY() f32 {
    return sun.y;
}
export fn sunScale() f32 {
    return sun.scale;
}
