//! safari — the WASM ABI shim for the Safari camera's zig core: the ONE module
//! the browser can see. It owns the static world and the draw-command buffer,
//! and exports `renderFrame(...)`, which fills that buffer with screen-space
//! polygons for JS to blit. Everything upstream (geom, camera, world, scene,
//! mountains, render, paint) is pure and never touches JS.
//!
//! Right now this is a toolchain SMOKE TEST — a single trivial export — so the
//! zig→wasm32-freestanding pipeline (build → embed → fetch → instantiate → call)
//! is proven end-to-end before any real geometry lands. `add` will be replaced
//! by `renderFrame` once geom.zig + camera.zig exist.

/// add: the smallest possible export — proof the module builds, links, and
/// exposes a callable function to JS. Delete once renderFrame is real.
export fn add(a: i32, b: i32) i32 {
    return a + b;
}
