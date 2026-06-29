//! geom — pure rider-relative geometry: the coordinate types, the world→rider
//! transform, the ground curvature, and near-plane clipping. No projection (that is
//! camera.zig), no drawing, no allocation. The math leaf the rest of the camera
//! stands on. Mirrors the rider-relative half of view.ts + scenery.ts.

/// A ground-plane point measured FROM THE RIDER: how far forward (down his look
/// axis) and how far to his right. The fundamental coordinate of the whole scene.
pub const RiderPt = struct { right: f32, forward: f32 };

/// A rider-relative vertex carrying a height off the ground — what the road quads
/// (and later raised structures) clip and project as.
pub const Vec3 = struct { right: f32, forward: f32, height: f32 };

/// The local ground is a gentle spherical plateau: a point drops this far below the
/// rider's tangent plane at horizontal distance d, so the road bends toward a finite
/// horizon instead of a vanishing point at infinity. Larger radius = gentler.
pub const GROUND_RADIUS: f32 = 100000.0;
pub fn groundDrop(right: f32, forward: f32) f32 {
    return (right * right + forward * forward) / (2.0 * GROUND_RADIUS);
}

/// toRider maps a point in a segment's bottom-left frame — `a` along the segment,
/// `x` across from its LEFT edge (0..width) — into the rider's frame, given his pose
/// (along/across the segment's centre line, and his look angle `yaw`). His pose is
/// centre-relative, so the half-width `hw` shifts x to from-the-left. Matches
/// toRider() in view.ts.
pub fn toRider(a: f32, x: f32, cam_along: f32, cam_across: f32, yaw: f32, hw: f32) RiderPt {
    const dA = a - cam_along;
    const dX = x - (cam_across + hw);
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{ .forward = dA * c + dX * s, .right = -dA * s + dX * c };
}

/// Clip a rider-frame polygon (vertices carrying height) against the near plane at
/// `near` metres forward, so no vertex sits behind the eye where the perspective
/// divide would fling it across the screen. Writes the clipped vertices into `out`
/// and returns the count (0..in.len+1; fewer than 3 means the caller skips the poly).
/// Mirrors clipNear() in scenery.ts.
pub fn clipNear(in: []const Vec3, near: f32, out: []Vec3) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        const a = in[i];
        const b = in[(i + 1) % in.len];
        const a_in = a.forward >= near;
        const b_in = b.forward >= near;
        if (a_in) {
            out[n] = a;
            n += 1;
        }
        if (a_in != b_in) {
            const f = (near - a.forward) / (b.forward - a.forward);
            out[n] = .{
                .right = a.right + f * (b.right - a.right),
                .forward = near,
                .height = a.height + f * (b.height - a.height),
            };
            n += 1;
        }
    }
    return n;
}
