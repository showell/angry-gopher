const std = @import("std");
const fence = @import("fence.zig");

/// render turns a raw chat message body into HTML. It implements — and IS the
/// definition of — lynrummy's markdown dialect: GFM-style paragraphs with hard
/// wraps, then escape-but-img, then the MSG_ reference linkifier. (The dialect's
/// ancestry is goldmark/CommonMark, but there is no external oracle: the gold
/// corpus in main.zig freezes THIS function's output so it can't regress.)
/// Currently: paragraphs (hard wraps + escaping), raw HTML (escape everything
/// but a same-origin <img>, block and inline), and the MSG_ reference linkifier.
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
    const body = try renderBlocks(a, md);
    return try linkifyMsgRefs(a, body);
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

fn renderBlocks(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try renderBlocksInto(&out, a, md, false, 0);
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
fn renderBlocksInto(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, tight: bool, depth: usize) std.mem.Allocator.Error!void {
    if (depth > max_block_depth) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, "<p>");
        try renderInline(out, a, md);
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
            try renderInline(out, a, h.content);
            try out.appendSlice(a, &[_]u8{ '<', '/', 'h', d, '>', '\n' });
            pos = next;
            continue;
        }

        // A list (bullet or ordered). A list can interrupt a paragraph (bullet
        // always; ordered only when it starts at 1) provided its first item is
        // non-empty, so it's checked before the paragraph branch.
        if (listMarkerAt(md, pos)) |lm| {
            try tightSep(out, a, tight);
            pos = try renderList(out, a, md, pos, lm, depth);
            continue;
        }

        // A blockquote (also interrupts a paragraph).
        if (quoteMarkerLen(line) != null) {
            try tightSep(out, a, tight);
            pos = try renderQuote(out, a, md, pos, depth);
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
        while (p < md.len) {
            const e2 = lineEnd(md, p);
            const l2 = md[p..e2];
            if (isBlank(l2)) break;
            if (parseFenceOpen(md, p) != null) break;
            if (atxHeading(l2) != null) break;
            if (listInterruptsAt(md, p)) break;
            if (quoteMarkerLen(l2) != null) break;
            if (!first) try out.appendSlice(a, "<br>\n");
            first = false;
            try renderInline(out, a, trimLine(l2));
            p = if (e2 < md.len) e2 + 1 else md.len;
        }
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
fn renderList(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, pos: usize, m0: ListMarker, depth: usize) std.mem.Allocator.Error!usize {
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
            try renderBlocksInto(&inner, a, item, false, depth + 1);
        } else {
            // we write a newline after a tight <li> iff its first child is not a
            // text paragraph (it's a nested list/quote/fence/heading).
            if (firstItemChildIsBlock(item)) try inner.append(a, '\n');
            try renderBlocksInto(&inner, a, item, true, depth + 1);
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
fn renderQuote(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, pos: usize, depth: usize) std.mem.Allocator.Error!usize {
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
    try renderBlocksInto(out, a, inner.items, false, depth + 1);
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
        const safe = safeImgAt(a, raw, i) orelse safeVideoAt(a, raw, i);
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

const ImgAttrs = struct {
    src: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    title: ?[]const u8 = null,
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    end: usize = 0, // index just past '>'
};

/// SafeTag is a rebuilt locked tag's HTML plus the index past the source span
/// it consumed (the '>' of a void <img>, or the </video> of a <video>).
const SafeTag = struct { html: []const u8, end: usize };

/// safeImgAt parses a single <img …> beginning at raw[start] and, if its src
/// is same-origin, returns the rebuilt locked tag plus the index past '>'.
fn safeImgAt(a: std.mem.Allocator, raw: []const u8, start: usize) ?SafeTag {
    const attrs = parseImgTagAt(raw, start) orelse return null;
    const src = attrs.src orelse return null;
    if (!isLocalUrl(std.mem.trim(u8, src, " \t\r\n"))) return null;

    var buf: std.ArrayList(u8) = .empty;
    appendSafeImg(&buf, a, attrs) catch return null;
    return .{ .html = buf.items, .end = attrs.end };
}

/// safeVideoAt parses a `<video …></video>` pair beginning at raw[start] and, if
/// its src is same-origin, returns a rebuilt locked player (controls, metadata
/// preload) plus the index past `</video>`. The closing tag must follow the open
/// tag with only whitespace between — no fallback content is carried through.
fn safeVideoAt(a: std.mem.Allocator, raw: []const u8, start: usize) ?SafeTag {
    const attrs = parseVideoTagAt(raw, start) orelse return null;
    const src = attrs.src orelse return null;
    if (!isLocalUrl(std.mem.trim(u8, src, " \t\r\n"))) return null;

    var p = attrs.end;
    while (p < raw.len and isSpace(raw[p])) : (p += 1) {}
    const close = matchCloseTag(raw, p, "video") orelse return null;

    var buf: std.ArrayList(u8) = .empty;
    appendSafeVideo(&buf, a, attrs) catch return null;
    return .{ .html = buf.items, .end = close };
}

/// matchCloseTag matches `</name>` at raw[pos] (optional whitespace before '>'),
/// returning the index past '>' or null.
fn matchCloseTag(raw: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos + 2 + name.len > raw.len or raw[pos] != '<' or raw[pos + 1] != '/') return null;
    if (!eqlCI(raw[pos + 2 .. pos + 2 + name.len], name)) return null;
    var i = pos + 2 + name.len;
    while (i < raw.len and isSpace(raw[i])) : (i += 1) {}
    if (i >= raw.len or raw[i] != '>') return null;
    return i + 1;
}

fn appendSafeImg(buf: *std.ArrayList(u8), a: std.mem.Allocator, attrs: ImgAttrs) !void {
    try buf.appendSlice(a, "<img");
    try appendAttr(buf, a, "src", attrs.src.?);
    if (attrs.alt) |v| try appendAttr(buf, a, "alt", v);
    if (attrs.title) |v| try appendAttr(buf, a, "title", v);
    if (attrs.width) |v| {
        if (allDigits(v)) try appendAttr(buf, a, "width", v);
    }
    if (attrs.height) |v| {
        if (allDigits(v)) try appendAttr(buf, a, "height", v);
    }
    try buf.append(a, '>');
}

const VideoAttrs = struct {
    src: ?[]const u8 = null,
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    end: usize = 0, // index just past the opening tag's '>'
};

/// parseVideoTagAt parses one <video> open tag at raw[start], capturing the
/// allowlisted attributes (src/width/height; last value wins) and the index past
/// '>'. Mirrors parseImgTagAt over the shared TagScan.
fn parseVideoTagAt(raw: []const u8, start: usize) ?VideoAttrs {
    const after_name = tagNameAt(raw, start, "video") orelse return null;
    var attrs = VideoAttrs{};
    var s = TagScan{ .raw = raw, .i = after_name };
    while (s.next()) |kv| setVideoAttr(&attrs, kv.name, kv.value);
    if (s.bad) return null;
    attrs.end = s.end;
    return attrs;
}

fn setVideoAttr(attrs: *VideoAttrs, name: []const u8, value: []const u8) void {
    if (eqlCI(name, "src")) {
        attrs.src = value;
    } else if (eqlCI(name, "width")) {
        attrs.width = value;
    } else if (eqlCI(name, "height")) {
        attrs.height = value;
    }
}

/// appendSafeVideo emits the locked player: controls + metadata preload (so the
/// browser fetches only the head until play), the same-origin src, and digit
/// width/height. No autoplay, no event handlers — only the allowlist survives.
fn appendSafeVideo(buf: *std.ArrayList(u8), a: std.mem.Allocator, attrs: VideoAttrs) !void {
    try buf.appendSlice(a, "<video controls preload=\"metadata\"");
    try appendAttr(buf, a, "src", attrs.src.?);
    if (attrs.width) |v| {
        if (allDigits(v)) try appendAttr(buf, a, "width", v);
    }
    if (attrs.height) |v| {
        if (allDigits(v)) try appendAttr(buf, a, "height", v);
    }
    try buf.appendSlice(a, "></video>");
}

fn appendAttr(buf: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, val: []const u8) !void {
    try buf.append(a, ' ');
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, "=\"");
    try escapeInto(buf, a, val);
    try buf.append(a, '"');
}

/// TagScan walks the attributes of one HTML start-tag, beginning just past the
/// tag name. `next()` yields each `name=value` (quotes respected, value "" for a
/// bare attribute); it returns null at the tag's '>' (setting `end` past it) OR
/// on malformed input (setting `bad`). Shared by the <img> and <video> parsers
/// so the fiddly quoting rules live in one place.
const TagScan = struct {
    raw: []const u8,
    i: usize,
    end: usize = 0, // index past '>' once a clean close is reached
    bad: bool = false,

    const Attr = struct { name: []const u8, value: []const u8 };

    fn next(s: *TagScan) ?Attr {
        while (s.i < s.raw.len) {
            const c = s.raw[s.i];
            if (isSpace(c) or c == '/') {
                s.i += 1;
                continue;
            }
            if (c == '>') {
                s.end = s.i + 1;
                return null;
            }
            const name_start = s.i;
            while (s.i < s.raw.len and isAttrNameChar(s.raw[s.i])) : (s.i += 1) {}
            if (s.i == name_start) {
                s.bad = true;
                return null;
            }
            const name = s.raw[name_start..s.i];
            while (s.i < s.raw.len and isSpace(s.raw[s.i])) : (s.i += 1) {}

            var value: []const u8 = "";
            if (s.i < s.raw.len and s.raw[s.i] == '=') {
                s.i += 1;
                while (s.i < s.raw.len and isSpace(s.raw[s.i])) : (s.i += 1) {}
                if (s.i >= s.raw.len) {
                    s.bad = true;
                    return null;
                }
                const q = s.raw[s.i];
                if (q == '"' or q == '\'') {
                    s.i += 1;
                    const vs = s.i;
                    while (s.i < s.raw.len and s.raw[s.i] != q) : (s.i += 1) {}
                    if (s.i >= s.raw.len) {
                        s.bad = true;
                        return null;
                    }
                    value = s.raw[vs..s.i];
                    s.i += 1;
                } else {
                    const vs = s.i;
                    while (s.i < s.raw.len and !isSpace(s.raw[s.i]) and s.raw[s.i] != '>') : (s.i += 1) {}
                    value = s.raw[vs..s.i];
                }
            }
            return .{ .name = name, .value = value };
        }
        s.bad = true; // ran off the end without a '>'
        return null;
    }
};

/// tagNameAt reports whether raw[start] opens `<name` followed by a separator
/// (space, '>', or '/'), and returns the index just past the name.
fn tagNameAt(raw: []const u8, start: usize, name: []const u8) ?usize {
    const after = start + 1 + name.len;
    if (after >= raw.len or raw[start] != '<' or !eqlCI(raw[start + 1 .. after], name)) return null;
    const d = raw[after];
    if (!isSpace(d) and d != '>' and d != '/') return null;
    return after;
}

/// parseImgTagAt parses one <img> tag at raw[start], capturing the allowlisted
/// attributes (last value wins) and the index past '>'. Quotes are respected.
fn parseImgTagAt(raw: []const u8, start: usize) ?ImgAttrs {
    const after_name = tagNameAt(raw, start, "img") orelse return null;
    var attrs = ImgAttrs{};
    var s = TagScan{ .raw = raw, .i = after_name };
    while (s.next()) |kv| setImgAttr(&attrs, kv.name, kv.value);
    if (s.bad) return null;
    attrs.end = s.end;
    return attrs;
}

fn setImgAttr(attrs: *ImgAttrs, name: []const u8, value: []const u8) void {
    if (eqlCI(name, "src")) {
        attrs.src = value;
    } else if (eqlCI(name, "alt")) {
        attrs.alt = value;
    } else if (eqlCI(name, "title")) {
        attrs.title = value;
    } else if (eqlCI(name, "width")) {
        attrs.width = value;
    } else if (eqlCI(name, "height")) {
        attrs.height = value;
    }
}

/// isLocalUrl accepts only same-origin, root-relative URLs ("/…", but not
/// "//…" or "/\…"). The same-origin gate for both <img src> and <video src>.
fn isLocalUrl(src: []const u8) bool {
    return src.len >= 2 and src[0] == '/' and src[1] != '/' and src[1] != '\\';
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

fn escapeInto(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, ch),
        }
    }
}

