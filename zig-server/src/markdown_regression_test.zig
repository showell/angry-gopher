const std = @import("std");
const chat_codec = @import("chat_codec.zig");
const Io = @import("host_io").Io;
const markdown = @import("markdown.zig");
const chat_store = @import("chat_store.zig");

// The markdown DIALECT regression baseline. Our zig renderer (markdown.zig) IS
// the definition of lynrummy's markdown dialect; these frozen (id, md, html)
// corpora pin its output so an unintended change to the dialect can't slip in
// unnoticed. There is NO external oracle — `html` is whatever OUR renderer
// produces, frozen and human-reviewed. Re-baselining after an INTENTIONAL
// dialect change is an explicit act: run with --rebaseline, then eyeball the
// git diff of each corpus file before committing it.
//
//   gold.jsonl         the real corpus — every (id, md) captured from prod chat
//                      + docs (private, outside the repo: it embeds real user
//                      messages). The bulk of the coverage. Made from a
//                      backup's chat/ by `-- --capture CHAT_ROOT`.
//   adversarial.jsonl  hand-written hostile corners the real corpus never hit.
//   dialect.jsonl      the cases where our dialect deliberately departs from
//                      vanilla CommonMark: inline markup is PER-LINE, so `**`,
//                      backticks, and `[...]` never pair across a hard wrap.
//
// Verify:       cd zig-server && zig build markdown-regression   (ops/check_markdown)
// Re-baseline:  cd zig-server && zig build markdown-regression -- --rebaseline   (ops/regen_markdown_gold)
// Capture:      cd zig-server && zig build markdown-regression -- --capture CHAT_ROOT
//
// A corpus that cannot be read stops the run: a gate that skipped its bulk
// would pass having checked almost nothing.
const GOLD_PATH = "/home/steve/showell_repos/gopher-gold/gold.jsonl";
const ADVERSARIAL_PATH = "adversarial.jsonl";
const DIALECT_PATH = "dialect.jsonl";

const CORPORA = [_]struct { path: []const u8, label: []const u8, detail: usize }{
    .{ .path = GOLD_PATH, .label = "corpus", .detail = 4 },
    .{ .path = ADVERSARIAL_PATH, .label = "adversarial", .detail = 24 },
    .{ .path = DIALECT_PATH, .label = "dialect", .detail = 24 },
};

const Case = struct {
    id: []const u8,
    md: []const u8,
    html: []const u8,
};

const Tally = struct { pass: usize = 0, fail: usize = 0 };

/// verifyFile renders every case's `md` and asserts it equals the frozen `html`,
/// printing a greppable FAILID per mismatch and full md/exp/got detail for the
/// first `detail` of them. The arena is reset per case — the per-message lifetime.
fn verifyFile(
    io: Io,
    alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    label: []const u8,
    detail: usize,
) !Tally {
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
        std.debug.print("{s}: cannot read {s}: {s}\n", .{ label, path, @errorName(e) });
        return e;
    };
    defer alloc.free(data);

    var t = Tally{};
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const c = try std.json.parseFromSliceLeaky(Case, a, line, .{});
        const got = try markdown.render(a, c.md);
        if (std.mem.eql(u8, got, c.html)) {
            t.pass += 1;
        } else {
            t.fail += 1;
            shown += 1;
            std.debug.print("FAILID\t{s}\n", .{c.id});
            if (shown <= detail) {
                std.debug.print("  md:  {s}\n  exp: {s}\n  got: {s}\n", .{ c.md, c.html, got });
            }
        }
    }
    std.debug.print("== {s}: {d}/{d} passing  ({d} failing)\n", .{ label, t.pass, t.pass + t.fail, t.fail });
    return t;
}

/// rebaselineFile rewrites `path` in place: each (id, md) is kept, and `html` is
/// replaced with whatever OUR renderer now produces. This is how the zig renderer
/// owns the baseline — after an intentional dialect change, re-freeze, then read
/// the git diff to confirm only the intended cases moved.
fn rebaselineFile(
    io: Io,
    alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    label: []const u8,
) !void {
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
        std.debug.print("{s}: cannot read {s}: {s}\n", .{ label, path, @errorName(e) });
        return e;
    };
    defer alloc.free(data);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const c = try std.json.parseFromSliceLeaky(Case, a, line, .{});
        const html = try markdown.render(a, c.md);
        try out.print(alloc, "{{\"id\":{f},\"md\":{f},\"html\":{f}}}\n", .{
            std.json.fmt(c.id, .{}), std.json.fmt(c.md, .{}), std.json.fmt(html, .{}),
        });
        n += 1;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    std.debug.print("== {s}: re-baselined {d} cases -> {s}\n", .{ label, n, path });
}

