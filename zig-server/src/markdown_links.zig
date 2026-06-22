//! markdown_links: the MSG_-reference linkifier — a post-pass over already-
//! rendered HTML. It rewrites `MSG_<slug>_<n>` tokens into reference links and
//! adds target="_blank" rel-noopener to external <a> hrefs, while skipping the
//! contents of <code>, <pre>, and existing <a> elements so it never rewrites a
//! token inside code or double-links an anchor.
//!
//! A leaf that runs LAST: render()/renderTrusted() call it on the block+inline
//! output. It operates purely on the HTML string and never re-enters the parser.

const std = @import("std");
const mtext = @import("markdown_text.zig");

// Leaf text helpers (see markdown_text); aliased so the bodies read unqualified.
const isWordChar = mtext.isWordChar;
const isSlugChar = mtext.isSlugChar;
const isDigit = mtext.isDigit;
const isAsciiAlpha = mtext.isAsciiAlpha;
const isAsciiAlnum = mtext.isAsciiAlnum;
const startsWithCI = mtext.startsWithCI;

// --- MSG_ reference linkifier (post-pass over rendered HTML) -----------------

/// linkifyMsgRefs rewrites MSG_<slug>_<n> tokens in HTML text into reference
/// links, skipping the contents of <code>, <pre>, and <a> elements — a
/// single tokenizing walk (tags vs. text).
pub fn linkifyMsgRefs(a: std.mem.Allocator, html: []const u8) ![]const u8 {
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
