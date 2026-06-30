//! camera — the perspective projection: a rider-relative ground point at a height
//! becomes a screen pixel. Owns the lens constants (canvas size, field of view, eye
//! height) and the near plane. Pure; no drawing, no allocation. Everything that
//! defines the VIEW — yaw (folded into the rider transform), the focal that lean and
//! focus pull IN, later pitch/roll — is just a scalar fed here, which is why the
//! whole camera is a handful of numbers. Mirrors the projection in main.ts.

const std = @import("std");
const geom = @import("geom.zig");

pub const W: f32 = 960.0;
pub const H: f32 = 600.0;
pub const EYE_H: f32 = 1.2;
pub const NEAR: f32 = 0.4;

const FOV_DEG: f32 = 70.0;
/// base focal (pixels), looking straight ahead. The live `cam_focal` pulls IN from
/// this as the rider leans / narrows focus on something — see camFocal.
pub const FOCAL: f32 = (W / 2.0) / @tan(FOV_DEG / 2.0 * std.math.pi / 180.0);

// the focal pulls IN (widens the FOV — smaller focal) for the deepest of two narrowings: the LEAN into a
// turn (he's watching the corner, not the far mountains) and the rider's ATTENTION on something off the
// road (a crossing cat now; a distracting pig later). Mirrors focalForLean / focalForGaze / the min() in
// main.ts. The lean narrows hardest (to 35%, squared so it snaps in deep in the turn); attention narrows
// gentler (to 61%, linear) — but a crossing cat's attention overshoots 1 (see cat.focus), so it can pull
// harder than a full gaze. They rarely overlap (eyes on the road mid-corner), so the tightest simply wins.
const MIN_FOCAL_FACTOR: f32 = 0.35; // focal at full lean, as a fraction of FOCAL (never 0)
const MIN_GAZE_FOCAL_FACTOR: f32 = 0.61; // focal at full attention, as a fraction of FOCAL

fn focalForLean(lean_frac: f32) f32 {
    return FOCAL * (1.0 - (1.0 - MIN_FOCAL_FACTOR) * lean_frac * lean_frac);
}
fn focalForGaze(attention: f32) f32 {
    return FOCAL * (1.0 - (1.0 - MIN_GAZE_FOCAL_FACTOR) * attention);
}

/// camFocal is the live camera focal for this frame: the tighter (smaller) of the lean pull-in and the
/// attention pull-in. `lean_frac` is |tilt| / MAX_LEAN clamped to 0..1 (the caller knows MAX_LEAN);
/// `attention` is the 0..1+ focus on an off-road distraction (max of the cat focus and, later, the pig
/// gaze focus). The whole projection + backdrop read the returned focal, so they share one camera.
pub fn camFocal(lean_frac: f32, attention: f32) f32 {
    return @min(focalForLean(lean_frac), focalForGaze(attention));
}

pub const ScreenPt = struct { x: f32, y: f32 };

/// project a rider-relative point at `height` metres to a screen pixel, given the
/// live focal `cam_focal`. The perspective divide is by `forward`, so callers must
/// clip to NEAR first (geom.clipNear) — forward is then never ~0.
pub fn project(p: geom.Vec3, cam_focal: f32) ScreenPt {
    return .{
        .x = W / 2.0 + (p.right / p.forward) * cam_focal,
        .y = H / 2.0 - ((p.height - EYE_H) / p.forward) * cam_focal,
    };
}