// --- inline rendering (text + img + links + autolinks) ----------------------

// An inline node. The renderInline pipeline is: tokenize text into nodes
// (literal text, pre-rendered html for code/img/link/autolink, and `*`/`_`
// delimiter runs) → resolve emphasis by the CommonMark delimiter-stack
// algorithm (inserting open/close marker nodes) → emit. Nodes live in one
// arraylist; the inline order is a doubly-linked list over `prev`/`next`, and
// the delimiter stack is a second linked list over `dprev`/`dnext`.
const IKind = enum { text, html, delim, open, close };

const Node = struct {
    kind: IKind,
    s: []const u8 = "", // text: raw (escape on emit); html: pre-rendered (emit as-is)
    ch: u8 = 0, // delim char
    count: usize = 0, // delim: remaining (unconsumed) delimiters
    orig: usize = 0, // delim: original run length (for the rule of 3)
    can_open: bool = false,
    can_close: bool = false,
    use: usize = 0, // open/close marker: 1 = <em>, 2 = <strong>
    prev: ?u32 = null,
    next: ?u32 = null,
    dprev: ?u32 = null, // delimiter-stack links (delim nodes only)
    dnext: ?u32 = null,
};

const Inline = struct {
    nodes: std.ArrayList(Node) = .empty,
    head: ?u32 = null,
    tail: ?u32 = null,
    dhead: ?u32 = null,
    dtail: ?u32 = null,

    fn append(self: *Inline, a: std.mem.Allocator, n: Node) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        var node = n;
        node.prev = self.tail;
        node.next = null;
        try self.nodes.append(a, node);
        if (self.tail) |t| self.nodes.items[t].next = idx;
        self.tail = idx;
        if (self.head == null) self.head = idx;
        return idx;
    }

    fn appendDelim(self: *Inline, a: std.mem.Allocator, n: Node) !void {
        const idx = try self.append(a, n);
        self.nodes.items[idx].dprev = self.dtail;
        if (self.dtail) |t| self.nodes.items[t].dnext = idx;
        self.dtail = idx;
        if (self.dhead == null) self.dhead = idx;
    }

    // insertAfter splices a fresh node into the inline list just after `at`.
    fn insertAfter(self: *Inline, a: std.mem.Allocator, at: u32, n: Node) !void {
        const idx: u32 = @intCast(self.nodes.items.len);
        var node = n;
        node.prev = at;
        node.next = self.nodes.items[at].next;
        try self.nodes.append(a, node);
        if (self.nodes.items[idx].next) |nx| self.nodes.items[nx].prev = idx else self.tail = idx;
        self.nodes.items[at].next = idx;
    }

    // insertBefore splices a fresh node into the inline list just before `at`.
    fn insertBefore(self: *Inline, a: std.mem.Allocator, at: u32, n: Node) !void {
        const idx: u32 = @intCast(self.nodes.items.len);
        var node = n;
        node.next = at;
        node.prev = self.nodes.items[at].prev;
        try self.nodes.append(a, node);
        if (self.nodes.items[idx].prev) |pv| self.nodes.items[pv].next = idx else self.head = idx;
        self.nodes.items[at].prev = idx;
    }

    // unlinkDelim removes a node from the delimiter stack (its inline-list place
    // and text are untouched — leftover delimiter chars still emit).
    fn unlinkDelim(self: *Inline, idx: u32) void {
        const dp = self.nodes.items[idx].dprev;
        const dn = self.nodes.items[idx].dnext;
        if (dp) |p| self.nodes.items[p].dnext = dn else self.dhead = dn;
        if (dn) |n| self.nodes.items[n].dprev = dp else self.dtail = dp;
    }
};

