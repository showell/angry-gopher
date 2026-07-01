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
const cat = @import("cat.zig");
const gaze = @import("gaze.zig");
const truck = @import("truck.zig");
const sky = @import("sky.zig");
const paint = @import("paint.zig");

var the_world: world.World = undefined;
var cur: rider.RiderState = undefined;
var ready = false;

// the chased truck: its own little simulation, advanced in lockstep with the rider and kept in a parallel
// history ring so it scrubs cleanly on pause/reverse. course_len is the fixed distance its schedule lerps
// its lead down over (computed once the world is built).
var truck_cur: truck.State = undefined;
var course_len: f32 = 0;

// the animation clock (TS step = riderHistory.length - 1): advance()++ / back()-- so it
// scrubs on reverse and freezes on pause, driving the day→dusk sky, sun, and mountain
// dimming. Floors at 0. f32 so the sun's linear descent reads it directly.
var step_clock: f32 = 0;

// the sun's screen placement for the current frame, recomputed in renderFrame from the
// rider's heading + the clock; the blitter reads it to paint the disc behind the ranges.
var sun: sky.SunPos = .{ .visible = false, .x = 0, .y = 0, .scale = 0 };

// the live camera focal for the last frame (lean + attention pull-in), exported for the HUD / probes.
var cam_focal_now: f32 = camera.FOCAL;

// history stack (ring) of prior states, so ↓ can step backward. Bounded — back works
// within the last HIST_CAP frames, ample for inspection; older frames drop.
const HIST_CAP = 8192;
var hist: [HIST_CAP]rider.RiderState = undefined;
var truck_hist: [HIST_CAP]truck.State = undefined; // parallel to hist; advanced/popped in lockstep
var hist_head: usize = 0;
var hist_count: usize = 0;

fn ensure() void {
    if (ready) return;
    the_world = world.buildWorld();
    cur = rider.initialRiderState();
    truck_cur = truck.initial();
    course_len = world.courseLength(&the_world);
    ready = true;
}

/// advance steps the rider one frame (getNextRiderState), pushing the prior state so
/// back() can return to it.
pub export fn advance() void {
    ensure();
    // reached the finish line: reset the whole ride to the start so the screensaver replays the journey
    // (rider, truck, the day→dusk clock, and the scrub history all back to frame 0). Mirrors a fresh drive.
    if (rider.isFinished(cur, &the_world)) {
        cur = rider.initialRiderState();
        truck_cur = truck.initial();
        step_clock = 0;
        hist_head = 0;
        hist_count = 0;
        return;
    }
    hist[hist_head] = cur;
    truck_hist[hist_head] = truck_cur;
    hist_head = (hist_head + 1) % HIST_CAP;
    if (hist_count < HIST_CAP) hist_count += 1;
    cur = rider.getNextRiderState(cur, &the_world);
    // the truck advances against the NEW rider distance (its schedule anchors to where the rider is now).
    truck_cur = truck.next(truck_cur, world.routeDistance(&the_world, cur.segment, cur.along), &the_world, course_len);
    step_clock += 1;
}

/// back pops one frame off the history stack (a no-op at the bottom).
pub export fn back() void {
    ensure();
    if (hist_count == 0) return;
    hist_head = (hist_head + HIST_CAP - 1) % HIST_CAP;
    hist_count -= 1;
    cur = hist[hist_head];
    truck_cur = truck_hist[hist_head];
    if (step_clock > 0) step_clock -= 1;
}

/// renderFrame fills the draw buffer for the current rider state and returns the byte
/// length. The camera pose is the rider's segment + along/across/yaw — so his drift
/// and heading through a turn show directly; the blitter adds the roll from tilt.
pub export fn renderFrame() u32 {
    ensure();
    paint.reset();
    // the live camera focal: the deepest of the lean pull-in and the rider's attention on a crossing cat
    // (a distracting pig will join `attention` here once pigs are ported). The whole frame — projection,
    // backdrop, and the sun below — reads this one focal, so they stay one camera.
    const lean_frac = @min(@abs(cur.tilt) / rider.MAX_LEAN, 1.0);
    const attention = @max(catAttention(), gaze.gazeFocus(cur.focus));
    const cam_focal = camera.camFocal(lean_frac, attention);
    cam_focal_now = cam_focal;
    // the extra camera yaw on top of his heading: the distracted-rider gaze toward the pigs + a subtle
    // head-turn into a lean (HEAD_YAW_FRAC of the tilt). Swings the whole view; render folds it into the
    // scene pose AND the backdrop heading. Mirrors view.ts / main.ts (state.yaw + gazeAngle + headYaw).
    const view_yaw = cur.gaze_yaw + HEAD_YAW_FRAC * cur.tilt;
    render.frame(&the_world, cur.segment, cur.along, cur.across, cur.yaw, cur.heading, step_clock, cur.v, cam_focal, view_yaw, truck_cur);
    // the sun's placement for the rider's absolute heading (+ the view yaw) + clock, for the blitter to
    // paint behind the ranges (the buffer's first polys). The same continuous heading the
    // mountains use, so the sun doesn't snap across the loop seam.
    sun = sky.sunPos(cur.heading + view_yaw, step_clock, cam_focal);
    return paint.byteLen();
}

// the rider also turns his HEAD into a corner — a subtle view-only yaw, 15% of the lean. Mirrors main.ts.
const HEAD_YAW_FRAC: f32 = 0.15;

