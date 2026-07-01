//! win32 — the Windows live-window layer for the native Safari renderer.
//!
//! This is the Windows sibling of native/x11.zig: the per-platform shim that owns a window
//! and the event loop, nothing else. The reusable core is unchanged — raster.zig fills a
//! pixel buffer from the shared wasm geometry (via safari.zig) — and this file just shows
//! that buffer in a Win32 window and pumps the message queue. Only the blit differs: GDI's
//! StretchDIBits of a top-down 32-bit DIB, where X11 used an XImage + XRender.
//!
//! PIXEL FORMAT. raster fills 0x00RRGGBB per u32. A GDI 32-bit BI_RGB DIB is exactly that
//! DWORD layout (bytes B,G,R,0 little-endian), so the buffer feeds StretchDIBits directly with
//! no per-pixel conversion — the same free aliasing the X11 layer got from a TrueColor visual.
//! biHeight is NEGATIVE so the DIB is top-down (row 0 = top), matching our buffer's order.
//!
//! ANTI-ALIASING. We hand GDI the SUPERSAMPLED render (1920×1200) rather than the box-
//! downsampled 960×600, and let GDI resample it to the window with the HALFTONE stretch mode
//! (bilinear-quality). At the 960 window that's a 2:1 downscale ≈ the manual box filter;
//! expanded up to ~1080p it's near 1:1, so the snowcap keeps its AA.
//!
//! PRESENTATION (double-buffered). We do NOT StretchDIBits straight onto the window: HALFTONE
//! scaling is slow, and the compositor samples the window surface mid-write (top-to-bottom),
//! catching a half-updated frame — horizontal tearing streaks. So we scale into an OFF-SCREEN
//! memory DC (a screen-compatible bitmap the size of the client area), then present the finished
//! frame with a single fast 1:1 BitBlt. The on-screen write is then one quick copy, too brief to
//! be caught half-done. The memory bitmap is rebuilt only on resize.
//!
//! THREADING (the frame-parallel pipeline). Profiling showed the frame is ~97% software raster
//! (raster.render, 15–29 ms) and ~3% geometry (renderFrame, 0.68 ms) — single-threaded that's
//! ~31 ms/frame (~32 fps), the sluggishness. But raster.render is a PURE function of (fb, words,
//! tilt, sky, sun), and the depth sort that fixes paint order lives entirely in the geometry
//! step (render.zig). So we split the work: the MAIN thread runs the sequential geometry (it
//! owns safari's globals — the one draw buffer + rider state) and snapshots each frame's draw-
//! words into a ring slot; two WORKER threads each rasterize a snapshot into its own pixel
//! buffer in parallel; the main thread blits finished frames IN ORDER at the 60 fps cadence.
//! Measured ~6.5 ms/frame with 2 workers (clears 60 fps); the shared core + golden PNG harness
//! are untouched.
//!
//! It's LOCK-FREE: a slot is owned by exactly one thread in each phase, so the only shared word
//! is its `state` enum. The atomic transitions carry the buffer handoff — main's draw-words
//! writes are release-published by the store to .queued and a worker acquires them by the CAS
//! that claims the slot (.queued→.rendering, so two workers never grab the same one); the
//! worker's pixels are release-published by the store to .ready and main acquires them before
//! the blit. Idle workers (ring full — the steady state, since they outrun the 60 fps display)
//! just Sleep(1); that poll costs nothing against the frame budget.
//!
//! FIRST STEP scope. Still the design width (never calls safari.setViewW), so the SCENE matches
//! the browser + golden PNG harness (only the final resample is GDI's). No adaptive-camera
//! fullscreen and no .scr logistics yet — those are the next steps.
//!
//! std.os.windows (zig 0.16) ships the base types + kernel32 but no user32/gdi32, so the
//! GUI/GDI surface is declared inline below — the standard approach for a no-SDK cross build.
//!
//! Cross-compiled to x86_64-windows by ops/build_safari_windows (zig build -Dwin32). Controls
//! mirror the browser/x11 minimally for now: SPACE pause/resume · Q/Esc quit.

const std = @import("std");
const safari = @import("safari");
const raster = @import("raster.zig");
const w = std.os.windows;