/// renderInline renders one line of inline content: escapes plain text and
/// recognizes inline <img>, code spans, markdown links [t](u), GFM bare-URL/
/// email autolinks, and `*`/`_`/`**` emphasis. target="_blank" on external
/// links is added by the linkifyMsgRefs post-pass (mirroring Go).
fn renderInline(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    var inl = Inline{};

    var run_start: usize = 0;
    var i: usize = 0;
    // Monotonic scan cursors: the first ']' / ')' at or after a position, and a
    // floor below which no email autolink can start, all only ever move forward.
    // They keep mdLinkAt / autolinkAt from re-scanning the same suffix from every
    // '[' or post-`_` boundary — the difference between O(n²) and O(n) on hostile
    // input like "[[[[…", "[]([]([](…", or "a_b_a_b…" (Steve, 2026-06-19).
    var rb: usize = std.mem.indexOfScalarPos(u8, text, 0, ']') orelse text.len;
    var rp: usize = std.mem.indexOfScalarPos(u8, text, 0, ')') orelse text.len;
    var email_dead: usize = 0;
    while (i < text.len) {
        const c = text[i];
        var consumed = false;
        if (c == '<') {
            if (safeImgAt(a, text, i) orelse safeVideoAt(a, text, i)) |tag| {
                try flushText(&inl, a, text[run_start..i]);
                _ = try inl.append(a, .{ .kind = .html, .s = tag.html });
                i = tag.end;
                consumed = true;
            }
        } else if (c == '`') {
            if (codeSpanAt(text, i)) |cs| {
                try flushText(&inl, a, text[run_start..i]);
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(a, "<code>");
                try escapeInto(&buf, a, codeSpanContent(text[cs.content_start..cs.content_end]));
                try buf.appendSlice(a, "</code>");
                _ = try inl.append(a, .{ .kind = .html, .s = buf.items });
                i = cs.end;
                consumed = true;
            } else {
                // No equal-length closing run: the whole opening run is
                // literal. Skip past it so we don't re-enter at an interior
                // backtick and let a shorter sub-run open a spurious span —
                // CommonMark treats a backtick run as an atomic unit. The run
                // stays pending as text (backticks aren't HTML-special). This
                // is what keeps an inline ``` (e.g. discussing fences) from
                // mangling the rest of the paragraph.
                var n: usize = 0;
                while (i + n < text.len and text[i + n] == '`') : (n += 1) {}
                i += n;
                continue;
            }
        } else if (c == '[') {
            if (try mdLinkAt(a, text, i, &rb, &rp)) |lk| {
                try flushText(&inl, a, text[run_start..i]);
                _ = try inl.append(a, .{ .kind = .html, .s = lk.html });
                i = lk.end;
                consumed = true;
            }
        } else if (c == '*' or c == '_') {
            try flushText(&inl, a, text[run_start..i]);
            var n: usize = 0;
            while (i + n < text.len and text[i + n] == c) : (n += 1) {}
            const fl = flanking(text, i, i + n);
            const can_open = if (c == '*') fl.left else fl.left and (!fl.right or fl.before_punct);
            const can_close = if (c == '*') fl.right else fl.right and (!fl.left or fl.after_punct);
            try inl.appendDelim(a, .{
                .kind = .delim,
                .s = text[i .. i + n],
                .ch = c,
                .count = n,
                .orig = n,
                .can_open = can_open,
                .can_close = can_close,
            });
            i += n;
            consumed = true;
        } else if (autolinkBoundary(text, i)) {
            if (autolinkAt(text, i, &email_dead)) |al| {
                try flushText(&inl, a, text[run_start..i]);
                var buf: std.ArrayList(u8) = .empty;
                try emitAutolink(&buf, a, text[i..al.end], al.kind);
                _ = try inl.append(a, .{ .kind = .html, .s = buf.items });
                i = al.end;
                consumed = true;
            }
        }
        if (consumed) {
            run_start = i;
        } else {
            i += 1;
        }
    }
    try flushText(&inl, a, text[run_start..]);

    processEmphasis(&inl, a);
    try emitInline(out, a, &inl);
}

