//! names: the display-name POLICY — what a person may call themselves, and how
//! a raw string is cleaned into that. Pure: no Io, no store, no notion of an
//! account.
//!
//! It lives on its own because two identities now ask the same question. Chat's
//! members (users.zig, via login.zig) and the local players who just want to
//! play Lyn Rummy (player.zig) share one answer, and neither should have to
//! import the other to get it. When the chat surface moves to its own machine,
//! each side takes a copy of this file and nothing else follows.

const std = @import("std");
const Alloc = std.mem.Allocator;
const testing = std.testing;

pub const max_user_len = 40; // max display-name length

// UNICODE NOTE: classifying letters/digits by full Unicode tables would need data
// zig std doesn't expose, so the policy here is: ASCII letters/digits are
// letters/digits, the space and apostrophe are allowed, and ANY non-ASCII
// codepoint (byte >= 0x80) is treated as a letter. This is deliberately
// permissive — it accepts some exotic symbols a stricter check would reject — but
// it never locks out a legitimate name, and every real account name on the site
// is ASCII anyway. Length is byte-based.

pub const NameResult = struct { name: []const u8, err: []const u8 };

fn allowedNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ' ' or c == '\'' or c >= 0x80;
}

fn isNameAlnumByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// validateUserName cleans and checks a login-supplied name: trims, collapses
/// internal whitespace runs to one space, requires at least one letter/digit,
/// rejects any other punctuation. Returns {name, ""} on success or {"", message}
/// describing the fix.
pub fn validateUserName(alloc: Alloc, raw: []const u8) !NameResult {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .name = "", .err = "Please enter a name." };
    if (trimmed.len > max_user_len) return .{ .name = "", .err = "That name is too long (40 characters max)." };

    var b: std.ArrayList(u8) = .empty;
    var last_space = false;
    var has_alnum = false;
    for (trimmed) |c| {
        if (!allowedNameByte(c)) {
            return .{ .name = "", .err = "Names can use only letters, numbers, spaces, and apostrophes." };
        }
        if (c == ' ') {
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
            if (isNameAlnumByte(c)) has_alnum = true;
        }
        try b.append(alloc, c);
    }
    const out = std.mem.trimEnd(u8, b.items, " ");
    if (!has_alnum) return .{ .name = "", .err = "Please enter a name with at least one letter or number." };
    // "You"/"Me" are sentinels the UI uses for the viewer (e.g. Recent renders the
    // viewer's own author as "You"), so a real account can't hold them — case-
    // insensitively, since "YOU" reads as the sentinel too.
    if (std.ascii.eqlIgnoreCase(out, "you") or std.ascii.eqlIgnoreCase(out, "me")) {
        return .{ .name = "", .err = "“You” and “Me” are reserved — please pick another name." };
    }
    return .{ .name = out, .err = "" };
}

/// sanitizeUser scrubs a name into a clean attribute value: keeps allowed bytes,
/// collapses whitespace runs, caps length, "" if nothing usable remains. Lenient
/// (strips rather than rejects) — login re-checks with validateUserName.
pub fn sanitizeUser(alloc: Alloc, raw: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var last_space = false;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        if (c == ' ') {
            if (!last_space and b.items.len > 0) {
                try b.append(alloc, ' ');
                last_space = true;
            }
        } else if (allowedNameByte(c)) {
            try b.append(alloc, c);
            last_space = false;
        }
        if (b.items.len >= max_user_len) break;
    }
    return std.mem.trimEnd(u8, b.items, " ");
}

test "validateUserName collapses whitespace, requires alnum, rejects punctuation/overlength" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // happy: trims, collapses internal whitespace runs to one space
    try testing.expectEqualStrings("Steve Howell", (try validateUserName(a, "  Steve   Howell  ")).name);
    // apostrophe + space allowed; non-ASCII bytes treated as letters (permissive)
    try testing.expectEqualStrings("O'Brien", (try validateUserName(a, "O'Brien")).name);
    try testing.expectEqualStrings("José", (try validateUserName(a, "José")).name);

    // ── rejections: name is empty, err is set ──
    const cases = [_][]const u8{
        "   ", //                whitespace only
        "a<b", //                angle bracket (HTML-injection shaped)
        "x;y", //                semicolon
        "path/name", //          slash
        "'' ''", //              punctuation but no letter/digit
        "a" ** 41, //            41 bytes, over the 40 cap
    };
    for (cases) |raw| {
        const r = try validateUserName(a, raw);
        try testing.expectEqualStrings("", r.name);
        try testing.expect(r.err.len != 0);
    }

    // "You"/"Me" are UI sentinels — reserved case-insensitively (incl. after trim).
    const reserved = [_][]const u8{ "You", "you", "Me", "me", "YOU", "  Me  " };
    for (reserved) |raw| {
        const r = try validateUserName(a, raw);
        try testing.expectEqualStrings("", r.name);
        try testing.expect(r.err.len != 0);
    }
    // but names that merely CONTAIN them are fine
    try testing.expectEqualStrings("Mel", (try validateUserName(a, "Mel")).name);
    try testing.expectEqualStrings("You Two", (try validateUserName(a, "You Two")).name);
}

test "sanitizeUser strips disallowed bytes, collapses whitespace, caps length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // lenient: strips rather than rejects, and collapses the gap left behind
    try testing.expectEqualStrings("ab", try sanitizeUser(a, "a<b>"));
    try testing.expectEqualStrings("a b", try sanitizeUser(a, "  a < b  "));
    // nothing usable → empty
    try testing.expectEqualStrings("", try sanitizeUser(a, "<<>>"));
    // capped to max_user_len bytes
    try testing.expectEqual(@as(usize, max_user_len), (try sanitizeUser(a, "a" ** 80)).len);
}

