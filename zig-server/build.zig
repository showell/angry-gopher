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
    // @embedFile("<name>"). All live outside this package dir, so they're wired
    // here rather than by a relative @embedFile path.
    const assets = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "driving_app_js", .path = "../games/driving/app.js" },
        .{ .name = "puzzle_js", .path = "../games/lynrummy/elm/puzzle.js" },
        // Full-game bundles (the /game surface): the compiled Elm client, the
        // esbuild-bundled TS engine, and the Elm↔engine glue shim.
        .{ .name = "game_elm_js", .path = "../games/lynrummy/elm/elm.js" },
        .{ .name = "game_engine_js", .path = "../games/lynrummy/elm/engine.js" },
        .{ .name = "game_engine_glue_js", .path = "../games/lynrummy/elm/engine_glue.js" },
        // The puzzle catalogs, easiest-first (1-line … 6-line). Concatenated at
        // runtime into the catalog shipped in the page flag (see puzzles.zig).
        .{ .name = "puzzle_cat_1", .path = "../games/lynrummy/conformance/curated_1line_puzzles.dsl" },
        .{ .name = "puzzle_cat_2", .path = "../games/lynrummy/conformance/curated_2line_puzzles.dsl" },
        .{ .name = "puzzle_cat_3", .path = "../games/lynrummy/conformance/curated_3line_puzzles.dsl" },
        .{ .name = "puzzle_cat_4", .path = "../games/lynrummy/conformance/curated_4line_puzzles.dsl" },
        .{ .name = "puzzle_cat_5", .path = "../games/lynrummy/conformance/curated_5line_puzzles.dsl" },
        .{ .name = "puzzle_cat_6", .path = "../games/lynrummy/conformance/curated_6line_puzzles.dsl" },
    };
    for (assets) |a| {
        root.addAnonymousImport(a.name, .{ .root_source_file = b.path(a.path) });
    }

    const exe = b.addExecutable(.{ .name = "zig-server", .root_module = root });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the zig server");
    run_step.dependOn(&run_cmd.step);
}