fn flushText(inl: *Inline, a: std.mem.Allocator, s: []const u8) !void {
    if (s.len == 0) return;
    _ = try inl.append(a, .{ .kind = .text, .s = s });
}

fn emitInline(out: *std.ArrayList(u8), a: std.mem.Allocator, inl: *Inline) !void {
    var cur = inl.head;
    while (cur) |idx| {
        const n = inl.nodes.items[idx];
        switch (n.kind) {
            .text => try escapeInto(out, a, n.s),
            .html => try out.appendSlice(a, n.s),
            .delim => {
                var k: usize = 0;
                while (k < n.count) : (k += 1) try out.append(a, n.ch);
            },
            .open => try out.appendSlice(a, if (n.use == 2) "<strong>" else "<em>"),
            .close => try out.appendSlice(a, if (n.use == 2) "</strong>" else "</em>"),
        }
        cur = n.next;
    }
}

const Flank = struct { left: bool, right: bool, before_punct: bool, after_punct: bool };

/// flanking computes the CommonMark left/right-flanking flags for the delimiter
/// run text[s..e]. Run start/end of the line counts as whitespace.
fn flanking(text: []const u8, s: usize, e: usize) Flank {
    const before: u8 = if (s == 0) ' ' else text[s - 1];
    const after: u8 = if (e >= text.len) ' ' else text[e];
    const before_ws = isSpace(before);
    const after_ws = isSpace(after);
    const before_punct = isPunct(before);
    const after_punct = isPunct(after);
    const left = !after_ws and (!after_punct or before_ws or before_punct);
    const right = !before_ws and (!before_punct or after_ws or after_punct);
    return .{ .left = left, .right = right, .before_punct = before_punct, .after_punct = after_punct };
}

