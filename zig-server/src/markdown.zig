const std = @import("std");

/// render turns a raw chat message body into HTML, matching the Go
/// RenderChatMarkdown oracle (goldmark GFM + hard-wraps, then escape-but-img
/// and the MSG_ linkifier) byte-for-byte. Built up feature by feature against
/// the gold corpus. Currently: paragraphs (hard wraps + escaping), raw HTML
/// (escape everything but a same-origin <img>, block and inline), and the
/// MSG_ reference linkifier.
///
/// Caller owns the returned slice; pass an arena and reset it per message.
pub fn render(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    const body = try renderBlocks(a, md);
    return try linkifyMsgRefs(a, body);
}

// --- block rendering --------------------------------------------------------

fn renderBlocks(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

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
            pos = try renderFence(&out, a, md, fo);
            continue;
        }

        // An HTML block (CommonMark type 7) starts only at a block boundary —
        // it can't interrupt a paragraph — and runs until a blank line. We
        // emit its raw source through the escape-but-<img> scan, with no <p>
        // wrapper and no added newline (goldmark passes the source through).
        if (isHtmlBlockStart(line)) {
            var p = next;
            while (p < md.len) {
                const e2 = lineEnd(md, p);
                if (isBlank(md[p..e2])) break;
                p = if (e2 < md.len) e2 + 1 else md.len;
            }
            try writeRawHtml(&out, a, md[pos..p]);
            pos = p;
            continue;
        }

        // Otherwise a paragraph: a maximal run of non-blank lines, each
        // hard-wrapped with <br>, inline raw HTML handled the same way. A
        // fence opening on a later line interrupts the paragraph.
        try out.appendSlice(a, "<p>");
        var p = pos;
        var first = true;
        while (p < md.len) {
            const e2 = lineEnd(md, p);
            const l2 = md[p..e2];
            if (isBlank(l2)) break;
            if (parseFenceOpen(md, p) != null) break;
            if (!first) try out.appendSlice(a, "<br>\n");
            first = false;
            try renderInline(&out, a, trimLine(l2));
            p = if (e2 < md.len) e2 + 1 else md.len;
        }
        try out.appendSlice(a, "</p>\n");
        pos = p;
    }

    return out.toOwnedSlice(a);
}

// --- fenced code blocks (incl. the `quote` extension) -----------------------

const FenceOpen = struct {
    char: u8,
    count: usize,
    indent: usize,
    lang: []const u8,
    body_start: usize, // index of the first content line
};

/// parseFenceOpen recognizes a fence opening at md[pos] (line start): up to 3
/// leading spaces, then >=3 of '`' or '~'. The info string is the rest of the
/// line; the language is its first whitespace-delimited token.
fn parseFenceOpen(md: []const u8, pos: usize) ?FenceOpen {
    var i = pos;
    var indent: usize = 0;
    while (i < md.len and md[i] == ' ' and indent < 4) : (i += 1) {
        indent += 1;
    }
    if (indent >= 4 or i >= md.len) return null;
    const f = md[i];
    if (f != '`' and f != '~') return null;
    var count: usize = 0;
    while (i < md.len and md[i] == f) : (i += 1) {
        count += 1;
    }
    if (count < 3) return null;

    const eol = lineEnd(md, i);
    var info = md[i..eol];
    // A backtick info string may not contain a backtick.
    if (f == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    info = trimLine(info);
    var lang = info;
    if (std.mem.indexOfAny(u8, info, " \t")) |sp| lang = info[0..sp];

    return .{
        .char = f,
        .count = count,
        .indent = indent,
        .lang = lang,
        .body_start = if (eol < md.len) eol + 1 else md.len,
    };
}

fn isClosingFence(line: []const u8, f: u8, n: usize) bool {
    var i: usize = 0;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 4) : (i += 1) {
        indent += 1;
    }
    if (indent >= 4) return false;
    var count: usize = 0;
    while (i < line.len and line[i] == f) : (i += 1) {
        count += 1;
    }
    if (count < n) return false;
    return trimLine(line[i..]).len == 0;
}