/// A case to capture: its id and its markdown, owned by the capture's arena.
const Source = struct { id: []const u8, md: []const u8 };

fn byId(_: void, a: Source, b: Source) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

/// collectSources walks `dir_path` (`rel` its path under the chat root) for
/// what users wrote: every message of a transcript (a `.md` directly in a
/// `sessions/` folder, id `<rel>#<message id>`, since a session id repeats
/// across conversations) and every doc (`users/<uid>/docs/<slug>.md`, its
/// whole body, id `doc/<uid>/<slug>`). The users' feeds beside the docs
/// (`images.md`, `code.md`, `links.md`) are the server's, not theirs.
fn collectSources(io: Io, a: std.mem.Allocator, dir_path: []const u8, rel: []const u8, out: *std.ArrayList(Source)) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const here = std.fs.path.basename(rel);
    const parent = std.fs.path.dirname(rel) orelse "";
    const in_docs = std.mem.eql(u8, here, "docs") and std.mem.eql(u8, std.fs.path.dirname(parent) orelse "", "users");
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(a, &.{ dir_path, entry.name });
        const child_rel = if (rel.len == 0) try a.dupe(u8, entry.name) else try std.fs.path.join(a, &.{ rel, entry.name });
        if (entry.kind == .directory) {
            try collectSources(io, a, child, child_rel, out);
        } else if (std.mem.endsWith(u8, entry.name, ".md")) {
            if (std.mem.eql(u8, here, "sessions")) {
                const data = try Io.Dir.cwd().readFileAlloc(io, child, a, .unlimited);
                for (try chat_codec.decodeChatFile(a, data)) |m|
                    try out.append(a, .{ .id = try std.fmt.allocPrint(a, "{s}#{s}", .{ child_rel, m.id }), .md = m.markdown });
            } else if (in_docs) {
                const slug = entry.name[0 .. entry.name.len - 3];
                const uid = std.fs.path.basename(parent);
                try out.append(a, .{ .id = try std.fmt.allocPrint(a, "doc/{s}/{s}", .{ uid, slug }), .md = try Io.Dir.cwd().readFileAlloc(io, child, a, .unlimited) });
            }
        }
    }
}

/// **THE GOLD, CAPTURED** (`-- --capture CHAT_ROOT`): what users wrote under
/// CHAT_ROOT (a data_dir's `chat/`, from a backup), each case rendered by OUR
/// renderer now, sorted by id, written to GOLD_PATH. The corpus holds real
/// messages, so GOLD_PATH is outside every repository. A root with nothing in
/// it is refused: an empty gold would pass every run.
fn capture(io: Io, alloc: std.mem.Allocator, chat_root: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var sources: std.ArrayList(Source) = .empty;
    try collectSources(io, a, chat_root, "", &sources);
    if (sources.items.len == 0) {
        std.debug.print("capture: nothing written by a user under {s}\n", .{chat_root});
        return error.NothingToCapture;
    }
    std.mem.sort(Source, sources.items, {}, byId);
    var out: std.ArrayList(u8) = .empty;
    for (sources.items) |s| {
        try out.print(a, "{{\"id\":{f},\"md\":{f},\"html\":{f}}}\n", .{
            std.json.fmt(s.id, .{}), std.json.fmt(s.md, .{}), std.json.fmt(try markdown.render(a, s.md), .{}),
        });
    }
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(GOLD_PATH).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = GOLD_PATH, .data = out.items });
    std.debug.print("== captured {d} cases from {s} -> {s}\n", .{ sources.items.len, chat_root, GOLD_PATH });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.skip(); // exe name
    var rebaseline = false;
    var capture_root: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rebaseline")) {
            rebaseline = true;
        } else if (std.mem.eql(u8, arg, "--capture")) {
            capture_root = args.next() orelse {
                std.debug.print("--capture needs a chat root (a data_dir's chat/)\n", .{});
                std.process.exit(2);
            };
        } else {
            std.debug.print("unknown argument {s}: --rebaseline, or --capture CHAT_ROOT\n", .{arg});
            std.process.exit(2);
        }
    }
    if (capture_root) |root| return capture(io, alloc, root);

    if (rebaseline) {
        for (CORPORA) |c| try rebaselineFile(io, alloc, &arena, c.path, c.label);
        std.debug.print("\nRe-baselined. Review the git diff of each corpus before committing.\n", .{});
        return;
    }

    var pass: usize = 0;
    var fail: usize = 0;
    for (CORPORA) |c| {
        const t = try verifyFile(io, alloc, &arena, c.path, c.label, c.detail);
        pass += t.pass;
        fail += t.fail;
    }
    std.debug.print("==> {d}/{d} passing  ({d} failing)\n", .{ pass, pass + fail, fail });
    if (fail != 0) std.process.exit(1);
}
