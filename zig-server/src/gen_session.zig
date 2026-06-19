//! gen_session: produces session_zig.jsonl — session cookies signed by the zig
//! signer (users.signSession) with a synthetic secret, which cmd/session_check
//! verifies with the REAL Go verifier (users.VerifySessionWith). Direction 2 of
//! the cross-validation: proof that a cookie the zig server would issue is
//! accepted by Go — the reversibility guard (zig-issued sessions survive a
//! rollback to the Go binary).
//!
//! Deterministic (no salt), so the fixture is stable; the secret is synthetic,
//! so it's repo-safe. Regenerate: cd zig-server && zig run src/gen_session.zig

const std = @import("std");
const users = @import("users.zig");

const OUT_PATH = "session_zig.jsonl";

// a synthetic 32-byte secret (never the live _session_secret).
const secret = [_]u8{'z'} ** 16 ++ [_]u8{'Z'} ** 16;

// fixed base "issued" time + the cookie lifetime, matching Go's gold.
const t0: i64 = 1_700_000_000;
const max_age: i64 = 365 * 24 * 60 * 60;

const Row = struct {
    id: []const u8,
    secret: []const u8, // hex
    cookie: []const u8,
    now: i64,
    expect: []const u8,
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret_hex = std.fmt.bytesToHex(secret, .lower);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const ids = [_][]const u8{ "1", "3", "42", "1234567890" };
    for (ids) |uid| {
        // fresh: Go must accept and resolve to uid.
        const cookie = try users.signSession(alloc, &secret, uid, t0);
        try emit(alloc, &out, .{ .id = try lbl(alloc, "accept/", uid), .secret = &secret_hex, .cookie = cookie, .now = t0, .expect = uid });
        // expired: same cookie, but Go's expiry (now past max age) must reject.
        try emit(alloc, &out, .{ .id = try lbl(alloc, "expired/", uid), .secret = &secret_hex, .cookie = cookie, .now = t0 + max_age + 1, .expect = "" });
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = OUT_PATH, .data = out.items });
    std.debug.print("wrote {d} rows to {s}\n", .{ ids.len * 2, OUT_PATH });
}

fn emit(alloc: std.mem.Allocator, out: *std.ArrayList(u8), row: Row) !void {
    const line = try std.fmt.allocPrint(alloc, "{f}\n", .{std.json.fmt(row, .{})});
    try out.appendSlice(alloc, line);
}

fn lbl(alloc: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, id });
}
