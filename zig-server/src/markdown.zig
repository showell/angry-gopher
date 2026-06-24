//! markdown: the block workhorse + public entry points of the chat dialect.
//! render()/renderTrusted()/hostileReason() live here, along with the recursive
//! block layer (paragraphs, ATX headings, fenced code, lists, blockquotes, the
//! raw-HTML block) — one mutually-recursive descent kept whole on purpose.
//!
//! The leaf pieces it drives, each its own file (one-way DAG, no cycles):
//!   markdown_text   — escaping + char-class predicates (pure leaf; everyone uses it)
//!   markdown_fence  — the fenced-code grammar (line-based predicates)
//!   markdown_media  — the locked same-origin <img>/<video> rebuilder (safety + dims)
//!   markdown_inline — the inline pass (emphasis, code spans, links, autolinks),
//!                     which also emits MSG_ refs + external-link attrs inline
//!   markdown_links  — the MSG_-reference + external-link RULES (helpers the
//!                     inline pass calls at emit time; no longer a post-pass)
//!
//! markdown.zig (this file) IS the dialect's source of truth; the gold corpus in
//! markdown_regression_test.zig freezes render()'s output so nothing here can
//! silently regress.

const std = @import("std");
const fence = @import("markdown_fence.zig");
const mtext = @import("markdown_text.zig");
const mmedia = @import("markdown_media.zig");
const minline = @import("markdown_inline.zig");

// Shared text primitives live in the markdown_text leaf; alias the few the block
// layer still uses so the renderer bodies read unqualified.
const escapeInto = mtext.escapeInto;
const isDigit = mtext.isDigit;
const isAsciiAlpha = mtext.isAsciiAlpha;

/// render turns a raw chat message body into HTML. It implements — and IS the
/// definition of — lynrummy's markdown dialect: GFM-style paragraphs with hard
/// wraps, escape-but-img, and MSG_ reference links emitted inline. (The dialect's
/// ancestry is goldmark/CommonMark, but there is no external oracle: the gold
/// corpus in markdown_regression_test.zig freezes THIS function's output so it
/// can't regress.)
/// Currently: paragraphs (hard wraps + escaping), raw HTML (escape everything
/// but a same-origin <img>, block and inline), and MSG_ reference links + the
/// external-link new-tab rule, both produced by the inline pass at emit time.
///
/// Caller owns the returned slice; pass an arena and reset it per message.
///
/// Before parsing, hostile/over-formatted input is rejected as malformed (see
/// hostileReason) — a defence-in-depth belt over the linear-by-construction
/// parser (the inline scanners use monotonic cursors so no input is super-
/// linear; this cap just refuses absurd inputs outright). Callers that write
/// (chat send, docs post) check hostileReason themselves first to fail the
/// POST loudly; this guard covers every other render path (backlog, preview).
pub fn render(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    if (hostileReason(md) != null) return a.dupe(u8, malformed_html);
    return try renderBlocks(a, md, false);
}

/// renderTrusted is render() for SERVER-OWNED content (not user-submitted): the
/// same block/inline pipeline, but WITHOUT the hostile-input token cap. A curated
/// file like the per-user Links page legitimately carries far more than 256 link
/// tokens, which render() would reject wholesale. The structural crash guards
/// (block-nesting depth) and HTML escaping still apply. NEVER call this on input
/// that came from a request body.
pub fn renderTrusted(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    return try renderBlocks(a, md, false);
}

/// renderTrustedReflow is renderTrusted for PROSE (blog articles): paragraphs
/// reflow to the reader's viewport. A source line wrap joins with a single space
/// rather than a hard `<br>`, so an inline span (emphasis, code, link) can cross
/// an author's line wrap, and the text rewraps to the reader's width. The
/// hard-wrap dialect — every newline a `<br>` — stays the default for chat/docs,
/// where a line break is content; reflow is only for server-owned long-form
/// writing. Same trusted (uncapped) pipeline as renderTrusted otherwise.
pub fn renderTrustedReflow(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    return try renderBlocks(a, md, true);
}

/// malformed_html is what a rejected (hostile / over-formatted) message renders
/// to instead of its content. A plain escaped paragraph — no styling shipped
/// from the server (the client may style .md-malformed).
pub const malformed_html = "<p class=\"md-malformed\">⚠️ malformed markdown — not rendered</p>\n";