/// processEmphasis resolves `*`/`_` delimiter runs into <em>/<strong> by the
/// CommonMark delimiter-stack algorithm (including the "rule of 3"), inserting
/// open/close marker nodes around the matched spans.
fn processEmphasis(inl: *Inline, a: std.mem.Allocator) void {
    // openers_bottom[len % 3][char], char: '*' = 0, '_' = 1. null = stack bottom.
    var openers_bottom = [_][2]?u32{.{ null, null }} ** 3;

    var closer = inl.dhead;
    while (closer) |ci| {
        if (!inl.nodes.items[ci].can_close) {
            closer = inl.nodes.items[ci].dnext;
            continue;
        }
        const cch = inl.nodes.items[ci].ch;
        const ob_index: usize = if (cch == '*') 0 else 1;
        const bottom = openers_bottom[inl.nodes.items[ci].count % 3][ob_index];

        // Look back for a matching opener.
        var opener = inl.nodes.items[ci].dprev;
        var opener_found = false;
        while (opener) |oi| {
            if (oi == bottom) break;
            const on = inl.nodes.items[oi];
            if (on.can_open and on.ch == cch) {
                const cn = inl.nodes.items[ci];
                const odd = (cn.can_open or on.can_close) and
                    (cn.orig % 3 != 0) and ((on.orig + cn.orig) % 3 == 0);
                if (!odd) {
                    opener_found = true;
                    break;
                }
            }
            opener = on.dprev;
        }

        const old_closer = ci;
        if (opener_found) {
            const oi = opener.?;
            const use: usize = if (inl.nodes.items[oi].count >= 2 and inl.nodes.items[ci].count >= 2) 2 else 1;

            // Wrap the span: open marker after the opener, close marker before
            // the closer. Insertion is append-based, so capture neighbors first.
            inl.insertAfter(a, oi, .{ .kind = .open, .use = use }) catch return;
            inl.insertBefore(a, ci, .{ .kind = .close, .use = use }) catch return;

            inl.nodes.items[oi].count -= use;
            inl.nodes.items[ci].count -= use;

            // Drop every delimiter strictly between opener and closer.
            inl.nodes.items[oi].dnext = ci;
            inl.nodes.items[ci].dprev = oi;

            if (inl.nodes.items[oi].count == 0) inl.unlinkDelim(oi);
            if (inl.nodes.items[ci].count == 0) {
                const nxt = inl.nodes.items[ci].dnext;
                inl.unlinkDelim(ci);
                closer = nxt;
            }
            // closer with leftover delimiters stays; the loop re-examines it.
        } else {
            closer = inl.nodes.items[ci].dnext;
            openers_bottom[inl.nodes.items[old_closer].count % 3][ob_index] = inl.nodes.items[old_closer].dprev;
            if (!inl.nodes.items[old_closer].can_open) inl.unlinkDelim(old_closer);
        }
    }
}

