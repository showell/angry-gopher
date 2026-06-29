//! safari — the WASM ABI shim: the ONE module the browser can see. It owns the
//! static world and exposes the draw buffer + renderFrame. Everything upstream
//! (geom, camera, world, tree, paint, render) is pure and never touches JS.
//!
//! The non-zig side is a dumb plain-JS blitter: it reads bufPtr() once, builds
//! typed-array views over linear memory, and on each frame calls renderFrame(...),
//! then fills the polygons in the [color][nPoints][x,y…] buffer. No logic there.

const world = @import("world.zig");
const render = @import("render.zig");
const paint = @import("paint.zig");

var the_world: world.Segment = undefined;
var built = false;

/// renderFrame fills the draw buffer with the frame for the given camera pose — the
/// rider's position along/across the segment centre line and his look yaw — and
/// returns the number of bytes written. The blitter walks that many bytes from
/// bufPtr(). Everything that later steers the view (gaze, focus, pitch, roll) is
/// just more scalars added to this signature.
export fn renderFrame(cam_along: f32, cam_across: f32, cam_yaw: f32) u32 {
    if (!built) {
        the_world = world.buildWorld();
        built = true;
    }
    paint.reset();
    render.frame(the_world, cam_along, cam_across, cam_yaw);
    return paint.byteLen();
}

/// bufPtr is the byte offset of the draw buffer in linear memory.
export fn bufPtr() u32 {
    return paint.ptr();
}

/// segLength is the current segment's length (m) — the blitter reads it to loop the
/// straight, so the length lives in exactly one place (world.zig), not the JS.
export fn segLength() f32 {
    if (!built) {
        the_world = world.buildWorld();
        built = true;
    }
    return the_world.length;
}
