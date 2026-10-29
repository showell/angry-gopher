//! **THE ROC'S MARKDOWN, HELD TO THE ZIG'S** (metal-vmm QUEUE 305): every
//! case of every corpus is rendered by chat-markdown's Zig and by the Roc
//! port (roc-webbox chat/Md*.roc, through chat/twin.roc's function 82), and
//! the two must agree on all five answers: `render`'s html, `workUnits`'
//! number, `hostileReason`'s reason, `renderTrusted`'s html and
//! `renderTrustedReflow`'s html. The work units are what the Zig's budget
//! caps, so equal numbers make the Roc's hostility verdict the Zig's.
//!
//! **IT PRINTS ONLY COUNTS AND FAILING CASE IDS, NEVER A CASE'S TEXT**: the
//! box runs it over the private gold corpus (real messages, which never
//! leave the box), so nothing a message holds reaches its output. A failing
//! case is named by its id and the answers that differ.
//!
//!   cd zig-server && zig build markdown-twin
//!       the corpora markdown_twin/corpora.txt lists, and the hostile shapes
//!       generated here; each corpus held to its line in
//!       markdown_twin/ratchet.txt, a pass count that may only rise.
//!   ... -- --also PATH        one more corpus (the box's gold), not ratcheted
//!   ... -- --raise            the ratchet rewritten to today's counts, when
//!                             none fell
//!   ... -- --fuzz N --seed S  N random messages from the dialect's tokens:
//!                             a hunt, never a gate; each difference is
//!                             appended to markdown_twin/fuzz_found.jsonl, a
//!                             corpus, to commit
//!   ... -- --time             each corpus's render time, Zig and Roc
//!
//! A corpus is jsonl, one `{"id", "md"}` a line (other fields, such as the
//! regression gold's `html`, are ignored). A corpus that cannot be read
//! stops the run: a judge that skipped its bulk would pass having checked
//! almost nothing.

const std = @import("std");
/// The host's I/O, by its one name (std's here): no file of the app names std's itself.
const Io = @import("host_io").Io;
const markdown = @import("chat_markdown");
const twin = @import("roc_chat_twin");

/// chat/twin.roc's number for the markdown's five answers.
const markdown_answers: u8 = 82;

const corpora_list = "markdown_twin/corpora.txt";
const ratchet_path = "markdown_twin/ratchet.txt";
const fuzz_found_path = "markdown_twin/fuzz_found.jsonl";

/// The five answers, in twin.roc's order.
const Part = enum { render, work_units, hostile_reason, trusted, trusted_reflow };
const part_count = std.enums.values(Part).len;

const Case = struct { id: []const u8, md: []const u8 };

/// A case's verdict: the parts that differ, or a Roc that crashed or gave
/// the wrong number of answers.
const Verdict = union(enum) {
    same,
    differ: [part_count]bool,
    roc_crashed,
    roc_answered: usize,
};

/// The Zig's five answers for `md`, in `a`.
fn zigAnswers(a: std.mem.Allocator, md: []const u8) ![part_count][]const u8 {
    return .{
        try markdown.render(a, md),
        try std.fmt.allocPrint(a, "{d}", .{try markdown.workUnits(a, md)}),
        (try markdown.hostileReason(a, md)) orelse "",
        try markdown.renderTrusted(a, md),
        try markdown.renderTrustedReflow(a, md),
    };
}

fn judge(a: std.mem.Allocator, md: []const u8) !Verdict {
    const zig = try zigAnswers(a, md);
    const roc = twin.call(a, markdown_answers, &.{md}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .roc_crashed,
    };
    if (roc.len != part_count) return .{ .roc_answered = roc.len };
    var differ: [part_count]bool = @splat(false);
    var any = false;
    for (zig, roc, 0..) |z, r, k| {
        differ[k] = !std.mem.eql(u8, z, r);
        any = any or differ[k];
    }
    return if (any) .{ .differ = differ } else .same;
}

