//! hash-password: a password on stdin, its bcrypt hash on stdout, as
//! users.setUserPassword would store it (auth.zig, cost 10). For the way back
//! in when the admin's password is lost (gopher-metal QUEUE.md item 89): the
//! hash is made here, on the machine of the person resetting it, and only the
//! hash travels — to prod by ops/reset_admin_password, to metal in its boot
//! disk's gopher-metal.conf by gopher-metal's droplet/chat.py.
//!
//!     printf '%s' "$password" | zig-out/bin/hash-password
//!
//! The password is the first line of stdin, without its line ending. An
//! empty one is refused: it would be a password anyone can type.

const std = @import("std");
const auth = @import("auth.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &in_buf);
    const line = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
        error.StreamTooLong => fail("hash-password: a password longer than 4 KiB"),
        else => return e,
    } orelse "";
    const password = std.mem.trimEnd(u8, line, "\r");
    if (password.len == 0) fail("hash-password: no password on stdin");
    // bcrypt reads at most 72 bytes; one longer would be cut without a word,
    // and two passwords sharing those 72 bytes would both open the account.
    if (password.len > 72) fail("hash-password: bcrypt uses only the first 72 bytes; choose a shorter password");

    var out: [60]u8 = undefined;
    const hash = try auth.hashPassword(password, &out, io);
    var out_buf: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &out_buf);
    try writer.interface.print("{s}\n", .{hash});
    try writer.interface.flush();
}

fn fail(why: []const u8) noreturn {
    std.debug.print("{s}\n", .{why});
    std.process.exit(1);
}