// the rider's attention on an off-road distraction, for the focal pull-in: the crossing cat on his CURRENT
// segment (the gap is measured within it). Combined with the pig gaze focus (gazeFocus) by the caller, a
// max — exactly main.ts's `attention`. 0 when no cat pulls his eye.
fn catAttention() f32 {
    const seg = the_world.segments[cur.segment];
    if (!seg.has_cat) return 0;
    return cat.focus(seg.cat.along - cur.along, cur.v);
}

/// riderTilt is the bike's lean — the blitter rolls the canvas by it (camera bank).
/// The lean search leaves a sub-pixel residue (~1e-5 rad) on straights that never quite
/// reaches 0; below ROLL_DEADBAND (~0.06°, < half a pixel of bank at the screen edge) the
/// camera is upright for ALL practical purposes, so we snap it to exactly 0. That keeps the
/// rendered roll HONEST — both the canvas and the native rasterizer's straight-line fast
/// paths key on st == 0 — without perturbing the simulation (the core reads cur.tilt direct).
const ROLL_DEADBAND: f32 = 1.0e-3;
pub export fn riderTilt() f32 {
    ensure();
    return if (@abs(cur.tilt) < ROLL_DEADBAND) 0.0 else cur.tilt;
}

/// camFocal is the live camera focal (px) from the last renderFrame — the lean + attention pull-in. The
/// HUD can show it; a frame pins it. FOCAL straight-and-clear, smaller as he leans or eyes a crossing cat.
pub export fn camFocal() f32 {
    return cam_focal_now;
}

/// gazeYaw / riderV / riderSeg expose live rider state for the HUD + frame-pinning: the distracted-rider
/// head-turn (rad), the speed (m/press, drops to the gawk speed at the pigs), and the current segment index.
pub export fn gazeYaw() f32 {
    ensure();
    return cur.gaze_yaw;
}
pub export fn riderV() f32 {
    ensure();
    return cur.v;
}
pub export fn riderSeg() u32 {
    ensure();
    return @intCast(cur.segment);
}

/// truckLead / truckV / truckBraking expose the chase for the HUD + probes: the truck's lead over the
/// rider (m along the route), its speed (m/press), and whether its brake lights are lit this frame.
pub export fn truckLead() f32 {
    ensure();
    return truck_cur.pos - world.routeDistance(&the_world, cur.segment, cur.along);
}
pub export fn truckV() f32 {
    ensure();
    return truck_cur.v;
}
pub export fn truckBraking() u32 {
    ensure();
    return if (truck_cur.braking) 1 else 0;
}

/// bufPtr is the byte offset of the draw buffer in linear memory.
pub export fn bufPtr() u32 {
    return paint.ptr();
}

/// frameWords exposes the current frame's draw-command words as a slice — for the NATIVE
/// renderer (games/driving/native), which reads the same buffer in-process rather than
/// through a Float32Array view. (The WASM blitter uses bufPtr()/renderFrame()'s length.)
pub fn frameWords() []const u32 {
    return paint.frameWords();
}

/// bufHighWater is the most bytes any frame has used this run (instrumentation); if it
/// ever equals bufCap() the draw buffer overflowed and commands were silently dropped.
pub export fn bufHighWater() u32 {
    return paint.highWaterBytes();
}

/// bufCap is the fixed draw-buffer size — the ceiling bufHighWater() must stay under.
pub export fn bufCap() u32 {
    return paint.capBytes();
}

/// cullSeg / cullSize: critters dropped LAST frame by the two culls — by chain-segment reach (saves the
/// WASM the projection work) and by projected pixel size (saves buffer + blitting). Instrumentation; the
/// gate asserts both stay non-zero over a traversal, so neither cull silently goes dead (belt + suspenders).
pub export fn cullSeg() u32 {
    return render.cull_seg;
}
pub export fn cullSize() u32 {
    return render.cull_size;
}

/// clock is the animation step `t` — the count of advances (minus backs). It's the clock
/// driving the sun/sky/beacons, AND the index Steve reports to pin a frame for path sims.
pub export fn clock() u32 {
    return @intFromFloat(step_clock);
}

// --- the day→dusk sky, for the blitter's background gradient + sun. zig owns every
// colour and the sun's position; the blitter just paints the gradients it is handed. ---

/// skyTop / skyHorizon are the upper-sky and lower-horizon-band colours (0xRRGGBB) for
/// the current clock — the two stops of the background gradient. They dim toward dusk and
/// the horizon reddens at sunset.
pub export fn skyTop() u32 {
    ensure();
    return sky.skyColor(step_clock);
}
pub export fn skyHorizon() u32 {
    ensure();
    return sky.horizonColor(step_clock);
}

/// sunVisible is 1 when the sun is on-screen for the current heading (else the blitter
/// skips it); sunX/sunY are its screen centre and sunScale its size factor (vertical
/// squeeze on a lean — 1.0 in the static frame). Set by the last renderFrame().
pub export fn sunVisible() u32 {
    return if (sun.visible) 1 else 0;
}
pub export fn sunX() f32 {
    return sun.x;
}
pub export fn sunY() f32 {
    return sun.y;
}
pub export fn sunScale() f32 {
    return sun.scale;
}

/// setViewW widens (or resets) the projection width — the native window calls it to match the
/// screen's aspect for more peripheral FOV (see camera.view_w). The browser and the golden PNG
/// harness never call it, so they stay pinned at the design width and render bit-identically.
/// Call it BEFORE renderFrame(); the next frame's draw commands span [0, view_w].
pub export fn setViewW(w: f32) void {
    camera.setViewW(w);
}
