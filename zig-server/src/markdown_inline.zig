//! markdown_inline: the inline pass — one line of inline content → HTML.
//!
//! Tokenizes text into nodes (literal text; pre-rendered html for code spans /
//! img / links / autolinks; and `*`/`_` delimiter runs), resolves emphasis by
//! the CommonMark delimiter-stack algorithm, then emits. Also recognizes code
//! spans, markdown links `[t](u)`, and GFM bare-URL/email autolinks. Emphasis
//! (processEmphasis/flanking) lives HERE rather than in a sibling module because
//! it mutates the very node list this pass builds — separating them would only
//! share the Node/Inline types and create a cycle.
//!
//! A leaf: the block renderer calls renderInline, and renderInline calls the
//! media rebuilder for an inline <img>/<video>; it never calls back into block
//! rendering. MSG_ reference links and external-link target="_blank" are emitted
//! HERE, at the point each text run / link is produced (markdown_links holds the
//! rules) — no separate post-pass re-scans the finished HTML.

const std = @import("std");
const mtext = @import("markdown_text.zig");
const mmedia = @import("markdown_media.zig");
const mlinks = @import("markdown_links.zig");

// Leaf text helpers (see markdown_text); aliased so the bodies read unqualified.
const escapeInto = mtext.escapeInto;
const isAsciiAlnum = mtext.isAsciiAlnum;
const isSpace = mtext.isSpace;
const isPunct = mtext.isPunct;
const startsWithCI = mtext.startsWithCI;

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
/// email autolinks, and `*`/`_`/`**` emphasis. MSG_ reference links and external
/// `target="_blank"` are emitted inline as text runs / links are produced.
///
/// `linkify` gates MSG_ expansion of plain-text runs. It's true for ordinary
/// content and false when rendering a markdown-link LABEL — a label is already
/// inside an <a>, so expanding a MSG_ ref there would nest anchors. (The old
/// post-pass got this for free by skipping <a> interiors; here it's an explicit
/// argument, which is the honest version of that skip.) Emphasis and autolinks
/// still run in labels, exactly as before.
pub fn renderInline(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, linkify: bool) std.mem.Allocator.Error!void {
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
        // A MSG_ ref is recognized FIRST (when linkify), as one atomic token —
        // its `_` characters would otherwise be tokenized as emphasis delimiters
        // and split the ref apart. Disabled inside a link label (see `linkify`).
        const msg_end: ?usize = if (linkify and c == 'M') mlinks.msgRefEnd(text, i) else null;
        if (msg_end) |end| {
            try flushText(&inl, a, text[run_start..i]);
            var buf: std.ArrayList(u8) = .empty;
            try mlinks.appendMsgRef(&buf, a, text[i + 4 .. end]); // group: <slug>_<n>
            _ = try inl.append(a, .{ .kind = .html, .s = buf.items });
            i = end;
            consumed = true;
        } else if (c == '<') {
            if (mmedia.safeImgAt(a, text, i) orelse mmedia.safeVideoAt(a, text, i)) |tag| {
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
    try out.appendSlice(a, "\"");
    // url/www are scheme://… (external → new tab); mailto: is not.
    if (kind != .email) try out.appendSlice(a, mlinks.external_attrs);
    try out.appendSlice(a, ">");
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
    try buf.appendSlice(a, "\"");
    if (mlinks.isExternalHref(url)) try buf.appendSlice(a, mlinks.external_attrs);
    try buf.appendSlice(a, ">");
    try renderInline(&buf, a, label, false); // a label is inside this <a> — don't nest MSG_ links
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
