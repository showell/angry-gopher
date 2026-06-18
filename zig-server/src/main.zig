const std = @import("std");
const markdown = @import("markdown.zig");

// gold.jsonl is the frozen real-corpus oracle (private, outside the repo).
// adversarial.jsonl is the hand-written hostile-corner fixture (in-repo,
// synthetic) — the corners the corpus never exercised. Both are checked.
const GOLD_PATH = "/home/steve/showell_repos/gopher-gold/gold.jsonl";
const ADVERSARIAL_PATH = "adversarial.jsonl";

const Case = struct {
    id: []const u8,
    md: []const u8,
    html: []const u8,
};

const Tally = struct { pass: usize = 0, fail: usize = 0 };

/// runFile verifies every case in a JSONL gold file, printing a greppable
/// FAILID per mismatch and full md/exp/got detail for the first `detail` of
/// them. The arena is reset per case — the per-message lifetime.
fn runFile(
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

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const gold = try runFile(io, alloc, &arena, GOLD_PATH, "corpus", 4);
    const adv = try runFile(io, alloc, &arena, ADVERSARIAL_PATH, "adversarial", 24);

    const pass = gold.pass + adv.pass;
    const total = pass + gold.fail + adv.fail;
    std.debug.print("==> {d}/{d} passing  ({d} failing)\n", .{ pass, total, gold.fail + adv.fail });
}