/// max_markup_tokens caps how many inline markup characters (`* _ [ ] ` ~ <`)
/// a single message/doc may contain OUTSIDE fenced code. Ordinary prose uses a
/// handful; a flood (hundreds–thousands) is an attack or a paste accident, and
/// some of those constructs drive the inline scanners (links, emphasis, email
/// autolinks). Real conversation never approaches this; past it we reject the
/// whole input as malformed rather than render it. Fenced code is exempt —
/// snake_case and indexing are ordinary text there, and code never reaches the
/// inline scanners anyway. (Steve, 2026-06-19: reject over-formatted input
/// rather than risk the server; "no more than ~256 non-ordinary-text tokens.")
const max_markup_tokens = 256;

/// hostileReason scans `md` once and returns a short reason if it's hostile or
/// absurdly over-formatted (and should render as malformed_html / be refused at
/// POST), or null if it's safe to render. Cheap and linear: a single line walk
/// that skips fenced code blocks and counts inline markup characters elsewhere.
pub fn hostileReason(md: []const u8) ?[]const u8 {
    var tokens: usize = 0;
    var fence_char: u8 = 0; // 0 = not inside a fenced code block
    var fence_count: usize = 0;
    var pos: usize = 0;
    while (pos < md.len) {
        const eol = lineEnd(md, pos);
        const line = md[pos..eol];
        const next = if (eol < md.len) eol + 1 else md.len;
        if (fence_char != 0) {
            // Inside a fenced code block: code is ordinary text, count nothing.
            if (fence.isClose(line, fence_char, fence_count)) fence_char = 0;
        } else if (parseFenceOpen(md, pos)) |fo| {
            fence_char = fo.char;
            fence_count = fo.count;
        } else {
            for (line) |c| switch (c) {
                '*', '_', '[', ']', '`', '~', '<' => {
                    tokens += 1;
                    if (tokens > max_markup_tokens) return "too much markdown formatting";
                },
                else => {},
            };
        }
        pos = next;
    }
    return null;
}

// --- block rendering --------------------------------------------------------

fn renderBlocks(a: std.mem.Allocator, md: []const u8, soft_wrap: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try renderBlocksInto(&out, a, md, false, 0, soft_wrap);
    return out.toOwnedSlice(a);
}

/// max_block_depth caps blockquote/list nesting. Each nesting level is a
/// renderQuote/renderList → renderBlocksInto recursion that copies the inner
/// source, so an unbounded nest (`> > > …` or deeply-indented lists) is both
/// O(depth) stack (→ stack overflow) and O(depth²) memory — a single hostile
/// message or doc could crash the server. Ordinary conversation never nests
/// past ~10 (the corpus max is 1); past this we degrade to a flat escaped
/// paragraph rather than recurse. Found by the adversarial stress harness, then
/// tightened from 256 to ~10-levels-of-headroom (Steve, 2026-06-19: "nothing
/// should ever be more than about 10 levels nested in ordinary conversation").
const max_block_depth = 16;

