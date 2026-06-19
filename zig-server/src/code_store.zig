//! code_store: the per-user Code transcript — Go's server/chat/code.go storage
//! half. Mirrors images_store in shape: every message-with-code-blocks a viewer
//! can see, collected oldest-first into {chat_root}/users/<uid>/code.md. Captured
//! blocks are stored verbatim as triple-backtick fences (the on-disk form
//! normalizes ~~~ openers to ``` too).
//!
//! The distinctive piece is extractCodeBlocks: a line-anchored fence state
//! machine (NOT a regex). It keeps ```lang and ~~~lang blocks but EXCLUDES
//! `~~~ quote` (the quote-reply marker), with a nesting-aware close so a
//! quote-of-a-quote doesn't end the outer block early. Byte-faithful to Go.
//!
//! Leaf module: reuses images_store's shared transcript-header parser +
//! source-URL helper, so the store doesn't depend on the UI layer.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");
const images_store = @import("images_store.zig");

/// code_sep joins entries on disk (same shape as the Images feed; Go's codeSep).
const code_sep = "\n\n-------------\n\n";

/// codeMu serializes all code.md reads/appends (coarser than Go's per-uid map).
var codeMu: Io.Mutex = .init;

pub const CodeBlock = struct { lang: []const u8, body: []const u8 };

pub const CodeEntry = struct {
    source_id: []const u8,
    from: []const u8,
    conv: []const u8,
    at: []const u8,
    blocks: []const CodeBlock,
};

fn userCodePath(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ store.chat_root, "users", uid, "code.md" });
}

// ── the fence extractor (Go's extractCodeBlocks, line-anchored state machine) ──

/// extractCodeBlocks walks `body` line by line tracking fence state. Opens on a
/// line starting ```/~~~ (lang = trimmed remainder); closes on a line that is
/// ONLY marker chars (≥3, trailing ws stripped — info text is NOT a close, per
/// CommonMark). `~~~ quote` blocks are SKIPPED entirely with a nesting-aware
/// close. Unclosed fences run to end-of-body (matching goldmark). Byte-faithful.
pub fn extractCodeBlocks(alloc: Alloc, body: []const u8) ![]const CodeBlock {
    var out: std.ArrayList(CodeBlock) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var lit = std.mem.splitScalar(u8, body, '\n');
    while (lit.next()) |ln| try lines.append(alloc, ln);
    const ls = lines.items;

    var i: usize = 0;
    while (i < ls.len) {
        const line = ls[i];
        var marker: u8 = 0;
        var lang: []const u8 = "";
        if (std.mem.startsWith(u8, line, "```")) {
            marker = '`';
            lang = std.mem.trim(u8, line[3..], " \t\r\n");
        } else if (std.mem.startsWith(u8, line, "~~~")) {
            marker = '~';
            lang = std.mem.trim(u8, line[3..], " \t\r\n");
        } else {
            i += 1;
            continue;
        }
        const is_quote = marker == '~' and std.mem.eql(u8, lang, "quote");
        const start = i + 1;
        var j = start;
        if (is_quote) {
            var depth: usize = 1;
            while (j < ls.len) : (j += 1) {
                if (isCloseFence(ls[j], marker)) {
                    depth -= 1;
                    if (depth == 0) break;
                } else if (std.mem.startsWith(u8, ls[j], "~~~")) {
                    depth += 1;
                }
            }
        } else {
            while (j < ls.len and !isCloseFence(ls[j], marker)) : (j += 1) {}
        }
        if (!is_quote) {
            const content = try std.mem.join(alloc, "\n", ls[start..j]);
            try out.append(alloc, .{ .lang = lang, .body = content });
        }
        i = j + 1;
    }
    return out.toOwnedSlice(alloc);
}

/// isCloseFence reports whether `line` is a valid closing fence: ≥3 chars, all
/// equal to `marker` after trailing-whitespace strip (no info text allowed).
fn isCloseFence(line: []const u8, marker: u8) bool {
    const stripped = std.mem.trimEnd(u8, line, " \t");
    if (stripped.len < 3) return false;
    for (stripped) |c| {
        if (c != marker) return false;
    }
    return true;
}

