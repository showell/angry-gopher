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

/// A point in a segment's bottom-left frame: `a` along, `x` across-from-left.
pub const AX = struct { a: f32, x: f32 };

/// nextToCur maps a point from the NEXT segment's BL frame into the CURRENT
/// segment's, across the join — the frame fusion. LEFT and RIGHT are NOT mirror
/// images: a left turn fuses on the end-left edge (origin is the inner corner), a
/// right turn fuses on the end-right edge and pays a width shift. Mirrors
/// nextToCur() in intersection.ts. `right` is the turn direction (sign > 0).
pub fn nextToCur(a_b: f32, x_b: f32, L: f32, theta: f32, right: bool, W: f32) AX {
    const c = @cos(theta);
    const s = @sin(theta);
    if (!right) {
        return .{ .a = a_b * c + x_b * s + L, .x = x_b * c - a_b * s };
    }
    return .{ .a = a_b * c - x_b * s + W * s + L, .x = x_b * c + a_b * s + W * (1.0 - c) };
}

/// curToNext is the inverse of nextToCur: a point in the CURRENT segment's BL frame
/// expressed in the NEXT segment's BL frame, across the same join. Used to draw the
/// joint just BEHIND the rider — the previous segment's corner mapped FORWARD into the
/// rider's (current) segment, so the pavement he's still crossing doesn't vanish.
/// Mirrors curToNext() in intersection.ts. `right` is the turn direction (sign > 0).
pub fn curToNext(a: f32, x: f32, L: f32, theta: f32, right: bool, W: f32) AX {
    const c = @cos(theta);
    const s = @sin(theta);
    if (!right) {
        const a0 = a - L;
        return .{ .a = a0 * c - x * s, .x = a0 * s + x * c };
    }
    const a0 = a - L - W * s;
    const x0 = x - W * (1.0 - c);
    return .{ .a = a0 * c + x0 * s, .x = -a0 * s + x0 * c };
}

/// lineMeet returns where two infinite lines cross in the rider frame: line A through
/// a0 toward a1, line B through b0 toward b1. Used for the corner's outer apex, where
/// the two segments' outer shoulders (extended into the joint) meet. A real turn has a
/// non-zero angle, so the lines are never parallel. Mirrors lineMeet() in intersection.ts.
pub fn lineMeet(a0: RiderPt, a1: RiderPt, b0: RiderPt, b1: RiderPt) RiderPt {
    const dax = a1.right - a0.right;
    const daf = a1.forward - a0.forward;
    const dbx = b1.right - b0.right;
    const dbf = b1.forward - b0.forward;
    const t = ((b0.right - a0.right) * dbf - (b0.forward - a0.forward) * dbx) / (dax * dbf - daf * dbx);
    return .{ .right = a0.right + t * dax, .forward = a0.forward + t * daf };
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
