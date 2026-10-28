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
    // **CODEX CHAT** (the `cobble-webbox` checkout), served under
    // /codex-chat: `codex_chat`, portable, on the same `webbox` and `host_io`.
    const cobble = b.dependency("cobble_webbox", .{ .target = target, .optimize = optimize });
    const codex_chat = cobble.module("codex_chat");
    root.addImport("codex_chat", codex_chat);
    // /uo: `uo_town`, Damian's UO town (TownWatch), the same way.
    const uo_town = cobble.module("uo_town");
    root.addImport("uo_town", uo_town);
    // /roc-chat: `roc_chat`, the Roc chat (roc-webbox, docs/ROC-CHAT.md
    // T1), its Roc built for this target. So every build needs the Roc
    // roc-webbox pins: `roc` on the PATH, or -Droc=<path>.
    const roc_webbox = b.dependency("roc_webbox", .{ .target = target, .optimize = optimize, .roc = b.option([]const u8, "roc", "the Roc compiler (default: `roc` on the PATH); the version roc-webbox's roc-version pins") orelse "roc" });
    const roc_chat = roc_webbox.module("roc_chat");
    root.addImport("roc_chat", roc_chat);

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
    run_cmd.addPassthruArgs();

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
        .{ .step = "search-bench", .path = "src/search_bench.zig", .optimize = .fast, .help = "Measure what search's index costs to build (src/search_bench.zig)" },
        .{ .step = "markdown-bench", .path = "src/markdown_bench.zig", .optimize = optimize, .help = "Render a corpus and report the slowest messages (src/markdown_bench.zig)" },
        .{ .step = "markdown-probe", .path = "src/markdown_hostile_probe.zig", .optimize = optimize, .help = "Check the renderer stays linear on hostile shapes (src/markdown_hostile_probe.zig)" },
        .{ .step = "markdown-regression", .path = "src/markdown_regression_test.zig", .optimize = optimize, .help = "Render the corpora and compare with the gold (ops/check_markdown; -- --rebaseline rewrites it)" },
    }) |tool| {
        const tool_mod = b.createModule(.{ .root_source_file = b.path(tool.path), .target = target, .optimize = tool.optimize });
        tool_mod.addImport("webbox", webbox);
        tool_mod.addImport("host_io", host_io);
        const tool_exe = b.addExecutable(.{ .name = tool.step, .root_module = tool_mod });
        const tool_run = b.addRunArtifact(tool_exe);
        tool_run.addPassthruArgs();
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
    // libraries' too: where this app's, zig-webbox's and Shale's sources are
    // (absolute: a test runs in whatever folder `zig build` was run from).
    const router_opts = b.addOptions();
    router_opts.addOption([]const u8, "commit", "dev");
    router_opts.addOption(bool, "fake_leak", false);
    router_opts.addOption([]const u8, "app_src", pathFromRoot(b, "src"));
    router_opts.addOption([]const u8, "webbox_src", pathFromRoot(webbox_dep.builder, "src"));
    router_opts.addOption([]const u8, "shale_src", pathFromRoot(shale_dep.builder, "src"));
    router_tests.root_module.addImport("build_options", router_opts.createModule());
    // roots.zig's test reads what the library's store.setBases assigns.
    const webbox_store_source = webbox_dep.path("src/store.zig");
    router_tests.root_module.addAnonymousImport("webbox_store_source", .{ .root_source_file = webbox_store_source });
    router_tests.root_module.addImport("webbox", webbox);
    router_tests.root_module.addImport("shale", shale);
    router_tests.root_module.addImport("codex_chat", codex_chat);
    router_tests.root_module.addImport("uo_town", uo_town);
    router_tests.root_module.addImport("roc_chat", roc_chat);
    router_tests.root_module.addImport("host_io", host_io);
    for (assets) |a| {
        router_tests.root_module.addAnonymousImport(a.name, .{ .root_source_file = b.path(a.path) });
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(router_tests).step);

    // **THE ROC CHAT'S PURE MODULES AGAINST THEIR ZIG TWINS** (roc-webbox
    // docs/ROC-CHAT.md C1): a binary of its own, since it links the twin
    // archive (chat/twin.roc), not the router's.
    const twin_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/chat_twin_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    twin_tests.root_module.addImport("roc_chat_twin", roc_webbox.module("roc_chat_twin"));
    twin_tests.root_module.addImport("webbox", webbox);
    twin_tests.root_module.addImport("webbox_linux", webbox_linux);
    twin_tests.root_module.addImport("shale", shale);
    twin_tests.root_module.addImport("host_io", host_io);
    twin_tests.root_module.addAnonymousImport("webbox_store_source", .{ .root_source_file = webbox_store_source });
    // The pages' twins build the chrome, which names the bundles by their bytes.
    for (assets) |a| twin_tests.root_module.addAnonymousImport(a.name, .{ .root_source_file = b.path(a.path) });
    test_step.dependOn(&b.addRunArtifact(twin_tests).step);

    // What decoding a transcript costs, Zig and its Roc twin side by side
    // (src/chat_codec_bench.zig): `zig build codec-bench [-- <transcript>]`.
    const codec_bench_mod = b.createModule(.{ .root_source_file = b.path("src/chat_codec_bench.zig"), .target = target, .optimize = .ReleaseFast });
    codec_bench_mod.addImport("roc_chat_twin", roc_webbox.module("roc_chat_twin"));
    codec_bench_mod.addImport("webbox", webbox);
    codec_bench_mod.addImport("webbox_linux", webbox_linux);
    codec_bench_mod.addImport("shale", shale);
    codec_bench_mod.addImport("host_io", host_io);
    codec_bench_mod.addAnonymousImport("webbox_store_source", .{ .root_source_file = webbox_store_source });
    const codec_bench_run = b.addRunArtifact(b.addExecutable(.{ .name = "codec-bench", .root_module = codec_bench_mod }));
    codec_bench_run.addPassthruArgs();
    b.step("codec-bench", "Decode a transcript in Zig and in Roc, time and peak memory (src/chat_codec_bench.zig)").dependOn(&codec_bench_run.step);
    for ([_][]const u8{ "src/auth.zig", "src/users.zig", "src/users_session.zig", "src/login.zig", "src/names.zig", "src/player.zig", "src/admin_ui.zig", "src/roots.zig", "src/markdown_fence.zig", "src/recent_feed.zig", "src/chat_upload.zig", "src/markdown.zig", "src/markdown_media.zig", "src/chat_sse.zig", "src/docs_store.zig", "src/reading_list.zig", "src/chat_store.zig", "src/chat_codec.zig", "src/chat_fanout.zig", "src/chat_count.zig", "src/chat_paths.zig", "src/stress.zig", "src/admin_backup.zig", "src/ustar.zig", "src/storage.zig", "src/uid_cookie.zig", "src/game_limits.zig", "src/admin_secret.zig", "src/login_throttle.zig", "src/search_tokens.zig", "src/search_index.zig", "src/chat_search.zig", "src/decimal.zig", "src/request_time.zig" }) |path| {
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

/// `builder`'s build root as an absolute path: 0.17's `b.root` may hold a
/// relative one, and these paths are handed to other processes and builds.
fn rootOf(builder: *std.Build) []const u8 {
    return builder.root.root_dir.handle.realPathFileAlloc(builder.graph.io, builder.root.subPathOrDot(), builder.allocator) catch |e|
        std.debug.panic("the build root {f}: {t}", .{ builder.root, e });
}

/// `sub` under this build's root, absolute (0.17 removed `b.pathFromRoot`).
fn pathFromRoot(b: *std.Build, sub: []const u8) []const u8 {
    return b.pathJoin(&.{ rootOf(b), sub });
}