/// renderBlocksInto is the block dispatcher. `tight` is set when rendering the
/// contents of a tight list item: paragraphs emit their inline content with no
/// <p> wrapper, and blocks are newline-separated rather than each carrying a
/// trailing newline of its own. `depth` is the block-nesting level (see
/// max_block_depth) — past the cap, the remaining source renders as one escaped
/// paragraph with no further block recursion.
fn renderBlocksInto(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, tight: bool, depth: usize, soft_wrap: bool) std.mem.Allocator.Error!void {
    if (depth > max_block_depth) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, "<p>");
        try minline.renderInline(out, a, md, true);
        try out.appendSlice(a, "</p>\n");
        return;
    }
    var pos: usize = 0;
    while (pos < md.len) {
        const eol = lineEnd(md, pos);
        const line = md[pos..eol];
        const next = if (eol < md.len) eol + 1 else md.len;

        if (isBlank(line)) {
            pos = next;
            continue;
        }

        // A fenced code block can interrupt a paragraph, so check it first.
        if (parseFenceOpen(md, pos)) |fo| {
            try tightSep(out, a, tight);
            pos = try renderFence(out, a, md, fo);
            continue;
        }

        // ATX heading (also interrupts a paragraph).
        if (atxHeading(line)) |h| {
            try tightSep(out, a, tight);
            const d: u8 = '0' + @as(u8, @intCast(h.level));
            try out.appendSlice(a, &[_]u8{ '<', 'h', d, '>' });
            try minline.renderInline(out, a, h.content, true);
            try out.appendSlice(a, &[_]u8{ '<', '/', 'h', d, '>', '\n' });
            pos = next;
            continue;
        }

        // A list (bullet or ordered). A list can interrupt a paragraph (bullet
        // always; ordered only when it starts at 1) provided its first item is
        // non-empty, so it's checked before the paragraph branch.
        if (listMarkerAt(md, pos)) |lm| {
            try tightSep(out, a, tight);
            pos = try renderList(out, a, md, pos, lm, depth, soft_wrap);
            continue;
        }

        // A blockquote (also interrupts a paragraph).
        if (quoteMarkerLen(line) != null) {
            try tightSep(out, a, tight);
            pos = try renderQuote(out, a, md, pos, depth, soft_wrap);
            continue;
        }

        // An HTML block (CommonMark type 7) starts only at a block boundary —
        // it can't interrupt a paragraph — and runs until a blank line. We
        // emit its raw source through the escape-but-<img> scan, with no <p>
        // wrapper and no added newline (the source passes through unchanged).
        if (isHtmlBlockStart(line)) {
            try tightSep(out, a, tight);
            var p = next;
            while (p < md.len) {
                const e2 = lineEnd(md, p);
                if (isBlank(md[p..e2])) break;
                p = if (e2 < md.len) e2 + 1 else md.len;
            }
            try writeRawHtml(out, a, md[pos..p]);
            pos = p;
            continue;
        }

        // Otherwise a paragraph: a maximal run of non-blank lines, each
        // hard-wrapped with <br>, inline raw HTML handled the same way. A
        // fence, heading, or interrupting list on a later line ends it.
        try tightSep(out, a, tight);
        if (!tight) try out.appendSlice(a, "<p>");
        var p = pos;
        var first = true;
        var reflow: std.ArrayList(u8) = .empty; // accumulates the joined paragraph (soft_wrap only)
        while (p < md.len) {
            const e2 = lineEnd(md, p);
            const l2 = md[p..e2];
            if (isBlank(l2)) break;
            if (parseFenceOpen(md, p) != null) break;
            if (atxHeading(l2) != null) break;
            if (listInterruptsAt(md, p)) break;
            if (quoteMarkerLen(l2) != null) break;
            if (soft_wrap) {
                // Reflow: wrapped source lines join with one space and the whole
                // paragraph goes to the inline pass once (below), so an inline
                // span can cross an author's line wrap and the text rewraps to
                // the reader's width.
                if (!first) try reflow.append(a, ' ');
                try reflow.appendSlice(a, trimLine(l2));
            } else {
                // Hard-wrap dialect: each source line is its own line, joined by
                // a <br>, and rendered inline on its own.
                if (!first) try out.appendSlice(a, "<br>\n");
                try minline.renderInline(out, a, trimLine(l2), true);
            }
            first = false;
            p = if (e2 < md.len) e2 + 1 else md.len;
        }
        if (soft_wrap) try minline.renderInline(out, a, reflow.items, true);
        if (!tight) try out.appendSlice(a, "</p>\n");
        pos = p;
    }
}

/// tightSep inserts the inter-block separator newline used inside a tight list
/// item: a bare paragraph joins a following block with one '\n'.
fn tightSep(out: *std.ArrayList(u8), a: std.mem.Allocator, tight: bool) !void {
    if (tight and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(a, '\n');
    }
}

// --- fenced code blocks (incl. the `quote` extension) -----------------------

/// FenceOpen is fence.Open plus the document offset of the first content line,
/// which the offset-based renderer needs and the line-based fence grammar can't
/// supply on its own.
const FenceOpen = struct {
    char: u8,
    count: usize,
    indent: usize,
    lang: []const u8,
    body_start: usize, // index of the first content line
};

