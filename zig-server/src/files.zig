//! **AN ERROR IS NOT AN EMPTY FILE.**
//!
//! A file that is not there legitimately means "nothing yet": a user with no
//! pins, a document nobody has started, a conversation with no reactions. A
//! file that IS there and will not read means something else entirely — the
//! disk, the permissions, a truncated name — and both arrive at the call site
//! as an error.
//!
//! `catch ""` cannot tell them apart, and the places that then WRITE what they
//! read turn one failed read into lost data: a document replaced by its newest
//! paragraph, a pinned set replaced by its newest pin. This says the
//! difference once, out loud, so a caller cannot forget it.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// The file's bytes, or "" when there is no such file. **Any other failure is
/// the caller's to deal with** — usually by leaving alone whatever it was
/// about to overwrite.
pub fn readOrEmpty(io: Io, alloc: Alloc, path: []const u8, limit: Io.Limit) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, limit) catch |e| switch (e) {
        error.FileNotFound => try alloc.alloc(u8, 0),
        else => e,
    };
}

const testing = std.testing;

test "a missing file is empty, and something unreadable in its place is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    const missing = try std.fs.path.join(a, &.{ base, "not-here" });
    try testing.expectEqualStrings("", try readOrEmpty(io, a, missing, .unlimited));

    // **SOMETHING THAT EXISTS BUT WILL NOT READ MUST NOT COME BACK AS ""**,
    // because the caller is about to write over what it thinks is empty.
    const dir = try std.fs.path.join(a, &.{ base, "a-directory" });
    try Io.Dir.cwd().createDirPath(io, dir);
    try testing.expect(readOrEmpty(io, a, dir, .unlimited) catch null == null);
}
