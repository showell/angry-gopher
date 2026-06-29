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
const paint = @import("paint.zig");

var the_world: world.World = undefined;
var cur: rider.RiderState = undefined;
var ready = false;

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
}

/// back pops one frame off the history stack (a no-op at the bottom).
export fn back() void {
    ensure();
    if (hist_count == 0) return;
    hist_head = (hist_head + HIST_CAP - 1) % HIST_CAP;
    hist_count -= 1;
    cur = hist[hist_head];
}

/// renderFrame fills the draw buffer for the current rider state and returns the byte
/// length. The camera pose is the rider's segment + along/across/yaw — so his drift
/// and heading through a turn show directly; the blitter adds the roll from tilt.
export fn renderFrame() u32 {
    ensure();
    paint.reset();
    render.frame(&the_world, cur.segment, cur.along, cur.across, cur.yaw);
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