/// parseFenceOpen recognizes a fence opening at md[pos] (line start), delegating
/// the grammar to fence.parseOpen (the shared, length-aware, depth-capped
/// definition) and adding the document offset of the body.
fn parseFenceOpen(md: []const u8, pos: usize) ?FenceOpen {
    const eol = lineEnd(md, pos);
    const o = fence.parseOpen(md[pos..eol]) orelse return null;
    return .{
        .char = o.char,
        .count = o.count,
        .indent = o.indent,
        .lang = o.lang,
        .body_start = if (eol < md.len) eol + 1 else md.len,
    };
}

const Heading = struct { level: usize, content: []const u8 };

/// atxHeading recognizes "# … " through "###### … ": 1-6 '#' after up to 3
/// spaces, then a space (or end of line). An optional trailing run of '#'
/// (the closing sequence) is stripped.
fn atxHeading(line: []const u8) ?Heading {
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) {
        indent += 1;
    }
    if (indent >= 4) return null;
    var level: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {
        level += 1;
    }
    if (level == 0 or level > 6) return null;
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;

    var content = std.mem.trim(u8, line[i..], " \t");
    var h = content.len;
    while (h > 0 and content[h - 1] == '#') : (h -= 1) {}
    if (h < content.len and (h == 0 or content[h - 1] == ' ' or content[h - 1] == '\t')) {
        content = std.mem.trim(u8, content[0..h], " \t");
    }
    return .{ .level = level, .content = content };
}

/// renderFence emits the code block and returns the position after the closing
/// fence (or EOF when there is none — an unterminated fence runs to the end).
fn renderFence(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, fo: FenceOpen) !usize {
    var content_end = md.len;
    var after = md.len;
    var p = fo.body_start;
    while (p < md.len) {
        const e = lineEnd(md, p);
        if (fence.isClose(md[p..e], fo.char, fo.count)) {
            content_end = p;
            after = if (e < md.len) e + 1 else md.len;
            break;
        }
        p = if (e < md.len) e + 1 else md.len;
    }
    const content = md[fo.body_start..content_end];

    const is_quote = std.mem.eql(u8, fo.lang, "quote");
    if (is_quote) {
        try out.appendSlice(a, "<pre class=\"chat-quote\">");
    } else {
        try out.appendSlice(a, "<pre><code");
        if (fo.lang.len > 0) {
            try out.appendSlice(a, " class=\"language-");
            try escapeInto(out, a, fo.lang);
            try out.append(a, '"');
        }
        try out.append(a, '>');
    }

    try writeCodeLines(out, a, content, fo.indent);

    try out.appendSlice(a, if (is_quote) "</pre>\n" else "</code></pre>\n");
    return after;
}

/// writeCodeLines emits each content line escaped and newline-terminated
/// (the final line is normalized to end with '\n'), stripping up to the
/// fence's own indentation from each line.
fn writeCodeLines(out: *std.ArrayList(u8), a: std.mem.Allocator, content: []const u8, indent: usize) !void {
    var i: usize = 0;
    while (i < content.len) {
        const e = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        var line = content[i..e];
        var s: usize = 0;
        while (s < line.len and s < indent and line[s] == ' ') : (s += 1) {}
        line = line[s..];
        try escapeInto(out, a, line);
        try out.append(a, '\n');
        i = if (e < content.len) e + 1 else content.len;
    }
}

// --- lists (bullet + ordered, tight/loose, nesting) -------------------------

const ListMarker = struct {
    ordered: bool,
    start: usize, // ordered start number
    delim: u8, // ordered delimiter '.' or ')'
    bullet: u8, // bullet char '-' '+' '*'
    indent: usize, // leading spaces before the marker
    content_col: usize, // column where the item content begins (dedent width)
    content_start: usize, // index in md of the first content char on this line
};

