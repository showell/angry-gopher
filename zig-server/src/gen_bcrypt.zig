//! gen_bcrypt: produces bcrypt_zig.jsonl — synthetic (password, zig-`$2b$` hash)
//! rows that cmd/bcrypt_check verifies with Go's bcrypt. This is direction 2 of
//! the cross-validation: proof that Go can read what the zig server would write.
//!
//! It's the reversibility guarantee — if we ever run the zig binary in
//! production (hashing new passwords as `$2b$`) and then roll back to the Go
//! binary, Go must still verify those hashes. (It does, natively; this freezes
//! that as a permanent regression guard rather than a one-off probe.)
//!
//! Passwords are SYNTHETIC, so the fixture is committed. Regenerate with:
//!   cd zig-server && zig run src/gen_bcrypt.zig
//! Each run reshuffles salts — re-commit on purpose, it's a fixture not a snapshot.

const std = @import("std");
const auth = @import("auth.zig");

const OUT_PATH = "bcrypt_zig.jsonl";

const Row = struct { id: []const u8, password: []const u8, hash: []const u8 };

const passwords = [_]struct { id: []const u8, pw: []const u8 }{
    .{ .id = "plain", .pw = "correct horse battery staple" },
    .{ .id = "symbols", .pw = "p@ssw0rd! #2026" },
    .{ .id = "single", .pw = "a" },
    .{ .id = "empty", .pw = "" },
    .{ .id = "spaces", .pw = "  leading and trailing  " },
    .{ .id = "unicode", .pw = "café ☕ 日本語 π" },
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    for (passwords) |p| {
        var buf: [60]u8 = undefined;
        const h = try auth.hashPassword(p.pw, &buf, io);
        const row = Row{ .id = p.id, .password = p.pw, .hash = h };
        const line = try std.fmt.allocPrint(alloc, "{f}\n", .{std.json.fmt(row, .{})});
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = OUT_PATH, .data = out.items });
    std.debug.print("wrote {d} rows to {s}\n", .{ passwords.len, OUT_PATH });
}
