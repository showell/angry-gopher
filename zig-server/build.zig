const std = @import("std");

// build.zig is the one place where front-end assets that live ELSEWHERE in the
// repo get baked into the binary. @embedFile alone can't reach outside the
// package dir, so each external asset is wired in here as a named import and
// pulled in with @embedFile("<name>").
//
//   zig build run     -> build + run the server (serves /driving on :9001)
//   zig build         -> just build (binary in zig-build/)
//
// The embedded front-end build outputs must exist first (ops/build_safari_wasm,
// ops/build_elm, ops/build_delivery from the repo root); see the asset list below.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    // **THE `webbox` LIBRARY** (zig-webbox, a web server in a box), what
    // this application is built on: no file here imports a file of it by
    // path. Three modules: `webbox`, portable, which everything imports;
    // `webbox_linux`, the Linux host, which only a Linux `main` imports; and
    // `host_io`, the one file that names the host (std's here; the
    // unikernel's build hands the same sources the machine's).
    const webbox_dep = b.dependency("webbox", .{ .target = target, .optimize = optimize });
    const host_io = webbox_dep.module("host_io");
    const webbox = webbox_dep.module("webbox");
    const webbox_linux = webbox_dep.module("webbox_linux");
    root.addImport("host_io", host_io);
    root.addImport("webbox", webbox);
    root.addImport("webbox_linux", webbox_linux);
    // **SHALE** (the `shale` checkout), its scripts on the site's own data:
    // `shale`, portable, built on the same `webbox` and `host_io`.
    const shale_dep = b.dependency("shale", .{ .target = target, .optimize = optimize });
    const shale = shale_dep.module("shale");
    root.addImport("shale", shale);

    // Bake the deploy's git short-hash into the binary so /version (and thus the
    // watchdog) reports exactly which commit is serving. ops/deploy passes
    // -Dcommit=$(git rev-parse --short HEAD); local/dev builds fall back to "dev".
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "commit", b.option([]const u8, "commit", "git short hash baked into /version") orelse "dev");
    // fake_leak: when true, /driving deliberately leaks a few bytes per hit so the
    // stress harness's leak detector can be validated against a known leak. Default
    // OFF and compile-time gated — there is NO runtime knob, so prod can't be made
    // to leak. Flipped on only by ops/stress_selftest.
    build_opts.addOption(bool, "fake_leak", b.option(bool, "fake_leak", "deliberately leak in /driving to validate the stress harness (never prod)") orelse false);
    root.addImport("build_options", build_opts.createModule());

    // Embedded front-end assets (the embed.go analog). Referenced in code as
    // @embedFile("<name>"). All live outside this package dir, so they're wired
    // here rather than by a relative @embedFile path.
    //
    // **A GENERATED ONE NAMES WHAT BUILDS IT** (`.built_by`, metal-vmm QUEUE
    // 157(d)): ops/check_zig reads this list, and refuses with that guidance
    // when one is missing, and when a file here that git does not track names
    // nothing. It kept a list of its own, which had lost delivery/app.js.
    // The table is zig-server/assets.zon, which every build of this
    // application reads (zig-metal-unikernel's too).
    const served: struct {
        embedded: []const struct { name: []const u8, path: []const u8, built_by: []const u8 = "" },
        site: []const []const u8,
    } = @import("assets.zon");
    const assets = served.embedded;
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

    // The leak stress harness (`zig build stress`): a separate executable that
    // hammers endpoints over HTTP and watches /debug/mem. Standalone — no embedded
    // assets — it only needs std (http.Client). Wrapped by ops/stress.
    const stress_mod = b.createModule(.{
        .root_source_file = b.path("src/stress.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_mod.addImport("host_io", host_io);
    const stress_exe = b.addExecutable(.{ .name = "stress", .root_module = stress_mod });
    // Build (don't run) the harness to zig-out/bin/stress. The ops scripts run the
    // binary directly so they own the exit-code semantics — a `zig build run` step
    // treats the harness's "leak found" exit 1 as a build failure, which is exactly
    // backwards for ops/stress_selftest (where finding the planted leak is success).
    const stress_step = b.step("stress", "Build the leak stress harness (zig-out/bin/stress)");
    stress_step.dependOn(&b.addInstallArtifact(stress_exe, .{}).step);

    // `zig build hash-password`: a password on stdin, its bcrypt hash out, as
    // the server stores it. For resetting a lost admin password
    // (ops/reset_admin_password; zig-metal-unikernel's droplet/chat.py).
    const hash_mod = b.createModule(.{
        .root_source_file = b.path("src/hash_password.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_mod.addImport("webbox", webbox);
    hash_mod.addImport("host_io", host_io);
    const hash_exe = b.addExecutable(.{ .name = "hash-password", .root_module = hash_mod });
    b.step("hash-password", "Build zig-out/bin/hash-password").dependOn(&b.addInstallArtifact(hash_exe, .{}).step);

    // **THE TOOLS RUN BY HAND**: measuring sticks and probes, not gates. Each
    // reaches the library, so each is built here, where the `webbox` module
    // is, and run by name: `zig build search-bench`, and so on.
    const Tool = struct { step: []const u8, path: []const u8, optimize: std.builtin.OptimizeMode, help: []const u8 };
    for ([_]Tool{
        .{ .step = "search-bench", .path = "src/search_bench.zig", .optimize = .ReleaseFast, .help = "Measure what search's index costs to build (src/search_bench.zig)" },
        .{ .step = "markdown-bench", .path = "src/markdown_bench.zig", .optimize = optimize, .help = "Render a corpus and report the slowest messages (src/markdown_bench.zig)" },
        .{ .step = "markdown-probe", .path = "src/markdown_hostile_probe.zig", .optimize = optimize, .help = "Check the renderer stays linear on hostile shapes (src/markdown_hostile_probe.zig)" },
        .{ .step = "markdown-regression", .path = "src/markdown_regression_test.zig", .optimize = optimize, .help = "Render the corpora and compare with the gold (ops/check_markdown; -- --rebaseline rewrites it)" },
    }) |tool| {
        const tool_mod = b.createModule(.{ .root_source_file = b.path(tool.path), .target = target, .optimize = tool.optimize });
        tool_mod.addImport("webbox", webbox);
        tool_mod.addImport("host_io", host_io);
        const tool_exe = b.addExecutable(.{ .name = tool.step, .root_module = tool_mod });
        const tool_run = b.addRunArtifact(tool_exe);
        if (b.args) |args| tool_run.addArgs(args);
        b.step(tool.step, tool.help).dependOn(&tool_run.step);
    }

    // Unit tests (`zig build test`). Each listed module is a test root; a file's
    // `test {}` blocks run when a root reaches it by imports Zig analyzes (an
    // import nothing uses is never analyzed, so its tests do not run), and
    // tools/test_roots.shale checks every file holding tests is reached.
    // Pure-logic modules tested in isolation, so no embedded assets are needed.
    // router.zig's tests call the REAL route table, so they reach handlers that
    // @embedFile assets and read build_options. Its test module therefore needs
    // the same wiring `root` got above — a plain module (the loop below) would
    // fail to compile on the first @embedFile.
    const router_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/router.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    // The request-edge harness reads every number parse in the source, the
    // libraries' too: where zig-webbox's and Shale's sources are.
    const router_opts = b.addOptions();
    router_opts.addOption([]const u8, "commit", "dev");
    router_opts.addOption(bool, "fake_leak", false);
    router_opts.addOption([]const u8, "webbox_src", webbox_dep.builder.pathFromRoot("src"));
    router_opts.addOption([]const u8, "shale_src", shale_dep.builder.pathFromRoot("src"));
    router_tests.root_module.addImport("build_options", router_opts.createModule());
    // roots.zig's test reads what the library's store.setBases assigns.
    const webbox_store_source = webbox_dep.path("src/store.zig");
    router_tests.root_module.addAnonymousImport("webbox_store_source", .{ .root_source_file = webbox_store_source });
    router_tests.root_module.addImport("webbox", webbox);
    router_tests.root_module.addImport("shale", shale);
    router_tests.root_module.addImport("host_io", host_io);
    for (assets) |a| {
        router_tests.root_module.addAnonymousImport(a.name, .{ .root_source_file = b.path(a.path) });
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(router_tests).step);
    for ([_][]const u8{ "src/auth.zig", "src/users.zig", "src/users_session.zig", "src/login.zig", "src/names.zig", "src/player.zig", "src/admin_ui.zig", "src/roots.zig", "src/markdown_fence.zig", "src/recent_feed.zig", "src/code_store.zig", "src/chat_upload.zig", "src/markdown.zig", "src/markdown_media.zig", "src/chat_sse.zig", "src/docs_store.zig", "src/reading_list.zig", "src/chat_store.zig", "src/chat_codec.zig", "src/chat_fanout.zig", "src/chat_count.zig", "src/chat_paths.zig", "src/reactions.zig", "src/stress.zig", "src/admin_backup.zig", "src/ustar.zig", "src/storage.zig", "src/uid_cookie.zig", "src/game_limits.zig", "src/admin_secret.zig", "src/login_throttle.zig", "src/chat_retire.zig", "src/admin_retire.zig", "src/search_tokens.zig", "src/search_index.zig", "src/chat_search.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        // A file of the application reaches the library as its modules.
        unit.root_module.addImport("webbox", webbox);
        unit.root_module.addImport("webbox_linux", webbox_linux);
        unit.root_module.addImport("shale", shale);
        unit.root_module.addImport("host_io", host_io);
        unit.root_module.addAnonymousImport("webbox_store_source", .{ .root_source_file = webbox_store_source });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