/// listMarkerAt recognizes a list item marker at the line starting at md[pos]:
/// up to 3 leading spaces, a bullet (`-`/`+`/`*`) or `<digits>.`/`<digits>)`,
/// then a space/tab (or end of line for an empty item).
fn listMarkerAt(md: []const u8, pos: usize) ?ListMarker {
    const eol = lineEnd(md, pos);
    const line = md[pos..eol];
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) indent += 1;
    if (indent >= 4 or i >= line.len) return null;

    var m = ListMarker{ .ordered = false, .start = 0, .delim = 0, .bullet = 0, .indent = indent, .content_col = 0, .content_start = 0 };
    if (line[i] == '-' or line[i] == '+' or line[i] == '*') {
        m.bullet = line[i];
        i += 1;
    } else if (isDigit(line[i])) {
        const ds = i;
        while (i < line.len and isDigit(line[i]) and (i - ds) < 9) : (i += 1) {}
        if (i >= line.len or (line[i] != '.' and line[i] != ')')) return null;
        m.ordered = true;
        m.delim = line[i];
        m.start = std.fmt.parseInt(usize, line[ds..i], 10) catch return null;
        i += 1;
    } else return null;

    // The marker must be followed by whitespace (or end the line: empty item).
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;
    const marker_end = i;
    var sp: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) sp += 1;

    // 1-4 spaces become the content indent; >4 means only one is consumed (the
    // rest is the content, possibly indented code); an empty item indents by 1.
    const after_spaces = marker_end + sp;
    if (marker_end >= line.len) {
        m.content_col = marker_end + 1;
        m.content_start = eol;
    } else if (sp == 0 or sp > 4) {
        m.content_col = marker_end + 1;
        m.content_start = pos + marker_end + @as(usize, if (sp == 0) 0 else 1);
    } else {
        m.content_col = after_spaces;
        m.content_start = pos + after_spaces;
    }
    return m;
}

fn sameListType(b: ListMarker, a: ListMarker) bool {
    if (a.ordered != b.ordered) return false;
    return if (a.ordered) a.delim == b.delim else a.bullet == b.bullet;
}

