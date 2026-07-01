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
//! ANTI-ALIASING. We hand GDI the SUPERSAMPLED render (big_px, 1920×1200) rather than the
//! box-downsampled 960×600, and let GDI resample it to the window with the HALFTONE stretch
//! mode (bilinear-quality). At the 960 window that's a 2:1 downscale ≈ the manual box filter;
//! expanded up to ~1080p it's near 1:1, so the snowcap keeps its AA; larger still it
//! interpolates from 1920 instead of blocking a 960 source up. (Rendering at the monitor's
//! true resolution is the deeper cure — that's the adaptive-camera step below.)
//!
//! FIRST STEP (this file). The goal here is only to get frames rendering on a clock-tick
//! flipbook rhythm — an auto-advancing window at the DESIGN width (960×600), no adaptive
//! camera and no screensaver logistics yet. It never calls safari.setViewW, so the SCENE is
//! the same geometry the browser + golden PNG harness draw (only the final resample is GDI's,
//! not our box filter). When the window isn't the exact client size the DIB just stretches to
//! fill it (aspect can distort on resize); the aspect-matched fullscreen fit (the view_w
//! widening x11.zig does) is the NEXT step.
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

// --- frame geometry (design aspect — same scene the browser/PNG path draws) ---
const W: usize = raster.W; // 960 — the window's default CLIENT size
const H: usize = raster.H; // 600
const W_i: c_int = @intCast(W);
const H_i: c_int = @intCast(H);
const SW: usize = raster.SW; // 1920 — the supersampled render GDI resamples from (the AA source)
const SH: usize = raster.SH; // 1200
const SW_i: c_int = @intCast(SW);
const SH_i: c_int = @intCast(SH);
const FRAME_MS: i64 = 16; // ~60 fps budget

// Static .bss render target (no allocator): the supersampled AA buffer. We blit THIS directly
// and let GDI HALFTONE resample it to the window, so there's no manual downsample step here.
var big_px: [SW * SH]u32 = undefined;

// Top-down 32-bit BI_RGB DIB over big_px — negative height means row 0 is the top.
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

// Window state the WndProc owns (single window, so file-scope is honest here).
var g_running: bool = true;
var g_auto: bool = true;

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
    _ = SetStretchBltMode(hdc, HALFTONE);
    _ = SetBrushOrgEx(hdc, 0, 0, null); // HALFTONE requires this or the brush origin misaligns

    var freq: i64 = 1;
    _ = QueryPerformanceFrequency(&freq);

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

        if (g_auto) safari.advance();
        renderScene();

        var rc: RECT = undefined;
        _ = GetClientRect(hwnd, &rc);
        _ = StretchDIBits(hdc, 0, 0, rc.right - rc.left, rc.bottom - rc.top, 0, 0, SW_i, SH_i, &big_px, &bmih, DIB_RGB_COLORS, SRCCOPY);

        // pace to the frame budget: sleep only the time LEFT after the work, so motion stays
        // even regardless of render cost. Sleep granularity is coarse (~15 ms) but fine for a
        // flipbook; QPC keeps the accounting honest as render cost grows.
        var now: i64 = 0;
        _ = QueryPerformanceCounter(&now);
        const elapsed_ms = @divTrunc((now - start) * 1000, freq);
        if (elapsed_ms < FRAME_MS) Sleep(@intCast(FRAME_MS - elapsed_ms));
    }
}

// rasterize the current rider frame into the supersampled buffer (the same render call the PNG
// harness + x11 make). We DON'T downsample here — GDI does the resampling in the blit (HALFTONE),
// which is what keeps expanded windows crisp instead of blocking up a pre-shrunk 960 frame.
fn renderScene() void {
    _ = safari.renderFrame();
    const sun = raster.SunPos{
        .visible = safari.sunVisible() == 1,
        .x = safari.sunX(),
        .y = safari.sunY(),
        .scale = safari.sunScale(),
    };
    const big = raster.Fb{ .px = &big_px, .w = SW, .h = SH };
    raster.render(big, safari.frameWords(), safari.riderTilt(), safari.skyTop(), safari.skyHorizon(), sun);
}
