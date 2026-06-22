const std = @import("std");

// build.zig is the one place where front-end assets that live ELSEWHERE in the
// repo get baked into the binary. @embedFile alone can't reach outside the
// package dir, so each external asset is wired in here as a named import and
// pulled in with @embedFile("<name>").
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

    // Bake the deploy's git short-hash into the binary so /version (and thus the
    // watchdog) reports exactly which commit is serving. ops/deploy passes
    // -Dcommit=$(git rev-parse --short HEAD); local/dev builds fall back to "dev".
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "commit", b.option([]const u8, "commit", "git short hash baked into /version") orelse "dev");
    root.addImport("build_options", build_opts.createModule());

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
        // The chat conversation page's client bundles (chat/*.js) — served
        // byte-for-byte so the real prod client boots on the zig chat page.
        .{ .name = "chat_js_colors", .path = "../chat/colors.js" },
        .{ .name = "chat_js_viewport", .path = "../chat/viewport.js" },
        .{ .name = "chat_js_theme", .path = "../chat/chat_theme.js" },
        .{ .name = "chat_js_chrome_drawer", .path = "../chat/chrome_drawer.js" },
        .{ .name = "chat_js_image_popup", .path = "../chat/chat_image_popup.js" },
        .{ .name = "chat_js_code_popup", .path = "../chat/chat_code_popup.js" },
        .{ .name = "chat_js_time_popup", .path = "../chat/chat_time_popup.js" },
        .{ .name = "chat_js_message", .path = "../chat/message.js" },
        .{ .name = "chat_js_message_view", .path = "../chat/message_view.js" },
        .{ .name = "chat_js_nav_stack", .path = "../chat/nav_stack.js" },
        .{ .name = "chat_js_middle_pane", .path = "../chat/middle_pane.js" },
        .{ .name = "chat_js_search", .path = "../chat/chat_search.js" },
        .{ .name = "chat_js_drag_to_pin", .path = "../chat/chat_drag_to_pin.js" },
        .{ .name = "chat_js_add_topic", .path = "../chat/chat_add_topic.js" },
        .{ .name = "chat_js_first_topic", .path = "../chat/chat_first_topic.js" },
        .{ .name = "chat_js_left_sidebar", .path = "../chat/chat_left_sidebar.js" },
        .{ .name = "chat_js_right_sidebar", .path = "../chat/chat_right_sidebar.js" },
        .{ .name = "chat_js_compose", .path = "../chat/chat_compose.js" },
        .{ .name = "chat_js_help", .path = "../chat/chat_help.js" },
        .{ .name = "chat_js_responsive", .path = "../chat/chat_responsive.js" },
        .{ .name = "chat_js_chat", .path = "../chat/chat.js" },
        .{ .name = "chat_js_notify", .path = "../chat/notify.js" },
        .{ .name = "chat_js_docs", .path = "../chat/docs.js" },
        .{ .name = "chat_js_recent", .path = "../chat/recent.js" },
        .{ .name = "chat_js_styles", .path = "../chat/styles.js" },
        .{ .name = "chat_js_images", .path = "../chat/images.js" },
        .{ .name = "chat_js_code", .path = "../chat/code.js" },
        // The /learn tutorial's own bundles (the page also reuses many chat/*.js
        // modules above, both to run its demos and to reveal as spoiler source).
        .{ .name = "learn_js", .path = "../learn/learn.js" },
        .{ .name = "learn_callback_log_js", .path = "../learn/callback_log.js" },
        .{ .name = "learn_fake_host_js", .path = "../learn/fake_host.js" },
        // Shared brand/avatar assets served from /images/<file> (brand.zig). The
        // cat professor is the /learn page's mascot.
        .{ .name = "image_cat_professor", .path = "../images/cat_professor.webp" },
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

    // Unit tests (`zig build test`). Each listed module is a test root; a module
    // must be in this list for its `test {}` blocks to actually run under the
    // gate (imports alone don't enroll a file's tests). Pure-logic modules tested
    // in isolation, so no embedded assets are needed.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/auth.zig", "src/users.zig", "src/markdown_fence.zig", "src/recent_feed.zig", "src/code_store.zig", "src/chat_upload.zig", "src/markdown.zig", "src/markdown_media.zig", "src/bus.zig", "src/chat_sse.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
