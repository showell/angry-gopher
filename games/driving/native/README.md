# Native Safari: the desktop screensaver

The same ride as the browser's `/driving`, as a native program. It reuses
the Zig geometry and render core in [`../wasm/`](../wasm/) (the `safari`
module in [`../build.zig`](../build.zig)) and supplies the two things a
browser gave: the pixel fill and the window.

- **Browser:** the Zig core writes a draw-command buffer, and
  `../wasm/blitter.js` fills its polygons on a `<canvas>`.
- **Native:** the same core writes the same buffer, `raster.zig` fills
  pixels in software, and a small shim for each OS puts the pixels on screen
  and feeds keys back.

[`../wasm/paint.zig`](../wasm/paint.zig) defines the draw-command format
both consume. Every file here opens with a comment saying what it does;
`win32.zig`'s covers the screensaver modes and the threading pipeline.

## The pieces

`raster.zig` is the software rasterizer: it reads the draw buffer and writes
`0x00RRGGBB` pixels, supersampling then downsampling for anti-aliasing. The
shims are `x11.zig` (the Linux and WSLg window) and `win32.zig` (the Windows
window and the `.scr` screensaver). Each hands raster's framebuffer to the OS
as is, since its pixel format is the native one. `main.zig` is a headless
harness that drives the whole route and writes one PNG a segment to
`games/driving/snap/native/`, a contact sheet for the eye and the target that
builds on a headless box. `prof.zig` times each render phase apart from the hot path.

## One shim per OS

Each OS gets its own native tool, and the build stays free of large
dependencies. The reuse that matters is already in `raster.zig`; a shim only
presents a buffer and feeds keys, about 100 to 200 lines each (Xlib on
Linux, Win32 GDI on Windows). SDL would merge those small shims into one at
the cost of a dependency.

## Fullscreen widens the camera

A wider screen widens the camera's horizontal field of view: the rider sees
more to the sides, and the scene keeps its scale. `camera.FOCAL` stays at its
960-pixel value while `camera.view_w` widens toward the screen's aspect, so
object sizes, depth and the sun's height (the **sunset clock**) stay as
tuned. An aspect past the range gets plain black letterbox bars.

**The browser and the PNG harness stay at width 960**: only the live native
windows call `setViewW`. So they stay bit-identical, and `ops/check_safari`
holds.

## Building, running, checking

- `ops/build_safari_native`: the headless PNG harness.
- `ops/run_safari_x11`: build and open the live Linux or WSLg window (needs
  `libx11-dev` and `libxrender-dev`). `F` toggles fullscreen.
- `ops/build_safari_windows`: cross-compile the Windows build from Linux,
  with the Windows SDK left out. It writes `safari_win32.exe` and the
  byte-identical `safari.scr`.
- `ops/build_safari_download`: the Linux binary offered as a download.
- `ops/prof_safari_native`: the phase profiler.
- `ops/check_safari` (in `ops/check`): drives the wasm over the whole course,
  checks the paint buffer and both critter culls, and fails on a file-scope
  `var` in `raster.zig` (below).

Visitors download the Linux program and the Windows `.scr` at
**`/safari_download`** (`zig-server/src/downloads.zig`, serving `downloads/`
from the working directory). `ops/build_downloads` fills `downloads/`. It is
one of `zig-server/assets.zon`'s `.site` directories, so zig-metal-unikernel's
image and judge carry it, and each needs it built before laying out a site
disk.

## raster.zig stays reentrant

On Windows the frame is almost all software raster, so `win32.zig` spreads
`raster.render` across two worker threads. So **`raster.zig` keeps all state
in per-call locals**: a file-scope `var` is a data race behind a pure-looking
signature, and it once showed as horizontal streaks from scratch buffers
clobbered mid-fill. `threadlocal var` is the escape for per-thread scratch.
`ops/check_safari` enforces the rule. It applies to this worker-parallel
module alone; the core (`../wasm/paint.zig`, `../wasm/render.zig`,
`../wasm/safari.zig`) keeps its globals on purpose, since it runs on the main
thread.

## Performance

Native rasterizes in software, so it runs slower than the browser's
GPU-backed canvas; in return it stands alone. Build it `ReleaseFast`, which
is several times faster than Debug. Linux reaches 60 fps on one thread;
Windows uses the two-worker pipeline. More raster threads, or caching the sky
and sun backdrop, are the reserves.

## Zig gotchas

- **Cross-directory `@import` by path is forbidden.** `build.zig` brings the
  shared core in as the named module `safari`.
- **Xlib:** use the `X`-prefixed function forms (`XDefaultScreen`,
  `XRootWindow`); translate-c chokes on the `DefaultScreen()`-style macros.
  `XDestroyImage` is a macro too: call `image.*.f.destroy_image.?()` after
  setting `image.data` to null, since it points at our static buffer.
- **`std.os.windows`** has the base types and kernel32 but leaves out user32
  and gdi32: declare those externs inline. `std.Thread.Mutex` and
  `Condition` moved under `std.Io`, so the win32 pipeline uses lock-free
  atomics. `std.process.Args` needs an OS handle too, so the `.scr` flag is
  parsed from `GetCommandLineW`.
- **A 64-bit `usize` surfaces bugs wasm32 hid**, such as an `@intCast` on
  segment counts.

## Open work

- A **macOS** shim (Cocoa `NSWindow` and `CGImage`).
- **Windows fullscreen** stretches the 16:10 scene to the monitor (mild on
  16:9); x11.zig's `view_w` widening and letterbox would fit it.
- A run of the Linux program on a real X session, beyond WSLg.