/// autolinkBoundary: a GFM autolink may start only at the beginning of the
/// run or after whitespace or one of * _ ~ (.
fn autolinkBoundary(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    const p = text[i - 1];
    return isSpace(p) or p == '*' or p == '_' or p == '~' or p == '(';
}

const AutoKind = enum { url, www, email };
const Autolink = struct { end: usize, kind: AutoKind };

/// autolinkAt detects a GFM autolink starting at text[i] and returns the index
/// just past it (after trailing-punctuation trimming), or null.
/// `email_dead` is renderInline's monotonic floor: no email autolink can start
/// at any index below it. Without it, an email-local char that's also an
/// autolink boundary ('_') makes emailEnd re-scan the whole email-local run from
/// every '_' — O(n²) on "a_b_a_b…". When emailEnd fails, the entire local run is
/// equally dead (every position in it scans to the same run end with the same
/// outcome), so we advance the floor past it: O(n) total.
fn autolinkAt(text: []const u8, i: usize, email_dead: *usize) ?Autolink {
    if (startsWithCI(text[i..], "http://") or startsWithCI(text[i..], "https://")) {
        const end = urlEnd(text, i) orelse return null;
        return .{ .end = end, .kind = .url };
    }
    if (startsWithCI(text[i..], "www.")) {
        const end = urlEnd(text, i) orelse return null;
        return .{ .end = end, .kind = .www };
    }
    if (i >= email_dead.*) {
        if (emailEnd(text, i)) |end| return .{ .end = end, .kind = .email };
        var j = i;
        while (j < text.len and isEmailLocalChar(text[j])) : (j += 1) {}
        email_dead.* = if (j > i) j else i + 1;
    }
    return null;
}

/// urlEnd consumes URL characters from start (up to whitespace or '<') then
/// trims GFM trailing punctuation and unbalanced ')'.
fn urlEnd(text: []const u8, start: usize) ?usize {
    var end = start;
    while (end < text.len and !isSpace(text[end]) and text[end] != '<') : (end += 1) {}
    // The DOMAIN (host, after the scheme and before any port/path/query) must
    // contain a '.', per GFM. A '.' in the path doesn't count — so
    // http://localhost:9100/x.md is not an autolink, but http://a.com/x is.
    var dstart = start;
    if (std.mem.indexOf(u8, text[start..end], "://")) |p| dstart = start + p + 3;
    var dend = dstart;
    while (dend < end and text[dend] != '/' and text[dend] != '?' and
        text[dend] != '#' and text[dend] != ':') : (dend += 1)
    {}
    if (std.mem.indexOfScalar(u8, text[dstart..dend], '.') == null) return null;
    while (end > start) {
        const c = text[end - 1];
        switch (c) {
            '?', '!', '.', ',', ':', '*', '_', '~', '\'', '"' => end -= 1,
            ')' => {
                if (countByte(text[start..end], ')') > countByte(text[start..end], '(')) {
                    end -= 1;
                } else break;
            },
            else => break,
        }
    }
    if (end <= start + 4) return null; // nothing meaningful left
    return end;
}

/// emailEnd matches a GFM email autolink (local@domain.tld) at text[i].
fn emailEnd(text: []const u8, i: usize) ?usize {
    var j = i;
    while (j < text.len and isEmailLocalChar(text[j])) : (j += 1) {}
    if (j == i or j >= text.len or text[j] != '@') return null;
    j += 1;
    const domain_start = j;
    while (j < text.len and (isAsciiAlnum(text[j]) or text[j] == '.' or text[j] == '-' or text[j] == '_')) : (j += 1) {}
    const domain = text[domain_start..j];
    if (domain.len == 0 or std.mem.indexOfScalar(u8, domain, '.') == null) return null;
    // A trailing '.' or '-' or '_' is not part of the email.
    while (j > domain_start and (text[j - 1] == '.' or text[j - 1] == '-' or text[j - 1] == '_')) : (j -= 1) {}
    return j;
}