// --- base types (aliases into std.os.windows + the two the stdlib omits) ---
const BOOL = w.BOOL;
const HWND = w.HWND;
const HINSTANCE = w.HINSTANCE;
const HDC = w.HDC;
const HMENU = w.HMENU;
const HICON = w.HICON;
const HCURSOR = w.HCURSOR;
const HBRUSH = w.HBRUSH;
const UINT = w.UINT;
const DWORD = w.DWORD;
const WORD = w.WORD;
const LONG = w.LONG;
const ATOM = w.ATOM;
const LPVOID = w.LPVOID;
const WCHAR = w.WCHAR;
const WPARAM = usize; // UINT_PTR
const LPARAM = isize; // LONG_PTR
const LRESULT = isize; // LONG_PTR

const HBITMAP = *opaque {};
const HGDIOBJ = *anyopaque;

// --- Win32 structs (extern layout) ---
const POINT = extern struct { x: LONG, y: LONG };
const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

// --- Win32 constants ---
const CS_VREDRAW: UINT = 0x0001;
const CS_HREDRAW: UINT = 0x0002;
const CS_OWNDC: UINT = 0x0020;
const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: c_int = 5;
const PM_REMOVE: UINT = 0x0001;
const WM_DESTROY: UINT = 0x0002;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_QUIT: UINT = 0x0012;
const VK_ESCAPE: WPARAM = 0x1B;
const VK_SPACE: WPARAM = 0x20;
const VK_Q: WPARAM = 0x51;
const SRCCOPY: DWORD = 0x00CC0020;
const DIB_RGB_COLORS: UINT = 0;
const BI_RGB: DWORD = 0;
const HALFTONE: c_int = 4; // high-quality (bilinear-ish) stretch; needs SetBrushOrgEx after
const IDC_ARROW: usize = 32512;

// --- extern Win32 functions (no SDK: declared against the system import libs) ---
extern "user32" fn RegisterClassW(*const WNDCLASSW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, c_int, c_int, c_int, c_int, ?HWND, ?HMENU, ?HINSTANCE, ?LPVOID) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn AdjustWindowRect(*RECT, DWORD, BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
extern "kernel32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
extern "gdi32" fn StretchDIBits(HDC, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int, *const anyopaque, *const BITMAPINFOHEADER, UINT, DWORD) callconv(.winapi) c_int;
extern "gdi32" fn SetStretchBltMode(HDC, c_int) callconv(.winapi) c_int;
extern "gdi32" fn SetBrushOrgEx(HDC, c_int, c_int, ?*POINT) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleBitmap(HDC, c_int, c_int) callconv(.winapi) ?HBITMAP;
extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, HDC, c_int, c_int, DWORD) callconv(.winapi) BOOL;

// --- frame geometry (design aspect — same scene the browser/PNG path draws) ---
const W: usize = raster.W; // 960 — the window's default CLIENT size
const H: usize = raster.H; // 600
const W_i: c_int = @intCast(W);
const H_i: c_int = @intCast(H);
const SW: usize = raster.SW; // 1920 — the supersampled render GDI resamples from (the AA source)
const SH: usize = raster.SH; // 1200
const SW_i: c_int = @intCast(SW);
const SH_i: c_int = @intCast(SH);
const FRAME_MS: i64 = 16; // ~60 fps display budget

// Top-down 32-bit BI_RGB DIB over a slot's supersampled buffer — negative height means row 0 is the top.
const bmih = BITMAPINFOHEADER{
    .biSize = @sizeOf(BITMAPINFOHEADER),
    .biWidth = SW_i,
    .biHeight = -SH_i,
    .biPlanes = 1,
    .biBitCount = 32,
    .biCompression = BI_RGB,
    .biSizeImage = 0,
    .biXPelsPerMeter = 0,
    .biYPelsPerMeter = 0,
    .biClrUsed = 0,
    .biClrImportant = 0,
};

// --- the frame-parallel pipeline ---
const NUM_WORKERS = 2; // raster workers; 2 clears 60 fps and leaves cores for blit + OS (measured)
const RING = 4; // frame slots in flight: 2 rendering + 1 displaying + 1 free to produce into
const MAX_WORDS = (1 << 20) / 4; // == paint.zig CAP_WORDS — the draw buffer never exceeds this

