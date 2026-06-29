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
/// this as the rider leans / narrows focus (deferred); the static frame uses FOCAL.
pub const FOCAL: f32 = (W / 2.0) / @tan(FOV_DEG / 2.0 * std.math.pi / 180.0);

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