/// listInterruptsAt reports whether a list marker at md[pos] may interrupt an
/// open paragraph: the item must be non-empty, and an ordered list must start
/// at 1 (CommonMark's paragraph-interruption rules).
fn listInterruptsAt(md: []const u8, pos: usize) bool {
    const m = listMarkerAt(md, pos) orelse return false;
    const eol = lineEnd(md, pos);
    if (m.content_start >= eol) return false; // empty item can't interrupt
    if (m.ordered and m.start != 1) return false;
    return true;
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

/// renderList consumes a whole list beginning at md[pos] (with first marker m0)
/// and returns the position just past it. Items are collected as dedented
/// content blocks and rendered recursively; tight/loose controls <p> wrapping.
fn renderList(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, pos: usize, m0: ListMarker, depth: usize, soft_wrap: bool) std.mem.Allocator.Error!usize {
    var items: std.ArrayList([]const u8) = .empty;
    var loose = false;

    var cur: std.ArrayList(u8) = .empty;
    var have_item = false;
    var cur_col = m0.content_col;
    var blanks: usize = 0;
    var p = pos;

    while (p < md.len) {
        const e = lineEnd(md, p);
        const line = md[p..e];
        const next = if (e < md.len) e + 1 else md.len;

        if (isBlank(line)) {
            blanks += 1;
            p = next;
            continue;
        }

        const indent = leadingSpaces(line);
        const marker = listMarkerAt(md, p);
        const is_new_item = marker != null and indent < cur_col;

        if (is_new_item) {
            if (!sameListType(marker.?, m0)) break; // a different marker ends the list
            if (have_item) {
                try items.append(a, try cur.toOwnedSlice(a));
                if (blanks > 0) loose = true;
            }
            cur = .empty;
            have_item = true;
            cur_col = marker.?.content_col;
            blanks = 0;
            try cur.appendSlice(a, md[marker.?.content_start..e]);
            try cur.append(a, '\n');
        } else if (indent >= cur_col and have_item) {
            // Indented continuation of the current item (its own nested blocks).
            if (blanks > 0) loose = true;
            blanks = 0;
            try cur.appendSlice(a, line[cur_col..]);
            try cur.append(a, '\n');
        } else if (blanks == 0 and have_item and !lineStartsBlock(md, p)) {
            // Lazy paragraph continuation: a non-indented line right after a
            // paragraph line still belongs to the item.
            try cur.appendSlice(a, line);
            try cur.append(a, '\n');
        } else break;

        p = next;
    }
    if (have_item) try items.append(a, try cur.toOwnedSlice(a));

    if (m0.ordered) {
        if (m0.start == 1) {
            try out.appendSlice(a, "<ol>\n");
        } else {
            try out.appendSlice(a, "<ol start=\"");
            var nbuf: [20]u8 = undefined;
            const ns = std.fmt.bufPrint(&nbuf, "{d}", .{m0.start}) catch unreachable;
            try out.appendSlice(a, ns);
            try out.appendSlice(a, "\">\n");
        }
    } else {
        try out.appendSlice(a, "<ul>\n");
    }
    for (items.items) |item| {
        // Render into a fresh buffer so the tight inter-block separator only
        // sees the item's own content, not the enclosing <li>.
        var inner: std.ArrayList(u8) = .empty;
        if (loose) {
            try inner.append(a, '\n');
            try renderBlocksInto(&inner, a, item, false, depth + 1, soft_wrap);
        } else {
            // we write a newline after a tight <li> iff its first child is not a
            // text paragraph (it's a nested list/quote/fence/heading).
            if (firstItemChildIsBlock(item)) try inner.append(a, '\n');
            try renderBlocksInto(&inner, a, item, true, depth + 1, soft_wrap);
        }
        try out.appendSlice(a, "<li>");
        try out.appendSlice(a, inner.items);
        try out.appendSlice(a, "</li>\n");
    }
    try out.appendSlice(a, if (m0.ordered) "</ol>\n" else "</ul>\n");
    return p;
}

/// firstItemChildIsBlock encodes our list-item rule: a tight <li> gets a
/// newline after it iff its first child is NOT a text paragraph — i.e. the item
/// content opens with a nested list, blockquote, fence, or heading. (Loose items
/// always get the newline; this is only consulted on the tight path.)
fn firstItemChildIsBlock(item: []const u8) bool {
    var pos: usize = 0;
    while (pos < item.len) {
        const e = lineEnd(item, pos);
        const line = item[pos..e];
        if (!isBlank(line)) {
            return listMarkerAt(item, pos) != null or
                quoteMarkerLen(line) != null or
                parseFenceOpen(item, pos) != null or
                atxHeading(line) != null;
        }
        pos = if (e < item.len) e + 1 else item.len;
    }
    return false;
}

/// lineStartsBlock reports whether md[pos] begins a block that a lazy paragraph
/// continuation may not absorb (a list item, blockquote, fence, heading, blank).
fn lineStartsBlock(md: []const u8, pos: usize) bool {
    const e = lineEnd(md, pos);
    const line = md[pos..e];
    if (isBlank(line)) return true;
    if (listMarkerAt(md, pos) != null) return true;
    if (quoteMarkerLen(line) != null) return true;
    if (parseFenceOpen(md, pos) != null) return true;
    if (atxHeading(line) != null) return true;
    return false;
}

// --- blockquotes ------------------------------------------------------------

/// quoteMarkerLen returns the prefix length to strip for a blockquote line: up
/// to 3 leading spaces, a '>', and one optional following space. null if the
/// line isn't a blockquote line.
fn quoteMarkerLen(line: []const u8) ?usize {
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) indent += 1;
    if (indent >= 4 or i >= line.len or line[i] != '>') return null;
    i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    return i;
}

/// renderQuote consumes a blockquote beginning at md[pos] and returns the
/// position just past it. '>'-prefixed lines (and lazy paragraph-continuation
/// lines, until a blank line) are stripped and rendered recursively.
fn renderQuote(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, pos: usize, depth: usize, soft_wrap: bool) std.mem.Allocator.Error!usize {
    var inner: std.ArrayList(u8) = .empty;
    var p = pos;
    var last_was_text = false;
    while (p < md.len) {
        const e = lineEnd(md, p);
        const line = md[p..e];
        const next = if (e < md.len) e + 1 else md.len;

        if (isBlank(line)) break; // a blank line ends the blockquote
        if (quoteMarkerLen(line)) |ql| {
            const stripped = line[ql..];
            try inner.appendSlice(a, stripped);
            try inner.append(a, '\n');
            last_was_text = !isBlank(stripped) and !lineStartsBlock(md, p + ql);
        } else if (last_was_text and !lineStartsBlock(md, p)) {
            // Lazy continuation of a paragraph inside the quote.
            try inner.appendSlice(a, line);
            try inner.append(a, '\n');
        } else break;
        p = next;
    }

    try out.appendSlice(a, "<blockquote>\n");
    try renderBlocksInto(out, a, inner.items, false, depth + 1, soft_wrap);
    try out.appendSlice(a, "</blockquote>\n");
    return p;
}

