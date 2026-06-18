const std = @import("std");
const markdown = @import("markdown.zig");

const GOLD_PATH = "/home/steve/showell_repos/gopher-gold/gold.jsonl";

const Case = struct {
    id: []const u8,
    md: []const u8,
    html: []const u8,
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const data = try std.Io.Dir.cwd().readFileAlloc(io, GOLD_PATH, alloc, .unlimited);
    defer alloc.free(data);

    // One arena reused across every case (reset, retain capacity) — the
    // per-message lifetime: render → compare → reset.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var shown: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const c = try std.json.parseFromSliceLeaky(Case, a, line, .{});

        const got = try markdown.render(a, c.md);
        if (std.mem.eql(u8, got, c.html)) {
            pass += 1;
        } else {
            fail += 1;
            shown += 1;
            // One greppable id per failure (for categorizing the remaining
            // tail), plus the full detail for the first few.
            std.debug.print("FAILID\t{s}\n", .{c.id});
            if (shown <= 4) {
                std.debug.print("  md:  {s}\n  exp: {s}\n  got: {s}\n", .{ c.md, c.html, got });
            }
        }
    }
    std.debug.print("==> {d}/{d} passing  ({d} failing)\n", .{ pass, pass + fail, fail });
}
