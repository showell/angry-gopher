//! **THE ROC ROUTER, PINNED** (roc-webbox docs/ROC-CHAT.md A3; metal-vmm
//! QUEUE 263b): the router's decisions over a corpus of paths, frozen as
//! goldens from the Roc itself, through the real ABI, on the day they
//! agreed with chat.zig's old dispatch (the twin that held them, retired):
//! `chat_route_golden.txt`, one line a decision, for a member, in both
//! areas. What a rule says better than a golden is a rule, over the whole
//! corpus: a path that is not UTF-8 is the door's 400, nothing asked; one
//! who is no member is sent to sign in and back to the request's own path,
//! but for a script. Test-only. The corpus (chat_route_paths_test.zig) also
//! feeds chat_twin_test.zig's check of the pre-turn hooks.
//!
//! A golden that differs writes what the Roc gave to
//! `.zig-cache/chat_route_golden.got.txt`, and fails. After a deliberate
//! change to the router, read its diff against the golden, then copy it over.

const std = @import("std");
const roc_chat = @import("roc_chat");
const Decision = roc_chat.Decision;

// ── the agreement (A3): the Roc router decides as this did ─────────────────

const testing = std.testing;

const paths = @import("chat_route_paths_test.zig");
const corpus = paths.corpus;

/// A decision as the golden says it: a page's status and type, never its
/// bytes (the router's work is where a request goes, not what a page
/// holds), and a route without its empty fields.
fn said(alloc: std.mem.Allocator, d: Decision) ![]const u8 {
    return switch (d) {
        .respond => |r| std.fmt.allocPrint(
            alloc,
            "{d} {s}",
            .{ r.status, r.content_type },
        ),
        .held => |h| std.fmt.allocPrint(
            alloc,
            "held {d} {s}",
            .{ h.status, h.content_type },
        ),
        else => blk: {
            var s = try std.fmt.allocPrint(
                alloc,
                "{f}",
                .{d},
            );
            for ([_][]const u8{
                " key=\"\"",
                " rest=\"\"",
                " topic=\"\"",
            }) |empty| s = try std.mem.replaceOwned(
                u8,
                alloc,
                s,
                empty,
                "",
            );
            break :blk s;
        },
    };
}

test "the Roc router decides every golden path as it was frozen: the decision, and whether it asked who was asking and counted presence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var subs: std.ArrayList([]const u8) = .empty;
    try paths.reduced(a, &subs);
    var got: std.ArrayList(u8) = .empty;
    for (subs.items) |sub| for ([_]bool{ false, true }) |channel| {
        var call = std.heap.ArenaAllocator.init(testing.allocator);
        defer call.deinit();
        roc_chat.use(call.allocator());
        var ask: roc_chat.Routing = .{ .member = true };
        const d = try roc_chat.decide(
            call.allocator(),
            sub,
            channel,
            .GET,
            ask.host(),
        );
        try got.print(
            a,
            "{s}\t\"{f}\"\t{s}\t{s}{s}\n",
            .{
                if (channel) "/channel" else "/chat",
                std.zig.fmtString(sub),
                try said(a, d),
                if (ask.asked) "a" else "-",
                if (ask.marked) "m" else "-",
            },
        );
    };
    const want = @embedFile("chat_route_golden.txt");
    if (std.mem.eql(
        u8,
        got.items,
        want,
    )) return;
    std.Io.Dir.cwd().writeFile(
        std.testing.io,
        .{ .sub_path = ".zig-cache/chat_route_golden.got.txt", .data = got.items },
    ) catch {};
    std.debug.print(
        "the Roc's decisions differ from chat_route_golden.txt: .zig-cache/chat_route_golden.got.txt has them\n",
        .{},
    );
    var g = std.mem.splitScalar(
        u8,
        got.items,
        '\n',
    );
    var w = std.mem.splitScalar(
        u8,
        want,
        '\n',
    );
    var shown: usize = 0;
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = g.next();
        const y = w.next();
        if (x == null and y == null) break;
        if (x != null and y != null and std.mem.eql(
            u8,
            x.?,
            y.?,
        )) continue;
        shown += 1;
        if (shown <= 10) std.debug.print("line {d}:\n  roc  {s}\n  want {s}\n", .{
            line,
            x orelse "(none)",
            y orelse "(none)",
        });
    }
    return error.TestUnexpectedResult;
}

test "the router's rules over the whole corpus: a path that is not UTF-8 is the door's 400 with nothing asked; one who is no member signs in and comes back to the path, but for a script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subs = try corpus(a);
    try testing.expect(subs.len * 4 > 5000); // decisions: each path in both areas, member or not
    var differ: usize = 0;
    for (subs) |sub| for ([_]bool{ false, true }) |channel| for ([_]bool{ false, true }) |member| {
        var call = std.heap.ArenaAllocator.init(testing.allocator);
        defer call.deinit();
        roc_chat.use(call.allocator());
        var ask: roc_chat.Routing = .{ .member = member };
        const d = try roc_chat.decide(
            call.allocator(),
            sub,
            channel,
            .GET,
            ask.host(),
        );
        const area = if (channel) "/channel" else "/chat";
        const script = !channel and sub.len > 1 and std.mem.endsWith(
            u8,
            sub,
            ".js",
        );
        const ok = if (!std.unicode.utf8ValidateSlice(sub))
            d == .malformed_form and !ask.asked and !ask.marked
        else if (script)
            d == .serve and d.serve.route.family == .asset and !ask.asked
        else if (!member)
            d == .to_login and std.mem.eql(
                u8,
                d.to_login,
                try std.mem.concat(
                    call.allocator(),
                    u8,
                    &.{ area, sub },
                ),
            ) and ask.asked
        else
            true;
        if (!ok) {
            differ += 1;
            if (differ <= 10) std.debug.print("{s} \"{f}\" member={}: {f} (asked {})\n", .{
                area,
                std.zig.fmtString(sub),
                member,
                d,
                ask.asked,
            });
        }
    };
    try testing.expectEqual(@as(usize, 0), differ);
}
