//! markdown_links: the MSG_-reference + external-link rules, applied INLINE by
//! the inline pass at emit time (it used to be a post-pass that re-tokenized the
//! finished HTML to re-discover code/link interiors — structure the inline pass
//! already knows, so it now decides where the structure is still in hand). Two
//! pure helpers over markdown_text:
//!   linkifyAndEscape — emit a plain-text run, MSG_<slug>_<n> → reference link,
//!                      everything else HTML-escaped.
//!   external_attrs   — the new-tab attributes for an external (scheme://) href.

const std = @import("std");
const mtext = @import("markdown_text.zig");

// Leaf text helpers (see markdown_text); aliased so the bodies read unqualified.
const isWordChar = mtext.isWordChar;
const isSlugChar = mtext.isSlugChar;
const isDigit = mtext.isDigit;
const isAsciiAlpha = mtext.isAsciiAlpha;
const isAsciiAlnum = mtext.isAsciiAlnum;

/// external_attrs opens a link in a new tab without leaking the opener. Appended
/// to an <a> whose href isExternalHref. One source of truth for both the
/// markdown-link and autolink emit sites.
pub const external_attrs = " target=\"_blank\" rel=\"noopener\"";

/// appendMsgRef writes a `MSG_<slug>` reference link for `slug` (`<slug>_<n>`,
/// the group msgRefEnd captures). The slug grammar (`[A-Za-z0-9-]+_[0-9]+`) has
/// no HTML-special bytes, so it's emitted verbatim into both the href and the
/// visible text.
pub fn appendMsgRef(out: *std.ArrayList(u8), a: std.mem.Allocator, slug: []const u8) !void {
    try out.appendSlice(a, "<a href=\"#msg-");
    try out.appendSlice(a, slug);
    try out.appendSlice(a, "\" class=\"msg-ref\">MSG_");
    try out.appendSlice(a, slug);
    try out.appendSlice(a, "</a>");
}

/// msgRefEnd matches \bMSG_([A-Za-z0-9-]+_[0-9]+)\b at text[i], returning the
/// index just past the match, or null. The inline pass calls this DURING the
/// scan (not after) so a MSG_ ref becomes one atomic token before its `_`
/// characters could be mistaken for emphasis delimiters.
pub fn msgRefEnd(text: []const u8, i: usize) ?usize {
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

/// isExternalHref is true for a fully-qualified `scheme://…` href (the ones we
/// open in a new tab). Internal links (`#msg-…`, `/chat/…`) and `mailto:` are not.
pub fn isExternalHref(href: []const u8) bool {
    const p = std.mem.indexOf(u8, href, "://") orelse return false;
    if (p == 0 or !isAsciiAlpha(href[0])) return false;
    for (href[1..p]) |c| {
        if (!isAsciiAlnum(c) and c != '+' and c != '.' and c != '-') return false;
    }
    return true;
}
