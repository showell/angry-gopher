//! build.zig for the NATIVE Safari renderer (the Linux screensaver core).
//!
//! It compiles games/driving/native/main.zig and wires the shared zig core
//! (games/driving/wasm/safari.zig) in as a named module "safari", so the native renderer
//! reuses the EXACT same geometry/render code the WASM build embeds — only the blit
//! differs (raster.zig vs the browser canvas). Output: zig-out/bin/safari_native.
//!
//! Built + run by ops/build_safari_native. Native + ReleaseFast are hardcoded (no -D
//! knobs) so the dev loop is one predictable command, like the other ops scripts.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{}); // native host
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const safari_mod = b.createModule(.{
        .root_source_file = b.path("wasm/safari.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "safari_native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("safari", safari_mod);
    b.installArtifact(exe);

    // The per-phase profiler (ops/prof_safari_native) — headless, no X11, deterministic.
    const prof = b.addExecutable(.{
        .name = "safari_prof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/prof.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    prof.root_module.addImport("safari", safari_mod);
    b.installArtifact(prof);

    // The live X11 window (the Linux/WSLg display layer) is opt-in via -Dwindow, so the
    // default `zig build` (the headless PNG harness) needs no X11 dev libs — it still
    // builds on a bare headless box (e.g. the Droplet, which only renders frames to disk).
    const want_window = b.option(bool, "window", "build the X11 live-window app (needs libx11-dev)") orelse false;
    if (want_window) {
        const win = b.addExecutable(.{
            .name = "safari_x11",
            .root_module = b.createModule(.{
                .root_source_file = b.path("native/x11.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true, // @cImport(Xlib) needs libc
            }),
        });
        win.root_module.addImport("safari", safari_mod);
        win.root_module.linkSystemLibrary("X11", .{});
        win.root_module.linkSystemLibrary("Xrender", .{}); // the scaled fullscreen blit (needs libxrender-dev)
        b.installArtifact(win);
    }

    // The Windows .exe (the Win32/GDI display layer) is opt-in via -Dwin32 and always
    // CROSS-compiled to x86_64-windows — we build it from the Linux box, so it needs its own
    // safari module compiled for that target (the native-host safari_mod above won't do). No
    // SDK/libc: it links the bundled system import libs (user32/gdi32/kernel32) and declares
    // the GUI surface inline. subsystem=.Windows suppresses the console window.
    const want_win32 = b.option(bool, "win32", "cross-build the Windows .exe (x86_64-windows)") orelse false;
    if (want_win32) {
        const win_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
        const win_safari = b.createModule(.{
            .root_source_file = b.path("wasm/safari.zig"),
            .target = win_target,
            .optimize = optimize,
        });
        const w32 = b.addExecutable(.{
            .name = "safari_win32",
            .root_module = b.createModule(.{
                .root_source_file = b.path("native/win32.zig"),
                .target = win_target,
                .optimize = optimize,
            }),
        });
        w32.subsystem = .Windows;
        w32.root_module.addImport("safari", win_safari);
        w32.root_module.linkSystemLibrary("user32", .{});
        w32.root_module.linkSystemLibrary("gdi32", .{});
        b.installArtifact(w32);
    }
}
