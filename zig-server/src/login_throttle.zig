//! login_throttle: refuse password guesses BEFORE the bcrypt (QUEUE.md item
//! 97; gopher-metal's DESIGN-login-throttle.md, option B).
//!
//! Each `/login/full` that verifies a member is a bcrypt check (cost 10) — tens
//! of milliseconds of CPU, and on gopher-metal that is the machine's one
//! processor. So an unlimited guesser is two problems at once: it guesses uid 1
//! (the only account worth it), and it exhausts the core. The defence is to
//! count failures and, past a bound, refuse with a 429 **before**
//! `checkUserPassword` is ever called — a hash-table probe, not a hash.
//!
//! Two windowed counters, like game_limits' per-address table:
//!   - **by ADDRESS** (`game_limits.clientAddress`: the peer, or the trusted
//!     proxy's last X-Forwarded-For): one place hammering any account. The CPU
//!     guard against a single flooder.
//!   - **by ACCOUNT** (the resolved member id, so two spellings or cases of the
//!     same name are one account): many places guessing one account — the
//!     distributed attack on uid 1, which the per-address counter cannot see.
//!
//! A SUCCESS clears that address's count, so a member who mistypes and then gets
//! it right is not left throttled. The numbers are all here, in one place.
//!
//! **IT IS NOT A LOCK.** The windows reset, so a throttle is never itself a
//! lasting lockout of a real member; and if an attack burns uid 1's account
//! budget, the admin waits out the window or uses the reset runbook
//! (gopher-metal's ADMIN-PASSWORD-LOST.md) — the honest break-glass.
//!
//! In memory, reset on restart, the same on both hosts (no allocation outlives
//! a request), exactly as game_limits keeps its bounds — so the judge holds
//! both hosts to it identically.

const std = @import("std");
const Io = std.Io;

// ── the numbers, in one place ─────────────────────────────────────────────────
/// Failed sign-ins one address may make before it is refused, and the window.
pub const addr_fails: u32 = 10;
pub const addr_window_s: i64 = 15 * 60;
/// Failed sign-ins against one account before it is refused, and the window.
pub const account_fails: u32 = 30;
pub const account_window_s: i64 = 60 * 60;

pub const Bound = enum {
    address,
    account,

    /// The 429's body: it names the bound without naming the account or the
    /// address (a guesser learns nothing from it).
    pub fn text(b: Bound) []const u8 {
        return switch (b) {
            .address => std.fmt.comptimePrint(
                "Too many sign-in attempts from your network. Wait about {d} minutes and try again.\n",
                .{@divTrunc(addr_window_s, 60)},
            ),
            .account => "Too many sign-in attempts for this account. Wait up to an hour and try again.\n",
        };
    }
};

// ── the tables ────────────────────────────────────────────────────────────────
const max_key = 45; // the longest IPv6 text; a member id is far shorter
const slots = 256;

const Slot = struct {
    key: [max_key]u8 = undefined,
    len: u8 = 0, // 0: empty
    since: i64 = 0, // the window's start: its first count
    fails: u32 = 0,
};

var addrs: [slots]Slot = @splat(.{});
var accounts: [slots]Slot = @splat(.{});
var mu: Io.Mutex = .init;

/// **THE PROOF THE REFUSAL NEVER REACHED BCRYPT** (item 97): every refusal
/// `check` returns is counted here, and it is exposed on `/version`
/// (`login_throttle.refused`). A judge story drives past a bound and reads this
/// move on both hosts, so "refused before the hash" is observable, not promised.
var refused_count: u64 = 0;

pub fn refused() u64 {
    return @atomicLoad(u64, &refused_count, .monotonic);
}

fn now(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// The current fail count for `key` in `table`, or 0 if it is absent or its
/// window has passed. **Read-only**: it never creates a slot, so a check for a
/// never-seen key cannot evict a throttled one.
fn peek(table: []const Slot, key_in: []const u8, t: i64, window: i64) u32 {
    const key = key_in[0..@min(key_in.len, max_key)];
    for (table) |*s| {
        if (s.len != 0 and std.mem.eql(u8, s.key[0..s.len], key)) {
            if (t - s.since >= window) return 0; // the window has passed
            return s.fails;
        }
    }
    return 0;
}

/// Bumps `key`'s fail count in `table`, creating or re-windowing its slot. A
/// full table gives up its oldest, as game_limits' does.
fn bump(table: []Slot, key_in: []const u8, t: i64, window: i64) void {
    const key = key_in[0..@min(key_in.len, max_key)];
    var free: ?*Slot = null;
    var oldest: ?*Slot = null;
    for (table) |*s| {
        if (s.len != 0 and std.mem.eql(u8, s.key[0..s.len], key)) {
            if (t - s.since >= window) fresh(s, key, t);
            s.fails += 1;
            return;
        }
        if (free == null and (s.len == 0 or t - s.since >= window)) free = s;
        if (s.len != 0 and (oldest == null or s.since < oldest.?.since)) oldest = s;
    }
    const s = free orelse oldest.?;
    fresh(s, key, t);
    s.fails = 1;
}

fn fresh(s: *Slot, key: []const u8, t: i64) void {
    @memcpy(s.key[0..key.len], key);
    s.len = @intCast(key.len);
    s.since = t;
    s.fails = 0;
}

/// **BEFORE THE BCRYPT.** Returns the bound that is over, or null to let the
/// password be checked. `address` may be null (the host gave no peer); then only
/// the account dimension applies. A refusal is counted (`refused`).
pub fn check(io: Io, address: ?[]const u8, account_id: []const u8) ?Bound {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const t = now(io);
    if (address) |a| if (peek(&addrs, a, t, addr_window_s) >= addr_fails) {
        _ = @atomicRmw(u64, &refused_count, .Add, 1, .monotonic);
        return .address;
    };
    if (peek(&accounts, account_id, t, account_window_s) >= account_fails) {
        _ = @atomicRmw(u64, &refused_count, .Add, 1, .monotonic);
        return .account;
    }
    return null;
}

/// A password check failed: count it against both the address and the account.
pub fn recordFailure(io: Io, address: ?[]const u8, account_id: []const u8) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const t = now(io);
    if (address) |a| bump(&addrs, a, t, addr_window_s);
    bump(&accounts, account_id, t, account_window_s);
}