/// `FAILID`, the corpus, the id and what differed: never the text.
fn printFailure(label: []const u8, id: []const u8, v: Verdict) void {
    std.debug.print("FAILID\t{s}\t{s}\t", .{ label, id });
    switch (v) {
        .same => unreachable,
        .roc_crashed => std.debug.print("roc crashed", .{}),
        .roc_answered => |n| std.debug.print("roc gave {d} answers", .{n}),
        .differ => |d| {
            var first = true;
            for (d, 0..) |bad, k| {
                if (!bad) continue;
                if (!first) std.debug.print(",", .{});
                std.debug.print("{s}", .{@tagName(@as(Part, @fromBackingInt(@intCast(k))))});
                first = false;
            }
        },
    }
    std.debug.print("\n", .{});
}

/// A corpus's count: cases agreeing, differing, and the Zig's hostile
/// ones among all (so a run says how much of the refusal path it reached).
const Tally = struct { pass: usize = 0, fail: usize = 0, hostile: usize = 0 };

fn judgeCases(arena: *std.heap.ArenaAllocator, label: []const u8, cases: []const Case) !Tally {
    var t: Tally = .{};
    for (cases) |c| {
        _ = arena.reset(.retain_capacity);
        const v = try judge(arena.allocator(), c.md);
        if ((try markdown.hostileReason(arena.allocator(), c.md)) != null) t.hostile += 1;
        if (v == .same) {
            t.pass += 1;
        } else {
            t.fail += 1;
            printFailure(label, c.id, v);
        }
    }
    return t;
}

/// The cases of a jsonl corpus, in `a`.
fn readCorpus(io: Io, a: std.mem.Allocator, path: []const u8) ![]Case {
    const data = Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| {
        std.debug.print("cannot read the corpus {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    var cases: std.ArrayList(Case) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        if (line.len == 0) continue;
        const c = std.json.parseFromSliceLeaky(Case, a, line, .{ .ignore_unknown_fields = true }) catch |e| {
            std.debug.print("{s}:{d}: not a case: {s}\n", .{ path, n, @errorName(e) });
            return e;
        };
        try cases.append(a, c);
    }
    return cases.items;
}

/// A corpus's label: its file's name without `.jsonl`.
fn labelOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - 6] else base;
}

// ── the hostile shapes ──────────────────────────────────────────────────────

/// A shape a unit repeated: `head`, `unit` n times, `tail`. The documented
/// adversarial shapes (markdown_hostile_probe.zig's), cmark's pathological
/// tests (test/pathological_tests.py), and the dialect's own corners: the
/// fence cap, the nesting cap, the email floor.
const Shape = struct { name: []const u8, head: []const u8 = "", unit: []const u8, tail: []const u8 = "" };

