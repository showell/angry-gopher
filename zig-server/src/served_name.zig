//! **WHAT A REQUEST MAY NAME OF A SERVED FOLDER**: the one check the
//! downloads and the gallery each made of a name from the URL before
//! reading the file it names (they were two copies, line for line; shale's
//! cookbook/zig/clones.shale found them).

/// `[A-Za-z0-9._-]` and nothing else: no path separator, so no traversal
/// (a `.` is fine; a `..` segment needs a `/` to escape, which is refused).
pub fn isSafeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

test "served_name: a file's own name is safe; a path, an empty name, a space or a byte past ASCII is not" {
    const testing = @import("std").testing;
    for ([_][]const u8{ "a.png", "lyn-rummy_1.2.tar.gz", "..", ".hidden", "A" }) |n| try testing.expect(isSafeName(n));
    for ([_][]const u8{ "", "a/b.png", "../x", "a\\b", "a b", "caf\xc3\xa9.png", "a\x00b", "%2e%2e" }) |n| try testing.expect(!isSafeName(n));
}
