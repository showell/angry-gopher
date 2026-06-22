//! markdown_media: the locked, same-origin <img>/<video> rebuilder — the one
//! place the dialect lets real HTML tags through to the browser, so it gets the
//! extra care.
//!
//! TWO reasons this is its own tidy module:
//!
//!   1. SECURITY. A recognized <img>/<video> is never passed through; it is
//!      REBUILT from a fixed attribute allowlist (src/alt/title/width/height for
//!      img; src/width/height for video). Anything else — onerror=, onload=,
//!      style=, srcdoc=, a cross-origin or protocol-relative src — is dropped on
//!      the floor, and a tag that doesn't fully match falls back to plain
//!      HTML-escaping at the call site. The src must be root-relative same-origin
//!      (isLocalUrl), and video gains controls + preload="metadata" with no
//!      autoplay. So a hostile message can't smuggle script or off-site fetches
//!      through the one tag we render live.
//!
//!   2. GOPHER SEMANTICS. width/height are deliberately preserved (digit-only,
//!      via allDigits) because the browser needs intrinsic dimensions to reserve
//!      layout space — that's what lets the chat image/video transcript lazy-load
//!      and async-decode without the feed jumping as media streams in. Dropping
//!      the dims would reintroduce the scroll-jank the lazy-render code exists to
//!      avoid, so the allowlist keeps them on purpose.
//!
//! Entry points: safeImgAt / safeVideoAt — each parses ONE tag at a position and
//! returns the rebuilt SafeTag (html + index past the source it consumed) or
//! null. Called by markdown.writeRawHtml (block-level raw HTML) and
//! markdown_inline.renderInline (inline <img>). A pure leaf over markdown_text.

const std = @import("std");
const mtext = @import("markdown_text.zig");

// Leaf text helpers (see markdown_text); aliased so the bodies read unqualified.
const escapeInto = mtext.escapeInto;
const allDigits = mtext.allDigits;
const eqlCI = mtext.eqlCI;
const isSpace = mtext.isSpace;
const isAttrNameChar = mtext.isAttrNameChar;

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
pub const SafeTag = struct { html: []const u8, end: usize };

/// safeImgAt parses a single <img …> beginning at raw[start] and, if its src
/// is same-origin, returns the rebuilt locked tag plus the index past '>'.
pub fn safeImgAt(a: std.mem.Allocator, raw: []const u8, start: usize) ?SafeTag {
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
pub fn safeVideoAt(a: std.mem.Allocator, raw: []const u8, start: usize) ?SafeTag {
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

// ── tests ────────────────────────────────────────────────────────────────────
//
// safeImgAt/safeVideoAt are the security + lazy-render-dimensions boundary, so
// these pin both: the allowlist rebuild (event handlers dropped, dims kept iff
// digits) and the same-origin gate. They return null on anything they won't
// vouch for; the caller then plain-escapes the tag.

const testing = std.testing;

/// rebuilt runs safeImgAt at offset 0 and returns the rebuilt html (or "" if the
/// tag was rejected — the caller would HTML-escape it instead).
fn imgHtml(a: std.mem.Allocator, raw: []const u8) []const u8 {
    const tag = safeImgAt(a, raw, 0) orelse return "";
    return tag.html;
}
fn videoHtml(a: std.mem.Allocator, raw: []const u8) []const u8 {
    const tag = safeVideoAt(a, raw, 0) orelse return "";
    return tag.html;
}

test "safeImgAt rebuilds a same-origin img from the allowlist, dropping the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // src/alt/width survive; onerror= and style= are dropped (not in the allowlist)
    const html = imgHtml(a, "<img src=\"/u/cat.png\" alt=\"a cat\" width=\"200\" onerror=\"x()\" style=\"z\">");
    try testing.expectEqualStrings("<img src=\"/u/cat.png\" alt=\"a cat\" width=\"200\">", html);
    try testing.expect(std.mem.indexOf(u8, html, "onerror") == null);
    try testing.expect(std.mem.indexOf(u8, html, "style") == null);
}

test "safeImgAt keeps width/height only when all-digits (the lazy-render dims)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // digit dims are kept (the browser needs them to reserve layout space)…
    try testing.expectEqualStrings(
        "<img src=\"/u/x.png\" width=\"320\" height=\"240\">",
        imgHtml(a, "<img src=\"/u/x.png\" width=\"320\" height=\"240\">"),
    );
    // …but a non-digit dimension (e.g. "100%", "abc") is dropped, not echoed
    const pct = imgHtml(a, "<img src=\"/u/x.png\" width=\"100%\" height=\"auto\">");
    try testing.expectEqualStrings("<img src=\"/u/x.png\">", pct);
}

test "safeImgAt rejects cross-origin and protocol-relative src (same-origin gate)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("", imgHtml(a, "<img src=\"https://evil/x.png\">")); // absolute
    try testing.expectEqualStrings("", imgHtml(a, "<img src=\"//evil/x.png\">")); //       protocol-relative
    try testing.expectEqualStrings("", imgHtml(a, "<img src=\"/\\evil\">")); //            backslash trick
    try testing.expectEqualStrings("", imgHtml(a, "<img alt=\"no src\">")); //             missing src
}

test "safeVideoAt rebuilds a locked player; cross-origin/unclosed are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // controls + metadata preload injected; digit width kept; onerror dropped
    const ok = videoHtml(a, "<video src=\"/u/clip.mp4\" width=\"640\" onerror=\"x()\"></video>");
    try testing.expectEqualStrings("<video controls preload=\"metadata\" src=\"/u/clip.mp4\" width=\"640\"></video>", ok);
    // cross-origin and a tag with no closing </video> both reject
    try testing.expectEqualStrings("", videoHtml(a, "<video src=\"https://evil/x.mp4\"></video>"));
    try testing.expectEqualStrings("", videoHtml(a, "<video src=\"/u/x.mp4\">")); // unclosed
}