const shapes = [_]Shape{
    // markdown_hostile_probe.zig's.
    .{ .name = "open-brackets", .unit = "[" },
    .{ .name = "link-bait", .unit = "[](" },
    .{ .name = "emph-underscore", .unit = "a_b_" },
    .{ .name = "emph-star", .unit = "*" },
    .{ .name = "backticks", .unit = "`" },
    .{ .name = "angle-brackets", .unit = "<" },
    .{ .name = "nested-quote", .unit = "> " },
    .{ .name = "msg-ref-bait", .unit = "MSG_a_1 " },
    .{ .name = "dense-legit", .unit = "**x** " },
    // cmark's pathological tests.
    .{ .name = "nested-strong-emph", .unit = "*a **a ", .tail = "b" },
    .{ .name = "nested-strong-emph-close", .head = "b", .unit = " a** a*" },
    .{ .name = "emph-closers-no-openers", .unit = "a_ " },
    .{ .name = "emph-openers-no-closers", .unit = "_a " },
    .{ .name = "link-closers-no-openers", .unit = "a]" },
    .{ .name = "link-openers-no-closers", .unit = "[a" },
    .{ .name = "mismatched-openers-closers", .unit = "*a_ " },
    .{ .name = "openers-closers-mod-3", .head = "a**b", .unit = "c* " },
    .{ .name = "link-openers-emph-closers", .unit = "[ a_" },
    .{ .name = "paren-bracket", .unit = "[ (](" },
    .{ .name = "nested-brackets", .unit = "[", .tail = "a" },
    .{ .name = "nested-brackets-close", .head = "a", .unit = "]" },
    .{ .name = "nested-quotes-a", .unit = "> ", .tail = "a" },
    .{ .name = "nul-bytes", .unit = "abc\x00de\x00" },
    .{ .name = "unclosed-links-a", .unit = "[a](<b" },
    .{ .name = "unclosed-links-b", .unit = "[a](b" },
    .{ .name = "unclosed-comments", .head = "</", .unit = "<!--" },
    .{ .name = "tabs", .head = "- ", .unit = "\t", .tail = "a" },
    .{ .name = "backslashes", .unit = "\\" },
    .{ .name = "entities", .unit = "&#x" },
    // The dialect's corners.
    .{ .name = "emails-dead", .unit = "a_b." },
    .{ .name = "email-ats", .unit = "a@" },
    .{ .name = "emails", .unit = "a.b@c.d " },
    .{ .name = "www", .unit = "www." },
    .{ .name = "urls", .unit = "http://a.b/(c) " },
    .{ .name = "url-parens", .head = "http://a.b/", .unit = ")" },
    .{ .name = "code-spans", .unit = "`a` " },
    .{ .name = "code-runs", .unit = "``` " },
    .{ .name = "img-bait", .unit = "<img src=\"/a.png\"" },
    .{ .name = "imgs", .unit = "<img src=\"/a.png\" alt=x>" },
    .{ .name = "videos", .unit = "<video src=\"/v.mp4\"></video>" },
    .{ .name = "links", .unit = "[t](http://x.com) " },
    .{ .name = "msg-bait", .unit = "MSG_" },
    .{ .name = "fences", .unit = "~~~\n" },
    .{ .name = "fences-backtick", .unit = "```\n" },
    .{ .name = "headings", .unit = "# a\n" },
    .{ .name = "bullets", .unit = "- " },
    .{ .name = "bullet-lines", .unit = "- a\n" },
    .{ .name = "ordered-lines", .unit = "1. a\n" },
    .{ .name = "loose-lines", .unit = "- a\n\n" },
    .{ .name = "html-block-lines", .unit = "<div>\n" },
    .{ .name = "quote-lines", .unit = ">a\n" },
    .{ .name = "hard-wraps", .unit = "a\n" },
    .{ .name = "blank-lines", .unit = "\n" },
    .{ .name = "words", .unit = "word " },
    .{ .name = "mixed", .unit = "*a* _b_ `c` [d](e) MSG_f_1 g@h.i www.j.k\n" },
};

const sizes = [_]usize{ 1, 2, 3, 4, 10, 100, 1000 };