// ── format / parse / append / read (mirrors images_store) ─────────────────────

/// formatCodeEntry serializes an entry: the shared header line, then each block
/// as ```<lang>\n<body>\n``` (always backticks), blocks separated by one newline.
pub fn formatCodeEntry(alloc: Alloc, e: CodeEntry) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "Sent by {s} at {s}, source MSG_{s} in {s}:", .{ e.from, e.at, e.source_id, e.conv });
    for (e.blocks, 0..) |blk, i| {
        if (i > 0) try b.append(alloc, '\n');
        try b.print(alloc, "\n```{s}\n{s}\n```", .{ blk.lang, blk.body });
    }
    return b.toOwnedSlice(alloc);
}

/// parseCodeFile splits a code.md into entries (chronological), skipping a block
/// whose body yields no fences. Reuses images_store's shared header parser.
pub fn parseCodeFile(alloc: Alloc, text: []const u8) ![]CodeEntry {
    var out: std.ArrayList(CodeEntry) = .empty;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return out.toOwnedSlice(alloc);

    var it = std.mem.splitSequence(u8, text, code_sep);
    while (it.next()) |raw| {
        const block = std.mem.trim(u8, raw, " \t\r\n");
        if (block.len == 0) continue;
        const nl = std.mem.indexOfScalar(u8, block, '\n') orelse continue;
        const h = images_store.parseHeader(block[0..nl]) orelse continue;
        const blocks = try extractCodeBlocks(alloc, block[nl + 1 ..]);
        if (blocks.len == 0) continue;
        try out.append(alloc, .{
            .source_id = h.source_id,
            .from = h.from,
            .conv = h.conv,
            .at = h.at,
            .blocks = blocks,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// appendCodeEntry writes one entry to a user's code.md, prefixed by the
/// separator when the file is non-empty. Mirrors appendCodeEntryLocked.
pub fn appendCodeEntry(io: Io, alloc: Alloc, uid: []const u8, e: CodeEntry) !void {
    const path = try userCodePath(alloc, uid);
    const entry = try formatCodeEntry(alloc, e);

    codeMu.lockUncancelable(io);
    defer codeMu.unlock(io);

    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const existing = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
    const bytes = if (existing.len > 0)
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ code_sep, entry })
    else
        entry;

    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
}

/// readCodeForUser returns a user's code entries in chronological order. Missing
/// file → empty. Mirrors readCodeForUser.
pub fn readCodeForUser(io: Io, alloc: Alloc, uid: []const u8) ![]CodeEntry {
    const path = try userCodePath(alloc, uid);
    codeMu.lockUncancelable(io);
    defer codeMu.unlock(io);
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return &.{};
    return parseCodeFile(alloc, data);
}

/// encodeCodeEvent writes one codeSSEEvent JSON object into `j` (Go field order:
/// source_id, from, conv, at, blocks:[{lang,body}], source_url). Shared by the
/// page backlog and the live fanout.
pub fn encodeCodeEvent(j: *std.ArrayList(u8), alloc: Alloc, e: CodeEntry, source_url: []const u8) !void {
    try j.print(alloc, "{{\"source_id\":{f},\"from\":{f},\"conv\":{f},\"at\":{f},\"blocks\":[", .{
        std.json.fmt(e.source_id, .{}), std.json.fmt(e.from, .{}),
        std.json.fmt(e.conv, .{}),      std.json.fmt(e.at, .{}),
    });
    for (e.blocks, 0..) |blk, idx| {
        if (idx != 0) try j.append(alloc, ',');
        try j.print(alloc, "{{\"lang\":{f},\"body\":{f}}}", .{ std.json.fmt(blk.lang, .{}), std.json.fmt(blk.body, .{}) });
    }
    try j.print(alloc, "],\"source_url\":{f}}}", .{std.json.fmt(source_url, .{})});
}
