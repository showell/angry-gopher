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
// codepoint is treated as a letter, in a name that is valid UTF-8. This is
// deliberately permissive — it accepts some exotic symbols a stricter check
// would reject — but it never locks out a legitimate name, and every real
// account name on the site is ASCII anyway. Length is byte-based.

/// **A NAME, CHECKED** (metal-vmm QUEUE 250): what `validateUserName` made,
/// as a type only it makes, and `literal` for a name written in the source,
/// so a new account or player (users.allocateUser, player.allocate) is never
/// named by text no one checked: a newline in a name would split every
/// transcript line it signs. Zig has no private fields: a literal without
/// `name_seal` does not compile, and ops/check_zig's seal lint refuses
/// `.name_seal =` and `.user_name =` outside this file. `text()` reads it.
pub const UserName = struct {
    user_name: []const u8,
    name_seal: Seal,

    pub fn text(n: UserName) []const u8 {
        return n.user_name;
    }

    /// A name written in the source, checked as it compiles: already in the
    /// form `validateUserName` gives back.
    pub fn literal(comptime s: []const u8) UserName {
        comptime if (!canonical(s)) @compileError("not a name validateUserName gives: " ++ s);
        return .{ .user_name = s, .name_seal = .{} };
    }
};

const Seal = struct {};

/// A name, or the message that says how to fix it.
pub const NameResult = union(enum) { ok: UserName, refused: []const u8 };

/// Whether `s` is a name `validateUserName` gives back as it is.
fn canonical(s: []const u8) bool {
    if (s.len == 0 or s.len > max_user_len or !std.unicode.utf8ValidateSlice(s)) return false;
    if (s[0] == ' ' or s[s.len - 1] == ' ' or std.mem.indexOf(u8, s, "  ") != null) return false;
    var has_alnum = false;
    for (s) |c| {
        if (!isAllowedNameByte(c)) return false;
        if (isNameAlnumByte(c)) has_alnum = true;
    }
    return has_alnum and !std.ascii.eqlIgnoreCase(s, "you") and !std.ascii.eqlIgnoreCase(s, "me");
}

fn isAllowedNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ' ' or c == '\'' or c >= 0x80;
}

fn isNameAlnumByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// validateUserName cleans and checks a login-supplied name: trims, collapses
/// internal whitespace runs to one space, requires at least one letter/digit,
/// rejects any other punctuation. Returns the name, or the message that
/// describes the fix.
pub fn validateUserName(alloc: Alloc, raw: []const u8) !NameResult {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .refused = "Please enter a name." };
    if (trimmed.len > max_user_len) return .{ .refused = "That name is too long (40 characters max)." };
    // **A NAME IS TEXT**: its bytes are UTF-8. A name goes into every message
    // its owner writes (the transcript's `from:`, the reactions sidecar, the
    // stream's JSON), and JSON written from bytes that are not UTF-8 is an
    // array of numbers where a client reads a string. A browser always sends
    // UTF-8, so only a hand-made request is refused here.
    if (!std.unicode.utf8ValidateSlice(trimmed)) return .{ .refused = "That name is not readable text; please type it again." };

    var b: std.ArrayList(u8) = .empty;
    var last_space = false;
    var has_alnum = false;
    for (trimmed) |c| {
        if (!isAllowedNameByte(c)) {
            return .{ .refused = "Names can use only letters, numbers, spaces, and apostrophes." };
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
    if (!has_alnum) return .{ .refused = "Please enter a name with at least one letter or number." };
    // "You"/"Me" are sentinels the UI uses for the viewer (e.g. Recent renders the
    // viewer's own author as "You"), so a real account can't hold them — case-
    // insensitively, since "YOU" reads as the sentinel too.
    if (std.ascii.eqlIgnoreCase(out, "you") or std.ascii.eqlIgnoreCase(out, "me")) {
        return .{ .refused = "“You” and “Me” are reserved — please pick another name." };
    }
    return .{ .ok = .{ .user_name = out, .name_seal = .{} } };
}

test "validateUserName collapses whitespace, requires alnum, rejects punctuation/overlength" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // happy: trims, collapses internal whitespace runs to one space
    try testing.expectEqualStrings("Steve Howell", (try validateUserName(a, "  Steve   Howell  ")).ok.text());
    // apostrophe + space allowed; non-ASCII bytes treated as letters (permissive)
    try testing.expectEqualStrings("O'Brien", (try validateUserName(a, "O'Brien")).ok.text());
    try testing.expectEqualStrings("José", (try validateUserName(a, "José")).ok.text());

    // ── rejections: name is empty, err is set ──
    const cases = [_][]const u8{
        "   ", //                whitespace only
        "a<b", //                angle bracket (HTML-injection shaped)
        "x;y", //                semicolon
        "path/name", //          slash
        "'' ''", //              punctuation but no letter/digit
        &@as([41]u8, @splat('a')), //            41 bytes, over the 40 cap
        "Jos\xe9", //            Latin-1, not UTF-8
        "a\xc0\xafb", //         an overlong encoding of '/'
        "\xed\xa0\x80x", //       a UTF-16 surrogate half
    };
    for (cases) |raw| {
        const r = try validateUserName(a, raw);
        try testing.expect(r == .refused and r.refused.len != 0);
    }

    // "You"/"Me" are UI sentinels — reserved case-insensitively (incl. after trim).
    const reserved = [_][]const u8{ "You", "you", "Me", "me", "YOU", "  Me  " };
    for (reserved) |raw| {
        const r = try validateUserName(a, raw);
        try testing.expect(r == .refused and r.refused.len != 0);
    }
    // but names that merely CONTAIN them are fine
    try testing.expectEqualStrings("Mel", (try validateUserName(a, "Mel")).ok.text());
    try testing.expectEqualStrings("You Two", (try validateUserName(a, "You Two")).ok.text());
}

test "UserName.literal takes only a name validateUserName gives back as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("O'Brien", UserName.literal("O'Brien").text());
    for ([_][]const u8{ "Steve Howell", "José", "Mel", "You Two" }) |ok| {
        try testing.expect(canonical(ok));
        try testing.expectEqualStrings(ok, (try validateUserName(arena.allocator(), ok)).ok.text());
    }
    for ([_][]const u8{ "", " Ada", "Ada ", "A  B", "a\nb", "a<b", "You", "'", &@as([41]u8, @splat('a')) }) |bad| try testing.expect(!canonical(bad));
}