/// Every shape at every size, and the two shapes that are no repeat: a list
/// whose every line indents one level more (the nesting cap), and a run of
/// backtick runs each one longer (cmark's "backticks").
fn hostileCases(a: std.mem.Allocator) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    for (shapes) |s| {
        for (sizes) |n| {
            var md: std.ArrayList(u8) = .empty;
            try md.appendSlice(a, s.head);
            for (0..n) |_| try md.appendSlice(a, s.unit);
            try md.appendSlice(a, s.tail);
            try cases.append(a, .{ .id = try std.fmt.allocPrint(a, "hostile/{s}/{d}", .{ s.name, n }), .md = md.items });
        }
    }
    for ([_]usize{ 2, 17, 40, 200 }) |n| {
        var stair: std.ArrayList(u8) = .empty;
        var ticks: std.ArrayList(u8) = .empty;
        var quotes: std.ArrayList(u8) = .empty;
        try ticks.append(a, 'e');
        for (0..n) |i| {
            for (0..i * 2) |_| try stair.append(a, ' ');
            try stair.appendSlice(a, "- a\n");
            for (0..i + 1) |_| try ticks.append(a, '`');
            try ticks.append(a, ' ');
            for (0..i + 1) |_| try quotes.append(a, '>');
            try quotes.appendSlice(a, " a\n");
        }
        try cases.append(a, .{ .id = try std.fmt.allocPrint(a, "hostile/list-stair/{d}", .{n}), .md = stair.items });
        try cases.append(a, .{ .id = try std.fmt.allocPrint(a, "hostile/backtick-stair/{d}", .{n}), .md = ticks.items });
        try cases.append(a, .{ .id = try std.fmt.allocPrint(a, "hostile/quote-stair/{d}", .{n}), .md = quotes.items });
    }
    // **ACROSS THE BUDGET'S EDGE**: a run of backtick runs each one longer
    // is quadratic (each unmatched run scans to the line's end), so as n
    // grows it crosses the ceiling, at a different charge each n. Swept in
    // every context a line renders in, so each check point (a block line,
    // an inline step, a label's, emphasis's) is the one that trips.
    const contexts = [_][2][]const u8{
        .{ "", "" },                     .{ "# ", "" },                .{ "- ", "" },
        .{ "> ", "" },                   .{ "[", "](u)" },             .{ "*a* _b_ ", " **c** *d* _e_" },
        .{ "text\n", "\nmore\n\nnext" }, .{ "```\n", "\n```\nafter" }, .{ "- a\n  - ", "\n- b" },
    };
    for (contexts, 0..) |ctx, ci| {
        var n: usize = 20;
        while (n <= 140) : (n += 3) {
            var md: std.ArrayList(u8) = .empty;
            try md.appendSlice(a, ctx[0]);
            for (0..n) |i| {
                for (0..i + 1) |_| try md.append(a, '`');
                try md.append(a, 'x');
            }
            try md.appendSlice(a, ctx[1]);
            try cases.append(a, .{ .id = try std.fmt.allocPrint(a, "hostile/edge/{d}/{d}", .{ ci, n }), .md = md.items });
        }
    }
    return cases.items;
}

// ── the fuzzer ──────────────────────────────────────────────────────────────

/// The dialect's tokens, and the text between them: a random message is a
/// run of these.
const tokens = [_][]const u8{
    "a",                              "b",                 "word",                 " ",                              "  ",             "    ",
    "\t",                             "\n",                "\n\n",                 "\r\n",                           "*",              "**",
    "***",                            "_",                 "__",                   "`",                              "``",             "```",
    "~~~",                            "~~~~",              "[",                    "]",                              "(",              ")",
    "](",                             "<",                 ">",                    "> ",                             "- ",             "+ ",
    "* ",                             "1. ",               "2) ",                  "10. ",                           "# ",             "### ",
    "####### ",                       "#",                 "MSG_a_1",              "MSG_x-y_22",                     "MSG_",           "_1",
    "http://a.b/c",                   "https://x.y",       "www.a.b",              "HTTP://Q.R",                     "a@b.c",          "x.y_z@q-r.s",
    "<img src=\"/a.png\" alt=\"x\">", "<img src=\"//e\">", "<IMG SRC=/b width=3>", "<video src=\"/v.mp4\"></video>", "<video src=/v>", "</video>",
    "<b>",                            "</b>",              "<div>",                "<!--",                           "&",              "\"",
    "'",                              "!",                 "?",                    ".",                              ",",              ":",
    "javascript:",                    "data:image/png",    "data:x",               "java\tscript:",                  "\\",             "|",
    "é",
    "\x00",                           "\x01",              "  - ",                 "    - ",                         "quote",          "```quote",
    "~~~ zig",                        "1",                 "0",                    "=",                              "/",
};

const Prng = std.Random.DefaultPrng;

fn fuzzCase(a: std.mem.Allocator, rand: std.Random) ![]const u8 {
    var md: std.ArrayList(u8) = .empty;
    const n = rand.intRangeAtMost(usize, 1, if (rand.boolean()) 24 else 160);
    for (0..n) |_| try md.appendSlice(a, tokens[rand.uintLessThan(usize, tokens.len)]);
    return md.items;
}