/// renderFence emits the code block and returns the position after the closing
/// fence (or EOF when there is none — an unterminated fence runs to the end).
fn renderFence(out: *std.ArrayList(u8), a: std.mem.Allocator, md: []const u8, fo: FenceOpen) !usize {
    var content_end = md.len;
    var after = md.len;
    var p = fo.body_start;
    while (p < md.len) {
        const e = lineEnd(md, p);
        if (isClosingFence(md[p..e], fo.char, fo.count)) {
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
/// (goldmark normalizes the final line to end with '\n'), stripping up to the
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

/// writeRawHtml emits a chunk of raw HTML: each recognized same-origin <img>
/// is rebuilt from an attribute allowlist; everything else is HTML-escaped to
/// literal text. Mirrors the Go writeRawHTML — scanning (not all-or-nothing)
/// so an <img> followed by text on the next line keeps both.
fn writeRawHtml(out: *std.ArrayList(u8), a: std.mem.Allocator, raw: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '<') {
            i += 1;
            continue;
        }
        if (safeImgAt(a, raw, i)) |img| {
            try escapeInto(out, a, raw[last..i]);
            try out.appendSlice(a, img.html);
            i = img.end;
            last = img.end;
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

const SafeImg = struct { html: []const u8, end: usize };

/// safeImgAt parses a single <img …> beginning at raw[start] and, if its src
/// is same-origin, returns the rebuilt locked tag plus the index past '>'.
fn safeImgAt(a: std.mem.Allocator, raw: []const u8, start: usize) ?SafeImg {
    const attrs = parseImgTagAt(raw, start) orelse return null;
    const src = attrs.src orelse return null;
    if (!isLocalImgUrl(std.mem.trim(u8, src, " \t\r\n"))) return null;

    var buf: std.ArrayList(u8) = .empty;
    appendSafeImg(&buf, a, attrs) catch return null;
    return .{ .html = buf.items, .end = attrs.end };
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

fn appendAttr(buf: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, val: []const u8) !void {
    try buf.append(a, ' ');
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, "=\"");
    try escapeInto(buf, a, val);
    try buf.append(a, '"');
}

/// parseImgTagAt parses one <img> tag at raw[start], capturing the allowlisted
/// attributes (last value wins) and the index past '>'. Quotes are respected.
fn parseImgTagAt(raw: []const u8, start: usize) ?ImgAttrs {
    if (start + 4 >= raw.len or raw[start] != '<' or !eqlCI(raw[start + 1 .. start + 4], "img")) return null;
    const d = raw[start + 4];
    if (!isSpace(d) and d != '>' and d != '/') return null;

    var attrs = ImgAttrs{};
    var i = start + 4;
    while (i < raw.len) {
        const c = raw[i];
        if (isSpace(c) or c == '/') {
            i += 1;
            continue;
        }
        if (c == '>') {
            attrs.end = i + 1;
            return attrs;
        }
        const name_start = i;
        while (i < raw.len and isAttrNameChar(raw[i])) : (i += 1) {}
        if (i == name_start) return null;
        const name = raw[name_start..i];
        while (i < raw.len and isSpace(raw[i])) : (i += 1) {}

        var value: []const u8 = "";
        if (i < raw.len and raw[i] == '=') {
            i += 1;
            while (i < raw.len and isSpace(raw[i])) : (i += 1) {}
            if (i >= raw.len) return null;
            const q = raw[i];
            if (q == '"' or q == '\'') {
                i += 1;
                const vs = i;
                while (i < raw.len and raw[i] != q) : (i += 1) {}
                if (i >= raw.len) return null;
                value = raw[vs..i];
                i += 1;
            } else {
                const vs = i;
                while (i < raw.len and !isSpace(raw[i]) and raw[i] != '>') : (i += 1) {}
                value = raw[vs..i];
            }
        }
        setImgAttr(&attrs, name, value);
    }
    return null;
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

/// isLocalImgUrl accepts only same-origin, root-relative URLs ("/…", but not
/// "//…" or "/\…"), matching the Go renderer.
fn isLocalImgUrl(src: []const u8) bool {
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

/// renderInline renders one line of paragraph text: escapes plain text, and
/// recognizes inline <img>, markdown links [t](u), and GFM bare-URL/email
/// autolinks. Emphasis/inline-code come later. target="_blank" on external
/// links is added by the linkifyMsgRefs post-pass (mirroring Go).
fn renderInline(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '<') {
            if (safeImgAt(a, text, i)) |img| {
                try escapeInto(out, a, text[last..i]);
                try out.appendSlice(a, img.html);
                i = img.end;
                last = i;
                continue;
            }
        } else if (c == '[') {
            if (try mdLinkAt(a, text, i)) |lk| {
                try escapeInto(out, a, text[last..i]);
                try out.appendSlice(a, lk.html);
                i = lk.end;
                last = i;
                continue;
            }
        } else if (autolinkBoundary(text, i) and autolinkAt(text, i) != null) {
            const al = autolinkAt(text, i).?;
            try escapeInto(out, a, text[last..i]);
            try emitAutolink(out, a, text[i..al.end], al.kind);
            i = al.end;
            last = i;
            continue;
        }
        i += 1;
    }
    try escapeInto(out, a, text[last..]);
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
fn autolinkAt(text: []const u8, i: usize) ?Autolink {
    if (startsWithCI(text[i..], "http://") or startsWithCI(text[i..], "https://")) {
        const end = urlEnd(text, i) orelse return null;
        return .{ .end = end, .kind = .url };
    }
    if (startsWithCI(text[i..], "www.")) {
        const end = urlEnd(text, i) orelse return null;
        return .{ .end = end, .kind = .www };
    }
    if (emailEnd(text, i)) |end| return .{ .end = end, .kind = .email };
    return null;
}

/// urlEnd consumes URL characters from start (up to whitespace or '<') then
/// trims GFM trailing punctuation and unbalanced ')'.
fn urlEnd(text: []const u8, start: usize) ?usize {
    var end = start;
    while (end < text.len and !isSpace(text[end]) and text[end] != '<') : (end += 1) {}
    // The domain must contain a '.'.
    if (std.mem.indexOfScalar(u8, text[start..end], '.') == null) return null;
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

const MdLink = struct { html: []const u8, end: usize };

/// mdLinkAt parses a markdown link [text](url) at text[i] (text[i] == '['),
/// or null if it's not a well-formed link.
fn mdLinkAt(a: std.mem.Allocator, text: []const u8, i: usize) std.mem.Allocator.Error!?MdLink {
    const close_br = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse return null;
    if (close_br + 1 >= text.len or text[close_br + 1] != '(') return null;
    const open_p = close_br + 1;
    const close_p = std.mem.indexOfScalarPos(u8, text, open_p + 1, ')') orelse return null;

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

/// isDangerousUrl mirrors goldmark's IsDangerousURL: blocks javascript:,
/// vbscript:, file:, and data: except for image data URIs.
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
/// href is fully qualified (scheme://). Mirrors the Go post-pass.
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
/// index just past the match, or null. Mirrors msgRefRe.
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