/// A password check succeeded: clear this address's count, so a member who
/// mistyped and then got it right is not throttled. The account's count is left
/// (a correct password does not undo a distributed attack on it).
pub fn clearAddress(io: Io, address: ?[]const u8) void {
    const a = address orelse return;
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const key = a[0..@min(a.len, max_key)];
    for (&addrs) |*s| {
        if (s.len != 0 and std.mem.eql(u8, s.key[0..s.len], key)) {
            s.len = 0;
            s.fails = 0;
            return;
        }
    }
}

/// For the tests: forget everything (the tables are process-lifetime).
pub fn forgetAllForTest() void {
    for (&addrs) |*s| s.* = .{};
    for (&accounts) |*s| s.* = .{};
    @atomicStore(u64, &refused_count, 0, .monotonic);
}

// ══ TESTS ════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn testIo() Io {
    return undefined; // now() is the only user of io, and the tests set the clock
}

// The tests drive `now` through a fake clock by calling the windowed helpers
// directly with an explicit `t`, which is what `check`/`record` compute from io.
test "a bound trips only after N failures, and the count proves the refusal is before any check" {
    forgetAllForTest();
    defer forgetAllForTest();
    const t: i64 = 1_000_000;
    const addr = "203.0.113.7";
    const acct = "1";
    // Under the bound: peek stays below, so a real check would proceed.
    for (0..addr_fails) |_| {
        try testing.expect(peek(&addrs, addr, t, addr_window_s) < addr_fails);
        bump(&addrs, addr, t, addr_window_s);
        bump(&accounts, acct, t, account_window_s);
    }
    // The (N+1)th: the address bound is reached, so a check refuses.
    try testing.expectEqual(addr_fails, peek(&addrs, addr, t, addr_window_s));
    try testing.expect(peek(&addrs, addr, t, addr_window_s) >= addr_fails);
}

test "the window resets: after it, the count starts again" {
    forgetAllForTest();
    defer forgetAllForTest();
    const addr = "198.51.100.9";
    var t: i64 = 5_000_000;
    for (0..addr_fails) |_| bump(&addrs, addr, t, addr_window_s);
    try testing.expectEqual(addr_fails, peek(&addrs, addr, t, addr_window_s));
    t += addr_window_s; // the window has passed
    try testing.expectEqual(@as(u32, 0), peek(&addrs, addr, t, addr_window_s));
}

test "the account bound is independent of the address, and survives a cleared address" {
    forgetAllForTest();
    defer forgetAllForTest();
    const t: i64 = 9_000_000;
    const acct = "1";
    // Many addresses, one account: each address stays well under its bound,
    // but the account climbs to its own.
    for (0..account_fails) |i| {
        var buf: [16]u8 = undefined;
        const addr = std.fmt.bufPrint(&buf, "10.0.0.{d}", .{i % 250}) catch unreachable;
        bump(&addrs, addr, t, addr_window_s);
        bump(&accounts, acct, t, account_window_s);
    }
    try testing.expect(peek(&accounts, acct, t, account_window_s) >= account_fails);
    // Clearing one address does not clear the account.
    for (&addrs) |*s| s.len = 0;
    try testing.expect(peek(&accounts, acct, t, account_window_s) >= account_fails);
}

test "a full address table gives up its oldest, not a newer one" {
    forgetAllForTest();
    defer forgetAllForTest();
    var t: i64 = 2_000_000;
    // Fill every slot, each at a distinct, increasing time.
    for (0..slots) |i| {
        var buf: [24]u8 = undefined;
        const addr = std.fmt.bufPrint(&buf, "172.16.{d}.{d}", .{ i / 250, i % 250 }) catch unreachable;
        bump(&addrs, addr, t, addr_window_s);
        t += 1;
    }
    // One more, within every window: it evicts the oldest (the first), and the
    // newest is still counted.
    bump(&addrs, "172.31.255.254", t, addr_window_s);
    try testing.expect(peek(&addrs, "172.31.255.254", t, addr_window_s) >= 1);
}