/// N random messages, each judged; a difference is named `fuzz/<seed>/<k>`
/// and appended, text and all (it is generated, no one's message), to
/// fuzz_found.jsonl.
fn fuzz(io: Io, alloc: std.mem.Allocator, n: usize, seed: u64) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var found: std.ArrayList(u8) = .empty;
    defer found.deinit(alloc);
    var prng = Prng.init(seed);
    var t: Tally = .{};
    for (0..n) |k| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const md = try fuzzCase(a, prng.random());
        const v = try judge(a, md);
        if (v == .same) {
            t.pass += 1;
            continue;
        }
        t.fail += 1;
        const id = try std.fmt.allocPrint(a, "fuzz/{d}/{d}", .{ seed, k });
        printFailure("fuzz", id, v);
        try found.print(alloc, "{{\"id\":{f},\"md\":{f}}}\n", .{ std.json.fmt(id, .{}), std.json.fmt(md, .{}) });
    }
    if (found.items.len > 0) {
        const old = Io.Dir.cwd().readFileAlloc(io, fuzz_found_path, alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => try alloc.dupe(u8, ""),
            else => return e,
        };
        defer alloc.free(old);
        const all = try std.mem.concat(alloc, u8, &.{ old, found.items });
        defer alloc.free(all);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = fuzz_found_path, .data = all });
    }
    std.debug.print("== fuzz (seed {d}): {d}/{d} agree ({d} differ)\n", .{ seed, t.pass, n, t.fail });
    if (found.items.len > 0) std.debug.print("   each difference appended to {s}: commit it, a corpus\n", .{fuzz_found_path});
}

// ── the ratchet ─────────────────────────────────────────────────────────────

const Rung = struct { label: []const u8, pass: usize };

/// ratchet.txt's lines, `<label> <pass count>`.
fn readRatchet(io: Io, a: std.mem.Allocator) ![]Rung {
    const data = Io.Dir.cwd().readFileAlloc(io, ratchet_path, a, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var rungs: std.ArrayList(Rung) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.RatchetLineHasNoCount;
        try rungs.append(a, .{ .label = line[0..sp], .pass = try std.fmt.parseInt(usize, line[sp + 1 ..], 10) });
    }
    return rungs.items;
}

fn rungFor(rungs: []const Rung, label: []const u8) ?usize {
    for (rungs) |r| if (std.mem.eql(u8, r.label, label)) return r.pass;
    return null;
}

const Result = struct { label: []const u8, t: Tally, ratcheted: bool };

fn writeRatchet(io: Io, a: std.mem.Allocator, results: []const Result) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# The markdown twin's pass counts (src/markdown_twin_test.zig): each may only rise.\n");
    for (results) |r| if (r.ratcheted) try out.print(a, "{s} {d}\n", .{ r.label, r.t.pass });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ratchet_path, .data = out.items });
}

