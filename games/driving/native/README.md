# Native Safari — the desktop screensaver path

The same ride as the browser `/driving`, running as a native executable instead of
in a canvas. This directory is the **native rendering path**; it reuses the exact zig
geometry + render core from [`../wasm/`](../wasm/) (wired in as the `safari` module by
[`../build.zig`](../build.zig)) and only replaces the two things a browser gave for
free: the pixel fill and the window.

- **Browser:** zig core → draw-command buffer → `wasm/blitter.js` fills polygons on a
  `<canvas>` (GPU-accelerated).
- **Native:** *same* zig core → *same* draw-command buffer → `raster.zig` fills pixels
  in software → a thin per-OS shim puts that pixel buffer on screen and feeds keys back.

The code is the authority for how any of this works — every file opens with a
top-of-file comment, and `win32.zig`'s header in particular documents the screensaver
modes and the threading pipeline in detail. This README is the map.

## The pieces

| file | role |
|---|---|
| `raster.zig` | the software rasterizer — consumes the shared `paint.zig` draw buffer (all tags + sky/grass background + sun glow/disc + the camera roll the browser did with `ctx.rotate`) and writes `0x00RRGGBB` pixels. No canvas, no allocator. Supersamples (`SS` knob) then box-downsamples, recovering the anti-aliasing the canvas gave free. |
| `main.zig` | the headless PNG harness — drives the full route and dumps one frame per segment to `snap/native/segNN.png`. A deterministic, argless perceptual contact sheet (**not** a strict gold), and the target that builds on a bare headless box. |
| `png.zig` | a zero-dependency PNG encoder (stored deflate) for the harness. |
| `x11.zig` | the Linux / WSLg live window: aliases an `XImage` onto raster's framebuffer (the pixel format *is* an X11 32-bit TrueColor pixel — zero conversion), `XPutImage`s each frame, `XRender`-scales for fullscreen. |
| `win32.zig` | the Windows window and the `.scr` screensaver. GDI `StretchDIBits` of a top-down BI_RGB DIB (again, raster's pixel *is* the DIB DWORD — no conversion). Runs a frame-parallel render pipeline and the `.scr` command-line modes. See its header comment. |
| `prof.zig` | a standalone deterministic profiler (`ops/prof_safari_native`) that times each render sub-phase in isolation — never timers in the hot path. |

The seam between zig and the pixel fill (the draw-command tag format) is documented in
[`../wasm/paint.zig`](../wasm/paint.zig) — that file is the truth for what `raster.zig`
and `blitter.js` both consume.

## Why native-per-OS instead of SDL

A deliberate call: best native tool per OS, no fat dependency. The reuse that matters is
already isolated — `raster.zig` produces a pixel buffer, and each OS shim only has to
*present a buffer and feed keys*, which is ~100–200 lines apiece (Xlib on Linux, Win32
GDI on Windows, Cocoa later). SDL2's one real benefit would be collapsing those tiny
shims into one; that isn't worth a dependency when each shim is this small.

## Fullscreen is a camera flex, not a stretch

Filling a wider screen widens the camera's horizontal FOV — the rider simply gets more
peripheral vision — rather than zooming or stretching the scene. `camera.FOCAL` stays
frozen at the 960-derived value and `camera.view_w` widens toward the screen aspect, so
object sizes, depth, and the sun's vertical position (hence the whole **sunset clock**)
are untouched and need no recalibration. Out-of-band aspects get plain black letterbox
bars — no heroics.

**Guarantee:** the browser and the PNG harness never call `setViewW`, so they stay pinned
at width 960 and remain bit-identical (the golden PNGs don't move; `ops/check_safari` stays
green). Only the live native windows flex the camera.

## Building, running, checking

- `ops/build_safari_native` — the headless PNG harness (writes the contact sheet).
- `ops/run_safari_x11` — build + open the live Linux/WSLg window (needs `libx11-dev`,
  `libxrender-dev`). `F` toggles fullscreen.
- `ops/build_safari_windows` — cross-compile the Windows build from Linux (no Windows
  SDK). Emits both `safari_win32.exe` and the byte-identical `safari.scr`.
- `ops/build_safari_download` — the Linux binary offered as a download.
- `ops/prof_safari_native` — the sub-phase profiler.
- `ops/check_safari` — the gate: drives the wasm a full course and asserts the paint
  buffer never overflows and both critter culls stay live; **also** fails if `raster.zig`
  grows a file-scope `var` (see reentrancy below). Wired into `ops/check`.

The Linux exe and the Windows `.scr` are offered to visitors at **`/safari_download`**
(served by `zig-server/src/downloads.zig` from `downloads/`, populated by `ops/deploy`).

## raster.zig must stay reentrant

On Windows the frame is ~97% software raster, so `win32.zig` fans `raster.render` across
two worker threads. That means **`raster.zig` must have no file-scope `var`** — a mutable
module global is a cross-thread data race hiding behind a pure-looking signature (it once
shipped as horizontal streaks: per-frame scratch buffers clobbered mid-fill). Per-call
locals only; `threadlocal var` is the sanctioned escape hatch if per-thread scratch is
ever genuinely needed. `ops/check_safari` enforces this so it can't regress. Note this is
scoped to the *worker-parallel* module only — the geometry core (`wasm/paint/render/
safari.zig`) keeps its globals on purpose because it runs single-threaded on the main
thread.

## Performance posture

Native is a software rasterizer with no GPU, so it is slower than the browser (whose
canvas *is* the GPU) — that's expected; native's value is zero-dependency independence.
`ReleaseFast` is load-bearing (~7× faster than Debug at runtime). Linux clears 60fps on
the whole route single-threaded; Windows uses the 2-worker pipeline to get there. Held
reserves if ever needed: more raster threads, or caching the sky+sun backdrop.

## zig 0.16 gotchas that will bite again

- **Cross-directory `@import` by path is forbidden.** The shared core is pulled in as a
  named module (`safari`) in `build.zig` — that's the fix, not a relative path.
- **Xlib:** use the `X`-prefixed *function* forms (`XDefaultScreen`, `XRootWindow`, …);
  zig's translate-c chokes on the classic `DefaultScreen()`-style macros. `XDestroyImage`
  is also a macro — call `image.*.f.destroy_image.?()` after nulling `image.data` (which
  points at our static buffer, so it must not be freed).
- **`std.os.windows`** ships the base types + kernel32 but **no user32/gdi32** — declare
  those externs inline (the standard no-SDK move). `std.Thread.Mutex`/`Condition` are gone
  (moved under `std.Io`, needing an `Io` handle), which is why the win32 pipeline is
  lock-free atomics. `std.process.Args` also needs an OS handle, so the `.scr` flag is
  parsed straight off `GetCommandLineW`.
- **64-bit native `usize` surfaces latent bugs wasm32 hid** (an `@intCast` on segment
  counts, caught the first time the core ran natively).

## Deferred

- **macOS** shim (Cocoa `NSWindow` + `CGImage`) — the one platform not yet built.
- **Windows fullscreen aspect-fit:** the `.scr` currently stretches the 16:10 scene to
  the monitor (mild on 16:9); the fix is to borrow x11.zig's `view_w`-widening + letterbox.
- Testing the Linux exe on a real X session (not just WSLg).
