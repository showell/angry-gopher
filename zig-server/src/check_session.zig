//! check_session: the zig half of the session-cookie cross-validation gate.
//!
//! Direction 1 (production-critical): read session_gold.jsonl — cookies signed
//! by the REAL Go signer (users.SignSessionWith) with a synthetic secret, each
//! paired with the verdict Go's verifier produces — and assert
//! users.verifySessionWithSecret agrees on every one. This proves the zig server
//! accepts existing members' live browser cookies unchanged (read-only
//! identity), and rejects expired / tampered / wrong-secret / malformed ones.
//!
//! Run:  cd zig-server && zig run src/check_session.zig
//! (Direction 2 — Go verifying zig's signature — lives in cmd/session_check.)

const std = @import("std");
const users = @import("users.zig");

const GOLD_PATH = "session_gold.jsonl";

const Case = struct {
    id: []const u8,
    secret: []const u8, // hex
    cookie: []const u8,
    now: i64,
    expect: []const u8, // resolved id, or "" if it must be rejected
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const data = std.Io.Dir.cwd().readFileAlloc(io, GOLD_PATH, alloc, .unlimited) catch |e| {
        std.debug.print("cannot read {s}: {s}\n", .{ GOLD_PATH, @errorName(e) });
        std.process.exit(1);
    };
    defer alloc.free(data);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const c = try std.json.parseFromSliceLeaky(Case, a, line, .{});

        const secret = try a.alloc(u8, c.secret.len / 2);
        _ = try std.fmt.hexToBytes(secret, c.secret);

        const got = users.verifySessionWithSecret(a, secret, c.cookie, c.now) orelse "";
        if (std.mem.eql(u8, got, c.expect)) {
            pass += 1;
        } else {
            fail += 1;
            std.debug.print("FAILID\t{s}\n  expect id={s} got id={s}\n  cookie: {s}\n", .{ c.id, c.expect, got, c.cookie });
        }
    }

    std.debug.print("== Go->zig session verify (direction 1): {d}/{d} passing  ({d} failing)\n", .{ pass, pass + fail, fail });
    if (fail != 0) std.process.exit(1);
}