fn usage() noreturn {
    std.debug.print("arguments: --also PATH, --raise, --fuzz N [--seed S], --time\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = std.heap.page_allocator;
    var setup = std.heap.ArenaAllocator.init(alloc);
    defer setup.deinit();
    const sa = setup.allocator();

    var also: std.ArrayList([]const u8) = .empty;
    var raise = false;
    var timed = false;
    var fuzz_n: ?usize = null;
    var seed: u64 = 1;
    const args = try init.minimal.args.toSlice(sa);
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const arg = args[k];
        if (std.mem.eql(u8, arg, "--raise")) {
            raise = true;
        } else if (std.mem.eql(u8, arg, "--time")) {
            timed = true;
        } else if (std.mem.eql(u8, arg, "--also") and k + 1 < args.len) {
            k += 1;
            try also.append(sa, args[k]);
        } else if (std.mem.eql(u8, arg, "--fuzz") and k + 1 < args.len) {
            k += 1;
            fuzz_n = std.fmt.parseInt(usize, args[k], 10) catch usage();
        } else if (std.mem.eql(u8, arg, "--seed") and k + 1 < args.len) {
            k += 1;
            seed = std.fmt.parseInt(u64, args[k], 10) catch usage();
        } else usage();
    }

    twin.use(alloc);
    defer twin.deinit();

    if (fuzz_n) |n| return fuzz(io, alloc, n, seed);

    // The corpora: the list's (ratcheted), the hostile shapes (ratcheted),
    // then each --also (counted, never ratcheted).
    const Corpus = struct { label: []const u8, cases: []const Case, ratcheted: bool };
    var corpora: std.ArrayList(Corpus) = .empty;
    const list = try Io.Dir.cwd().readFileAlloc(io, corpora_list, sa, .unlimited);
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try corpora.append(sa, .{ .label = labelOf(line), .cases = try readCorpus(io, sa, line), .ratcheted = true });
    }
    try corpora.append(sa, .{ .label = "hostile", .cases = try hostileCases(sa), .ratcheted = true });
    for (also.items) |path| try corpora.append(sa, .{ .label = labelOf(path), .cases = try readCorpus(io, sa, path), .ratcheted = false });

    const rungs = try readRatchet(io, sa);
    var results: std.ArrayList(Result) = .empty;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var fell = false;
    var total: Tally = .{};
    for (corpora.items) |c| {
        const t = try judgeCases(&arena, c.label, c.cases);
        total.pass += t.pass;
        total.fail += t.fail;
        total.hostile += t.hostile;
        try results.append(sa, .{ .label = c.label, .t = t, .ratcheted = c.ratcheted });
        std.debug.print("== {s}: {d}/{d} agree ({d} differ; {d} hostile)", .{ c.label, t.pass, t.pass + t.fail, t.fail, t.hostile });
        if (c.ratcheted) {
            const floor = rungFor(rungs, c.label) orelse 0;
            if (t.pass < floor) {
                fell = true;
                std.debug.print("  BELOW THE RATCHET ({d})", .{floor});
            } else if (t.pass > floor) {
                std.debug.print("  the ratchet ({d}) can rise: --raise", .{floor});
            }
        }
        std.debug.print("\n", .{});
        if (timed) try timeCorpus(&arena, c.cases);
    }
    std.debug.print("==> {d}/{d} agree ({d} differ; {d} hostile)\n", .{ total.pass, total.pass + total.fail, total.fail, total.hostile });
    if (fell) {
        std.debug.print("a corpus fell below its ratchet ({s})\n", .{ratchet_path});
        std.process.exit(1);
    }
    if (raise) {
        try writeRatchet(io, sa, results.items);
        std.debug.print("ratchet rewritten: {s}\n", .{ratchet_path});
    }
}

/// A corpus's `render` time, the Zig's and the Roc's (through the twin,
/// which also answers the other four, so the Roc's is the call's whole).
fn timeCorpus(arena: *std.heap.ArenaAllocator, cases: []const Case) !void {
    var zig_ms: f64 = 0;
    var roc_ms: f64 = 0;
    for (cases) |c| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const t0 = cpuMs();
        _ = try zigAnswers(a, c.md);
        const t1 = cpuMs();
        _ = twin.call(a, markdown_answers, &.{c.md}) catch {};
        zig_ms += t1 - t0;
        roc_ms += cpuMs() - t1;
    }
    std.debug.print("   time: zig {d:.1} ms, roc {d:.1} ms (all five answers each)\n", .{ zig_ms, roc_ms });
}

/// The process's CPU time so far, in milliseconds (chat_codec_bench.zig's).
fn cpuMs() f64 {
    const r = std.posix.getrusage(std.posix.rusage.SELF);
    const us = (r.utime.sec + r.stime.sec) * std.time.us_per_s + r.utime.usec + r.stime.usec;
    return @as(f64, @floatFromInt(us)) / 1000;
}
