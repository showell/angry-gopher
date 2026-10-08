//! ustar: **ONE TAR HEADER, WITH ITS PATH WHOLE OR REFUSED.** Zig's std has
//! a tar reader and no writer; the backup (admin_backup.zig) and a topic's
//! download (chat_download.zig) each write one, and both build their 512-byte
//! headers here.
//!
//! A ustar header holds a path of up to 255 bytes as a prefix of up to 155
//! and a name of up to 100, split at a slash. A path that cannot be split so
//! is `error.NameTooLong`, never its first 100 bytes: a topic's download once
//! cut `<sid>/<sid>.md` and `<sid>/<sid>.reactions.jsonl` to the same 100
//! bytes for a long topic name, and unpacking it wrote the reactions over the
//! transcript.

const std = @import("std");

pub const Parts = struct { prefix: []const u8, name: []const u8 };

/// `path` as (prefix, name) for a ustar header, or null when it cannot be.
pub fn split(path: []const u8) ?Parts {
    if (path.len <= 100) return .{ .prefix = "", .name = path };
    // The latest slash that leaves a name of at most 100 and a prefix of at
    // most 155.
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] != '/') continue;
        if (path.len - i - 1 > 100) return null;
        if (i <= 155 and path.len - i - 1 > 0) return .{ .prefix = path[0..i], .name = path[i + 1 ..] };
    }
    return null;
}

pub fn fits(path: []const u8) bool {
    return split(path) != null;
}

/// The header of an entry at `path`: a regular file (`typeflag` '0') of
/// `size` bytes, or a folder ('5').
pub fn header(path: []const u8, size: u64, mtime: u64, typeflag: u8) error{NameTooLong}![512]u8 {
    const parts = split(path) orelse return error.NameTooLong;
    var hdr: [512]u8 = @splat(0);
    @memcpy(hdr[0..parts.name.len], parts.name);
    octalField(hdr[100..108], if (typeflag == '5') 0o755 else 0o644); // mode
    octalField(hdr[108..116], 0); // uid
    octalField(hdr[116..124], 0); // gid
    octalField(hdr[124..136], size);
    octalField(hdr[136..148], mtime);
    @memset(hdr[148..156], ' '); // the checksum field counts as spaces while summing
    hdr[156] = typeflag;
    @memcpy(hdr[257..263], "ustar\x00");
    hdr[263] = '0'; // version "00"
    hdr[264] = '0';
    @memcpy(hdr[345..][0..parts.prefix.len], parts.prefix);
    var sum: u32 = 0;
    for (hdr) |c| sum += c;
    octalDigits(hdr[148..154], sum); // six octal digits, a NUL, a space
    hdr[154] = 0;
    hdr[155] = ' ';
    return hdr;
}

/// `value` as (field.len - 1) zero-padded octal digits and a NUL: ustar's
/// numeric fields.
fn octalField(field: []u8, value: u64) void {
    const digits = field.len - 1;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    field[digits] = 0;
}

/// Exactly field.len zero-padded octal digits, no terminator.
fn octalDigits(field: []u8, value: u64) void {
    var v = value;
    var i = field.len;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a long path goes in ustar's prefix, split at a slash, and one too long does not fit" {
    const short = split("data/chat/1_2/sessions/topic.md").?;
    try testing.expectEqualStrings("", short.prefix);
    const long = split("data/chat/1_2/sessions/" ++ "t" ** 90 ++ ".md").?;
    try testing.expectEqualStrings("data/chat/1_2/sessions", long.prefix);
    try testing.expect(split("data/" ++ "x" ** 101) == null);
    try testing.expect(split("p" ** 160 ++ "/name") == null);
}

test "a topic's download, at the longest topic name, reads back whole through zig's tar reader" {
    // chat_store.validSessionID allows 80 characters.
    const sid = "a" ** 80;
    const paths = [_][]const u8{
        sid ++ "/" ++ sid ++ ".md",
        sid ++ "/" ++ sid ++ ".reactions.jsonl",
        sid ++ "/uploads/0123456789abcdef0123456789abcdef.png",
    };
    var tar: std.ArrayList(u8) = .empty;
    defer tar.deinit(testing.allocator);
    for (paths) |p| {
        const hdr = try header(p, 2, 0, '0');
        try tar.appendSlice(testing.allocator, &hdr);
        try tar.appendSlice(testing.allocator, "ok");
        try tar.appendNTimes(testing.allocator, 0, 510);
    }
    try tar.appendNTimes(testing.allocator, 0, 1024);

    var reader: std.Io.Reader = .fixed(tar.items);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    for (paths) |p| {
        const f = (try it.next()).?;
        try testing.expectEqualStrings(p, f.name);
    }
    try testing.expect(try it.next() == null);
}

test "a path no ustar header can hold is refused, not cut" {
    try testing.expectError(error.NameTooLong, header("x" ** 120, 0, 0, '0'));
}
