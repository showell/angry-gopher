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
/// Accounts one address may CREATE in a window before it is refused (QUEUE.md
/// item 100). Every creation is a bcrypt (`setUserPassword`), so an unbounded
/// creator is a CPU flood on metal's one core and a way to fill the account
/// table; a real person makes one account, so five an hour is generous.
pub const create_max: u32 = 5;
pub const create_window_s: i64 = 60 * 60;

pub const Bound = enum {
    address,
    account,
    creates,

    /// The 429's body: it names the bound without naming the account or the
    /// address (a guesser learns nothing from it).
    pub fn text(b: Bound) []const u8 {
        return switch (b) {
            .address => std.fmt.comptimePrint(
                "Too many sign-in attempts from your network. Wait about {d} minutes and try again.\n",
                .{@divTrunc(addr_window_s, 60)},
            ),
            .account => "Too many sign-in attempts for this account. Wait up to an hour and try again.\n",
            .creates => "Too many accounts created from your network. Wait up to an hour and try again.\n",
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
var creates: [slots]Slot = @splat(.{}); // accounts created, per address (item 100)

/// **THE PROOF THE REFUSAL NEVER REACHED BCRYPT** (item 97): every refusal
/// `check` returns is counted here, and it is exposed on `/version`
/// (`login_throttle.refused`). A judge story drives past a bound and reads this
/// move on both hosts, so "refused before the hash" is observable, not promised.
var refused_count: u64 = 0;

pub fn refused() u64 {
    return @atomicLoad(u64, &refused_count, .monotonic);
}

/// A clock the tests can hand the module (QUEUE.md item 101), so `check`,
/// `recordFailure`, `clearAddress`, `createAllowed` and `recordCreate` — not
/// just the helpers — are exercised with time under control. Null in
/// production: the real wall clock.
var test_now: ?i64 = null;

fn now(io: Io) i64 {
    return test_now orelse @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
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

/// Bumps `key`'s count in `table`, creating or re-windowing its slot. When the
/// table is full it gives up a slot, but **never a throttled one** (QUEUE.md
/// item 101): the oldest slot still UNDER its `bound` goes, and only if every
/// live slot is already over its bound does the oldest of those. Otherwise ~256
/// cheap failures could flush uid 1's count and earn another round of guesses.
fn bump(table: []Slot, key_in: []const u8, t: i64, window: i64, bound: u32) void {
    const key = key_in[0..@min(key_in.len, max_key)];
    var free: ?*Slot = null; // empty or expired: reuse first, it throttles nobody
    var oldest_under: ?*Slot = null; // live, below its bound: safe to evict
    var oldest_any: ?*Slot = null; // the last resort, if all are over bound
    for (table) |*s| {
        if (s.len != 0 and std.mem.eql(u8, s.key[0..s.len], key)) {
            if (t - s.since >= window) fresh(s, key, t);
            s.fails += 1;
            return;
        }
        const expired = s.len == 0 or t - s.since >= window;
        if (free == null and expired) free = s;
        if (s.len != 0 and !expired) {
            if (oldest_any == null or s.since < oldest_any.?.since) oldest_any = s;
            if (s.fails < bound and (oldest_under == null or s.since < oldest_under.?.since)) oldest_under = s;
        }
    }
    const s = free orelse oldest_under orelse oldest_any.?;
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
    const t = now(io);
    if (address) |a| bump(&addrs, a, t, addr_window_s, addr_fails);
    bump(&accounts, account_id, t, account_window_s, account_fails);
}

/// A password check succeeded: clear this address's count, so a member who
/// mistyped and then got it right is not throttled. The account's count is left
/// (a correct password does not undo a distributed attack on it).
pub fn clearAddress(_: Io, address: ?[]const u8) void {
    const a = address orelse return;
    const key = a[0..@min(a.len, max_key)];
    for (&addrs) |*s| {
        if (s.len != 0 and std.mem.eql(u8, s.key[0..s.len], key)) {
            s.len = 0;
            s.fails = 0;
            return;
        }
    }
}

/// **BEFORE THE BCRYPT, FOR ACCOUNT CREATION** (QUEUE.md item 100). Whether this
/// address may create another account, or the bound that is over. `address`
/// null (no peer) is allowed — nothing to key on. Does not count; the caller
/// counts the creation it goes on to make with `recordCreate`.
pub fn createAllowed(io: Io, address: ?[]const u8) ?Bound {
    const a = address orelse return null;
    if (peek(&creates, a, now(io), create_window_s) >= create_max) {
        _ = @atomicRmw(u64, &refused_count, .Add, 1, .monotonic);
        return .creates;
    }
    return null;
}

/// An account was created from `address`: count it.
pub fn recordCreate(io: Io, address: ?[]const u8) void {
    const a = address orelse return;
    bump(&creates, a, now(io), create_window_s, create_max);
}

/// For the tests: forget everything (the tables are process-lifetime).
pub fn forgetAllForTest() void {
    for (&addrs) |*s| s.* = .{};
    for (&accounts) |*s| s.* = .{};
    for (&creates) |*s| s.* = .{};
    @atomicStore(u64, &refused_count, 0, .monotonic);
}

// ══ TESTS ════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// The public surface (QUEUE.md item 101): the tests drive the real `check` /
/// `recordFailure` / `clearAddress` / `createAllowed` / `recordCreate`, with
/// the module's clock set, so they exercise what the handlers call — not the
/// helpers under them. `io` is unused once `test_now` is set.
const tio: Io = undefined;

fn at(t: i64) void {
    test_now = t;
}

fn reset() void {
    forgetAllForTest();
    test_now = null;
}

test "the Nth failure from an address is refused before the check, and the count moves" {
    reset();
    defer reset();
    at(1_000);
    const addr = "203.0.113.7";
    for (0..addr_fails) |_| {
        try testing.expect(check(tio, addr, "1") == null); // under the bound: proceed
        recordFailure(tio, addr, "1");
    }
    try testing.expect(check(tio, addr, "1") == .address); // the (N+1)th is refused
    try testing.expect(refused() >= 1);
}

test "a success clears the address but not the account" {
    reset();
    defer reset();
    at(2_000);
    const acct = "1";
    // Many addresses hit the account bound; each address well under its own.
    for (0..account_fails) |i| {
        var buf: [20]u8 = undefined;
        const a = std.fmt.bufPrint(&buf, "10.1.{d}.{d}", .{ i / 250, i % 250 }) catch unreachable;
        try testing.expect(check(tio, a, acct) == null);
        recordFailure(tio, a, acct);
    }
    // A fresh address is now refused on the ACCOUNT bound alone.
    try testing.expect(check(tio, "198.51.100.5", acct) == .account);
    // Clearing an address does not clear the account.
    clearAddress(tio, "10.1.0.0");
    try testing.expect(check(tio, "198.51.100.5", acct) == .account);

    // Separately: an address that mistyped then succeeded is not throttled.
    const m = "203.0.113.9";
    for (0..addr_fails - 1) |_| recordFailure(tio, m, "2"); // 9 of 10, under the bound
    clearAddress(tio, m); // the correct password
    try testing.expect(check(tio, m, "2") == null);
}

test "the window reopens: after it passes, the count starts again" {
    reset();
    defer reset();
    const addr = "198.51.100.9";
    at(5_000);
    for (0..addr_fails) |_| recordFailure(tio, addr, "1");
    try testing.expect(check(tio, addr, "1") == .address);
    at(5_000 + addr_window_s); // the window has passed
    try testing.expect(check(tio, addr, "1") == null);
}

test "account creation is bounded per address, before the hash" {
    reset();
    defer reset();
    at(7_000);
    const addr = "203.0.113.20";
    for (0..create_max) |_| {
        try testing.expect(createAllowed(tio, addr) == null);
        recordCreate(tio, addr);
    }
    try testing.expect(createAllowed(tio, addr) == .creates); // the (N+1)th
    // A null address (no peer) is never create-throttled.
    try testing.expect(createAllowed(tio, null) == null);
}

test "a full table never evicts a throttled slot, so a flood cannot flush an account" {
    reset();
    defer reset();
    at(9_000);
    // Throttle one account past its bound from a dedicated address.
    const victim = "192.0.2.1";
    for (0..addr_fails) |_| recordFailure(tio, victim, "1");
    try testing.expect(check(tio, victim, "1") == .address);
    // Now flood the address table full with other addresses, each a single
    // failure (well under the bound). The victim's slot must survive, because
    // eviction takes an under-bound slot before a throttled one.
    for (0..slots * 2) |i| {
        var buf: [24]u8 = undefined;
        const a = std.fmt.bufPrint(&buf, "172.16.{d}.{d}", .{ i / 250, i % 250 }) catch unreachable;
        recordFailure(tio, a, "2");
    }
    try testing.expect(check(tio, victim, "1") == .address); // still throttled
}
