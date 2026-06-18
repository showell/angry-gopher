//! check_bcrypt: the zig half of the bcrypt cross-validation gate.
//!
//! Direction 1 (the production-critical one): read bcrypt_gold.jsonl — synthetic
//! (password, Go-`$2a$` hash, expect) rows produced by cmd/bcrypt_gold using the
//! exact library that hashed every live stored password — and assert that
//! auth.verifyPassword agrees with Go on every verdict. This proves the zig
//! server can log in existing users without re-hashing anyone.
//!
//! Plus a self round-trip: hash a password with auth.hashPassword (zig `$2b$`),
//! verify it accepts the right password and rejects the wrong one.
//!
//! Run:  cd zig-server && zig run src/check_bcrypt.zig
//! (Direction 2 — Go reading zig's `$2b$` output — lives in cmd/bcrypt_check.)

const std = @import("std");
const auth = @import("auth.zig");

const GOLD_PATH = "bcrypt_gold.jsonl";

const Case = struct {
    id: []const u8,
    password: []const u8,
    hash: []const u8,
    expect: bool,
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const data = std.Io.Dir.cwd().readFileAlloc(io, GOLD_PATH, alloc, .unlimited) catch |e| {
        std.debug.print("cannot read {s}: {s}\n", .{ GOLD_PATH, @errorName(e) });
        std.process.exit(1);
    };
    defer alloc.free(data);

    var pass: usize = 0;
    var fail: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const c = try std.json.parseFromSliceLeaky(Case, a, line, .{});
        const got = auth.verifyPassword(c.hash, c.password);
        if (got == c.expect) {
            pass += 1;
        } else {
            fail += 1;
            std.debug.print("FAILID\t{s}\n  expect verify={any} got={any}\n  pw:   {s}\n  hash: {s}\n", .{ c.id, c.expect, got, c.password, c.hash });
        }
    }
    std.debug.print("== Go->zig verify (direction 1): {d}/{d} passing  ({d} failing)\n", .{ pass, pass + fail, fail });

    // Self round-trip: zig hashes, zig verifies.
    var rt_ok = true;
    var buf: [60]u8 = undefined;
    const h = try auth.hashPassword("round trip secret", &buf, io);
    if (!auth.verifyPassword(h, "round trip secret")) {
        std.debug.print("FAIL round-trip: zig hash rejected its own correct password\n", .{});
        rt_ok = false;
        fail += 1;
    }
    if (auth.verifyPassword(h, "wrong secret")) {
        std.debug.print("FAIL round-trip: zig hash accepted a wrong password\n", .{});
        rt_ok = false;
        fail += 1;
    }
    if (rt_ok) {
        pass += 1;
        std.debug.print("== zig self round-trip: ok\n", .{});
    }

    std.debug.print("==> {d}/{d} passing  ({d} failing)\n", .{ pass, pass + fail, fail });
    if (fail != 0) std.process.exit(1);
}
