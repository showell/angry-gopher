const std = @import("std");

// build.zig is the zig port's answer to Go's embed.go: the one place where
// front-end assets that live ELSEWHERE in the repo get baked into the binary.
// @embedFile alone can't reach outside the package dir, so each external asset
// is wired in here as a named import and pulled in with @embedFile("<name>").
//
//   zig build run     -> build + run the server (serves /driving on :9001)
//   zig build         -> just build (binary in zig-build/)
//
// The driving bundle must exist first: run `ops/build_driving` from the repo
// root (esbuild over games/driving/main.ts -> games/driving/app.js).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Embedded front-end assets (the embed.go analog). Referenced in code as
    // @embedFile("driving_app_js").
    root.addAnonymousImport("driving_app_js", .{
        .root_source_file = b.path("../games/driving/app.js"),
    });

    const exe = b.addExecutable(.{ .name = "zig-server", .root_module = root });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the zig server");
    run_step.dependOn(&run_cmd.step);
}