fn emitAutolink(out: *std.ArrayList(u8), a: std.mem.Allocator, link: []const u8, kind: AutoKind) !void {
    try out.appendSlice(a, "<a href=\"");
    switch (kind) {
        .url => try escapeInto(out, a, link),
        .www => {
            try out.appendSlice(a, "http://");
            try escapeInto(out, a, link);
        },
        .email => {
            try out.appendSlice(a, "mailto:");
            try escapeInto(out, a, link);
        },
    }
    try out.appendSlice(a, "\">");
    try escapeInto(out, a, link);
    try out.appendSlice(a, "</a>");
}

const CodeSpan = struct { content_start: usize, content_end: usize, end: usize };

/// codeSpanAt matches a backtick code span at text[i]: an opening run of N
/// backticks closed by a run of exactly N backticks. Returns null (literal
/// backticks) if there's no matching close.
fn codeSpanAt(text: []const u8, i: usize) ?CodeSpan {
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == '`') : (n += 1) {}
    const content_start = i + n;
    var k = content_start;
    while (k < text.len) {
        if (text[k] != '`') {
            k += 1;
            continue;
        }
        var m: usize = 0;
        while (k + m < text.len and text[k + m] == '`') : (m += 1) {}
        if (m == n) return .{ .content_start = content_start, .content_end = k, .end = k + m };
        k += m; // a run of the wrong length is part of the content
    }
    return null;
}

/// codeSpanContent applies CommonMark's trimming: if the content both begins
/// and ends with a space and isn't all spaces, one space is stripped each end.
fn codeSpanContent(content: []const u8) []const u8 {
    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and
        std.mem.indexOfNone(u8, content, " ") != null)
    {
        return content[1 .. content.len - 1];
    }
    return content;
}

const MdLink = struct { html: []const u8, end: usize };

/// mdLinkAt parses a markdown link [text](url) at text[i] (text[i] == '['),
/// or null if it's not a well-formed link. `rb` / `rp` are renderInline's
/// monotonic ']' / ')' cursors: each only ever advances, so the forward scans
/// here cost O(n) total across all '[' rather than O(n²) on "[[[[…" / "[](…".
/// `rb` lands on the first ']' at >= i+1 and `rp` on the first ')' at >= open_p+1
/// — exactly what indexOfScalarPos found before, just never re-scanned.
fn mdLinkAt(a: std.mem.Allocator, text: []const u8, i: usize, rb: *usize, rp: *usize) std.mem.Allocator.Error!?MdLink {
    while (rb.* < text.len and rb.* < i + 1) {
        rb.* = std.mem.indexOfScalarPos(u8, text, rb.* + 1, ']') orelse text.len;
    }
    if (rb.* >= text.len) return null;
    const close_br = rb.*;
    if (close_br + 1 >= text.len or text[close_br + 1] != '(') return null;
    const open_p = close_br + 1;
    while (rp.* < text.len and rp.* < open_p + 1) {
        rp.* = std.mem.indexOfScalarPos(u8, text, rp.* + 1, ')') orelse text.len;
    }
    if (rp.* >= text.len) return null;
    const close_p = rp.*;

    const label = text[i + 1 .. close_br];
    const url = text[open_p + 1 .. close_p];

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "<a href=\"");
    if (!isDangerousUrl(url)) try escapeInto(&buf, a, url);
    try buf.appendSlice(a, "\">");
    try renderInline(&buf, a, label);
    try buf.appendSlice(a, "</a>");
    return .{ .html = buf.items, .end = close_p + 1 };
}

/// isDangerousUrl blocks the dangerous URL schemes javascript:, vbscript:,
/// file:, and data: except for image data URIs.
fn isDangerousUrl(url: []const u8) bool {
    if (startsWithCI(url, "data:image/")) {
        const v = url[11..];
        if (startsWithCI(v, "png") or startsWithCI(v, "gif") or startsWithCI(v, "jpeg") or
            startsWithCI(v, "webp") or startsWithCI(v, "svg")) return false;
        return true;
    }
    return startsWithCI(url, "javascript:") or startsWithCI(url, "vbscript:") or
        startsWithCI(url, "file:") or startsWithCI(url, "data:");
}

fn isEmailLocalChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '.' or c == '_' or c == '+' or c == '-';
}

fn countByte(s: []const u8, b: u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == b) n += 1;
    }
    return n;
}

