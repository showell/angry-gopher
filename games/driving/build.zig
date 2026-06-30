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
}