// A slot moves empty → queued (main filled it) → rendering (a worker claimed it) → ready (worker
// done) → empty (main displayed it). `state` is the only word shared between threads; the atomic
// acquire/release on it publishes each phase's buffer writes to the next owner (see the header).
const SlotState = enum(u8) { empty, queued, rendering, ready };
const Slot = struct {
    px: [SW * SH]u32 = undefined, // this frame's supersampled render (a worker fills it)
    words: [MAX_WORDS]u32 = undefined, // this frame's draw-command snapshot (main copies it in)
    words_len: usize = 0,
    tilt: f32 = 0,
    top: u32 = 0,
    horizon: u32 = 0,
    sun: raster.SunPos = .{ .visible = false, .x = 0, .y = 0, .scale = 0 },
    state: std.atomic.Value(SlotState) = .init(.empty),
};

var slots: [RING]Slot = undefined; // ~41 MB of .bss — committed on demand by the OS
var g_quit = std.atomic.Value(bool).init(false); // tells the workers to exit
var g_running: bool = true; // main loop (main thread only; set by the WndProc)
var g_auto: bool = true; // SPACE pause: main stops producing + displaying (freeze)

// double-buffer state (main thread only): an off-screen DC we scale into, its client-sized
// bitmap, and the size that bitmap is built for (rebuilt on resize). See PRESENTATION above.
var g_memdc: ?HDC = null;
var g_bmp: ?HBITMAP = null;
var g_bmp_w: c_int = 0;
var g_bmp_h: c_int = 0;

// a worker: claim any queued slot (CAS, so two workers never take the same one), rasterize it into
// its own buffer, mark it ready. When there's nothing queued, briefly poll. Repeat until quit.
fn worker() void {
    while (!g_quit.load(.acquire)) {
        const claimed: ?usize = blk: {
            for (&slots, 0..) |*s, i| {
                if (s.state.cmpxchgStrong(.queued, .rendering, .acquire, .monotonic) == null) break :blk i;
            }
            break :blk null;
        };
        if (claimed) |i| {
            const s = &slots[i]; // sole owner of this slot's buffers until we publish .ready
            raster.render(.{ .px = &s.px, .w = SW, .h = SH }, s.words[0..s.words_len], s.tilt, s.top, s.horizon, s.sun);
            s.state.store(.ready, .release);
        } else {
            Sleep(1); // ring full or drained — negligible against the 60 fps budget
        }
    }
}

fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            g_running = false;
            PostQuitMessage(0);
            return 0;
        },
        WM_KEYDOWN => {
            switch (wParam) {
                VK_SPACE => g_auto = !g_auto,
                VK_ESCAPE, VK_Q => _ = DestroyWindow(hwnd),
                else => {},
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

pub fn main() !void {
    const hinstance = GetModuleHandleW(null);
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("SafariDriveWindow");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Safari Drive");

    const wc = WNDCLASSW{
        .style = CS_OWNDC | CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .hInstance = hinstance,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (RegisterClassW(&wc) == 0) return error.RegisterClass;

    // size the window so the CLIENT area is exactly 960×600 (borders/caption sit outside it),
    // giving a crisp 1:1 blit until the adaptive-camera fullscreen step lands.
    var wr = RECT{ .left = 0, .top = 0, .right = W_i, .bottom = H_i };
    _ = AdjustWindowRect(&wr, WS_OVERLAPPEDWINDOW, .FALSE);

    const hwnd = CreateWindowExW(0, class_name, title, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, wr.right - wr.left, wr.bottom - wr.top, null, null, hinstance, null) orelse
        return error.CreateWindow;
    _ = ShowWindow(hwnd, SW_SHOW);

    const hdc = GetDC(hwnd) orelse return error.NoDC; // CS_OWNDC → valid for the window's life
    // off-screen DC we scale into (then BitBlt to the window) — the double buffer that kills tearing.
    g_memdc = CreateCompatibleDC(hdc) orelse return error.NoMemDC;
    _ = SetStretchBltMode(g_memdc.?, HALFTONE);
    _ = SetBrushOrgEx(g_memdc.?, 0, 0, null); // HALFTONE requires this or the brush origin misaligns

    for (&slots) |*s| s.state = .init(.empty);
    var workers: [NUM_WORKERS]std.Thread = undefined;
    for (&workers) |*t| t.* = try std.Thread.spawn(.{}, worker, .{});

    var freq: i64 = 1;
    _ = QueryPerformanceFrequency(&freq);

    var produce_seq: usize = 0; // next frame to run geometry for
    var display_seq: usize = 0; // next frame to blit (strict order)

    while (g_running) {
        var start: i64 = 0;
        _ = QueryPerformanceCounter(&start);

        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE).toBool()) {
            if (msg.message == WM_QUIT) {
                g_running = false;
                break;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        if (!g_running) break;

        if (g_auto) {
            displayNext(hdc, hwnd, &display_seq);
            produce(&produce_seq); // refill the ring after freeing a slot
        }

        // pace to the display budget: sleep only the time LEFT after the tick's work.
        var now: i64 = 0;
        _ = QueryPerformanceCounter(&now);
        const elapsed_ms = @divTrunc((now - start) * 1000, freq);
        if (elapsed_ms < FRAME_MS) Sleep(@intCast(FRAME_MS - elapsed_ms));
    }

    // tear down the workers cleanly before the window/DC go away. They poll g_quit at the top of
    // their loop (waking within the Sleep(1) at worst), so no wakeup signal is needed.
    g_quit.store(true, .release);
    for (&workers) |*t| t.join();

    if (g_bmp) |b| _ = DeleteObject(@ptrCast(b));
    if (g_memdc) |m| _ = DeleteDC(m);
}

// run the cheap sequential geometry (sim + depth sort + draw-command fill — all on safari's globals,
// so main-thread-only) for as many EMPTY ring slots as we can, snapshotting each into its slot and
// handing it to the workers. Stops when the ring is full (workers/display haven't caught up).
fn produce(produce_seq: *usize) void {
    while (true) {
        const s = &slots[produce_seq.* % RING];
        if (s.state.load(.acquire) != .empty) return; // ring full — nothing to produce into

        safari.advance();
        _ = safari.renderFrame();
        // the slot is .empty → no worker looks at it, so fill its buffers before publishing .queued.
        const words = safari.frameWords();
        @memcpy(s.words[0..words.len], words);
        s.words_len = words.len;
        s.tilt = safari.riderTilt();
        s.top = safari.skyTop();
        s.horizon = safari.skyHorizon();
        s.sun = .{ .visible = safari.sunVisible() == 1, .x = safari.sunX(), .y = safari.sunY(), .scale = safari.sunScale() };

        s.state.store(.queued, .release); // publish: a worker's claim CAS acquires the writes above
        produce_seq.* += 1;
    }
}

// if the next frame (in strict produced order) is rasterized, blit it and free its slot. At most one
// frame per tick, so the display paces at 60 fps even though the workers run well ahead.
fn displayNext(hdc: HDC, hwnd: HWND, display_seq: *usize) void {
    const s = &slots[display_seq.* % RING];
    if (s.state.load(.acquire) != .ready) return; // workers haven't finished it — hold the current frame

    var rc: RECT = undefined;
    _ = GetClientRect(hwnd, &rc);
    const cw = rc.right - rc.left;
    const ch = rc.bottom - rc.top;
    if (cw <= 0 or ch <= 0) return; // minimised — nothing to show (don't free the slot; keep it for later)

    // (re)build the off-screen bitmap when the client size changes. It's screen-COMPATIBLE (created
    // against the window DC, not the mem DC — else it'd be 1-bpp monochrome).
    if (g_bmp == null or cw != g_bmp_w or ch != g_bmp_h) {
        if (g_bmp) |b| _ = DeleteObject(@ptrCast(b));
        g_bmp = CreateCompatibleBitmap(hdc, cw, ch) orelse return;
        _ = SelectObject(g_memdc.?, @ptrCast(g_bmp.?));
        g_bmp_w = cw;
        g_bmp_h = ch;
    }

    // scale the supersampled frame into the off-screen buffer (HALFTONE), then present it in one
    // fast 1:1 BitBlt — so the on-screen write is too brief for the compositor to catch half-done.
    _ = StretchDIBits(g_memdc.?, 0, 0, cw, ch, 0, 0, SW_i, SH_i, &s.px, &bmih, DIB_RGB_COLORS, SRCCOPY);
    _ = BitBlt(hdc, 0, 0, cw, ch, g_memdc.?, 0, 0, SRCCOPY);

    s.state.store(.empty, .release); // freed for produce() to reuse
    display_seq.* += 1;
}