// --- MSG_ reference linkifier (post-pass over rendered HTML) -----------------

/// linkifyMsgRefs rewrites MSG_<slug>_<n> tokens in HTML text into reference
/// links, skipping the contents of <code>, <pre>, and <a> elements — the same
/// single tokenizing walk (tags vs. text) as the Go linkifyMsgRefs.
fn linkifyMsgRefs(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var skip: usize = 0;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse {
                try out.appendSlice(a, html[i..]);
                break;
            };
            var tag = html[i .. end + 1];
            if (startsWithCI(tag, "<a ")) tag = try openExternalInNewTab(a, tag);
            try out.appendSlice(a, tag);
            if (tagOpensSkip(tag)) {
                skip += 1;
            } else if (tagClosesSkip(tag) and skip > 0) {
                skip -= 1;
            }
            i = end + 1;
            continue;
        }
        const next = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
        const text = html[i..next];
        if (skip == 0) {
            try linkifyText(&out, a, text);
        } else {
            try out.appendSlice(a, text);
        }
        i = next;
    }
    return out.toOwnedSlice(a);
}

/// openExternalInNewTab adds target="_blank" rel="noopener" to an <a> whose
/// href is fully qualified (scheme://).
fn openExternalInNewTab(a: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const href = attrValue(tag, "href") orelse return tag;
    if (!isExternalHref(href)) return tag;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, tag[0 .. tag.len - 1]); // drop trailing '>'
    try buf.appendSlice(a, " target=\"_blank\" rel=\"noopener\">");
    return buf.items;
}

fn attrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var pat: [16]u8 = undefined;
    if (attr.len + 2 > pat.len) return null;
    @memcpy(pat[0..attr.len], attr);
    pat[attr.len] = '=';
    pat[attr.len + 1] = '"';
    const k = std.mem.indexOf(u8, tag, pat[0 .. attr.len + 2]) orelse return null;
    const start = k + attr.len + 2;
    const q = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..q];
}

fn isExternalHref(href: []const u8) bool {
    const p = std.mem.indexOf(u8, href, "://") orelse return false;
    if (p == 0 or !isAsciiAlpha(href[0])) return false;
    for (href[1..p]) |c| {
        if (!isAsciiAlnum(c) and c != '+' and c != '.' and c != '-') return false;
    }
    return true;
}

fn tagOpensSkip(tag: []const u8) bool {
    return startsWithCI(tag, "<code") or startsWithCI(tag, "<pre") or startsWithCI(tag, "<a ");
}

fn tagClosesSkip(tag: []const u8) bool {
    return startsWithCI(tag, "</code") or startsWithCI(tag, "</pre") or startsWithCI(tag, "</a");
}

fn linkifyText(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (msgRefEnd(text, i)) |end| {
            const slug = text[i + 4 .. end]; // group: <slug>_<n>
            try out.appendSlice(a, "<a href=\"#msg-");
            try out.appendSlice(a, slug);
            try out.appendSlice(a, "\" class=\"msg-ref\">MSG_");
            try out.appendSlice(a, slug);
            try out.appendSlice(a, "</a>");
            i = end;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
}

/// msgRefEnd matches \bMSG_([A-Za-z0-9-]+_[0-9]+)\b at text[i], returning the
/// index just past the match, or null.
fn msgRefEnd(text: []const u8, i: usize) ?usize {
    if (i + 4 > text.len or !std.mem.eql(u8, text[i .. i + 4], "MSG_")) return null;
    if (i > 0 and isWordChar(text[i - 1])) return null; // \b before
    var j = i + 4;
    const slug_start = j;
    while (j < text.len and isSlugChar(text[j])) : (j += 1) {}
    if (j == slug_start) return null;
    if (j >= text.len or text[j] != '_') return null;
    j += 1;
    const dig_start = j;
    while (j < text.len and isDigit(text[j])) : (j += 1) {}
    if (j == dig_start) return null;
    if (j < text.len and isWordChar(text[j])) return null; // \b after
    return j;
}

// --- small char/string helpers ----------------------------------------------

fn isWordChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '_';
}

fn isSlugChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-';
}

fn isAttrNameChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-' or c == '_' or c == ':';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isAsciiAlnum(c: u8) bool {
    return isAsciiAlpha(c) or isDigit(c);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

/// isPunct reports whether c is an ASCII punctuation char (CommonMark's
/// definition), used by the emphasis flanking rules.
fn isPunct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

fn eqlCI(s: []const u8, lower_lit: []const u8) bool {
    if (s.len != lower_lit.len) return false;
    for (s, lower_lit) |c, l| {
        if (lower(c) != l) return false;
    }
    return true;
}

fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (prefix, 0..) |p, n| {
        if (lower(haystack[n]) != lower(p)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

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
