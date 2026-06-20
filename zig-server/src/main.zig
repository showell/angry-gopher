const std = @import("std");
const markdown = @import("markdown.zig");

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
//                      messages). The bulk of the coverage.
//   adversarial.jsonl  hand-written hostile corners the real corpus never hit.
//   dialect.jsonl      the cases where our dialect deliberately departs from
//                      vanilla CommonMark: inline markup is PER-LINE, so `**`,
//                      backticks, and `[...]` never pair across a hard wrap.
//
// Verify:       cd zig-server && zig run src/main.zig
// Re-baseline:  cd zig-server && zig run src/main.zig -- --rebaseline
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
    io: std.Io,
    alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    label: []const u8,
    detail: usize,
) !Tally {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
        std.debug.print("({s}: cannot read {s}: {s})\n", .{ label, path, @errorName(e) });
        return .{};
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
    io: std.Io,
    alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    label: []const u8,
) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
        std.debug.print("({s}: cannot read {s}: {s})\n", .{ label, path, @errorName(e) });
        return;
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    std.debug.print("== {s}: re-baselined {d} cases -> {s}\n", .{ label, n, path });
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
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rebaseline")) rebaseline = true;
    }

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