fn lineEnd(md: []const u8, pos: usize) usize {
    return std.mem.indexOfScalarPos(u8, md, pos, '\n') orelse md.len;
}

fn isBlank(line: []const u8) bool {
    return trimLine(line).len == 0;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

// --- raw HTML: escape everything but a locked, same-origin <img> ------------

/// writeRawHtml emits a chunk of raw HTML: each recognized same-origin <img> or
/// <video> is rebuilt from an attribute allowlist; everything else is
/// HTML-escaped to literal text.
fn writeRawHtml(out: *std.ArrayList(u8), a: std.mem.Allocator, raw: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '<') {
            i += 1;
            continue;
        }
        const safe = mmedia.safeImgAt(a, raw, i) orelse mmedia.safeVideoAt(a, raw, i);
        if (safe) |tag| {
            try escapeInto(out, a, raw[last..i]);
            try out.appendSlice(a, tag.html);
            i = tag.end;
            last = tag.end;
        } else {
            i += 1;
        }
    }
    try escapeInto(out, a, raw[last..]);
}

/// isHtmlBlockStart reports whether line opens a CommonMark type-7 HTML block:
/// a complete open/close tag followed by only whitespace.
fn isHtmlBlockStart(line: []const u8) bool {
    const t = trimLine(line);
    if (t.len < 2 or t[0] != '<') return false;
    if (!isAsciiAlpha(t[1]) and t[1] != '/') return false;
    const tag_end = htmlTagEnd(t) orelse return false;
    return trimLine(t[tag_end..]).len == 0;
}

/// htmlTagEnd returns the index just past the '>' that closes the tag opened
/// at t[0], respecting quoted attribute values, or null if unterminated.
fn htmlTagEnd(t: []const u8) ?usize {
    var i: usize = 1;
    while (i < t.len) {
        const c = t[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < t.len and t[i] != c) : (i += 1) {}
            if (i >= t.len) return null;
            i += 1;
        } else if (c == '>') {
            return i + 1;
        } else {
            i += 1;
        }
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "render: a same-origin <video> becomes a locked player" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const html = try render(arena.allocator(), "<video src=\"/chat/c/1_3/yo/uploads/abc.mp4\"></video>");
    try testing.expect(std.mem.indexOf(u8, html, "<video controls preload=\"metadata\" src=\"/chat/c/1_3/yo/uploads/abc.mp4\"></video>") != null);
}

test "render: video attrs are allowlisted (onerror dropped, digit dims kept)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const html = try render(arena.allocator(), "<video src=\"/u/x.webm\" width=\"320\" onerror=\"alert(1)\"></video>");
    try testing.expect(std.mem.indexOf(u8, html, "onerror") == null);
    try testing.expect(std.mem.indexOf(u8, html, "width=\"320\"") != null);
}

test "render: a cross-origin or unclosed <video> is escaped, not embedded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const off = try render(arena.allocator(), "<video src=\"https://evil/x.mp4\"></video>");
    try testing.expect(std.mem.indexOf(u8, off, "<video") == null);
    try testing.expect(std.mem.indexOf(u8, off, "&lt;video") != null);
    const unclosed = try render(arena.allocator(), "<video src=\"/u/x.mp4\">"); // no </video>
    try testing.expect(std.mem.indexOf(u8, unclosed, "<video") == null);
}

test "renderTrustedReflow: an inline span crosses a source wrap; prose reflows (no <br>)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const html = try renderTrustedReflow(arena.allocator(), "A **bold phrase that\nspans two lines** here.");
    // The wrap joins with a space, so the emphasis run closes and the text reflows.
    try testing.expect(std.mem.indexOf(u8, html, "<strong>bold phrase that spans two lines</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<br>") == null);
    try testing.expect(std.mem.indexOf(u8, html, "**") == null);
}

test "renderTrusted (hard-wrap dialect): a source wrap stays a <br>, inline is line-scoped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const html = try renderTrusted(arena.allocator(), "A **bold phrase that\nspans two lines** here.");
    // Chat/docs contract: every newline is a hard break and a span can't cross it.
    try testing.expect(std.mem.indexOf(u8, html, "<br>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<strong>") == null);
}
