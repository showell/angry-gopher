//! presence: who's actively touching the chat subsystem RIGHT NOW.
//! A user is "online" if any counted chat route
//! marked them active within the last 5 minutes. No client polling, no idle
//! detection — the server's view of "is this user touching things?" IS the
//! definition.
//!
//! Lifecycle: every counted page/action route runs through markActive
//! (Host.count_presence!), which bumps the user's lastSeen. On the
//! offline→online edge (first sighting OR >= PresenceWindow of inactivity) the
//! Roc fans a came-online event to every OTHER authorized user across both
//! attention streams — the sidebar bus (the partner-row presence dot) and the
//! notify bus (the status strip) — and gives the edge back (giveBack) when it
//! cannot (metal-vmm QUEUE 288). No background sweeper, no offline broadcast: a row goes gray lazily on
//! the next page render when isOnline returns false.
//!
//! In-memory only, lost on restart, 5-minute fuzz. The
//! lastSeen map outlives any one request, so its keys are duped from the
//! process-lifetime page allocator, NOT the per-request arena.

const std = @import("std");
const mem_meter = @import("webbox").mem_meter;
const Now = @import("request_time.zig").Now;

/// PresenceWindow: a markActive within this window (5 min) means online.
const window_ns: i128 = 5 * std.time.ns_per_min;

/// The lastSeen map (uid → most-recent markActive, in real-clock ns).
/// Process-lifetime; keys are dupes owned by the metered base allocator
/// (mem_meter) so this map's growth shows up in the leak meter. Captured at
/// module level, so the route table reaches the meter's singleton: that is why
/// the meter's child has no default. It once defaulted to page_allocator, "so
/// base() is valid even before init() runs", and that mmap was the one thing
/// standing between zig-metal-unikernel and angry-gopher's real dispatch.
const gpa = mem_meter.base();
// No lock: only handlers reach these maps, one at a time (the host's turn,
// zig-metal-unikernel HOST.md); a kept stream's task never does.
var last_seen: std.StringHashMapUnmanaged(i128) = .empty;
/// Came-online broadcasts owed (one that could not start), uid → when it
/// was last tried (metal-vmm QUEUE 177.6): kept apart from `last_seen`, so
/// an active user stays online while it is owed. Keys are `last_seen`'s.
var owed: std.StringHashMapUnmanaged(i128) = .empty;
/// How long an owed broadcast waits before it is tried again: a lasting
/// failure (the user list unreadable) is not read on every request. **IT IS
/// TRIED ON THE USER'S NEXT REQUEST PAST THE WAIT**, never by a timer
/// (metal-vmm QUEUE 180.6): a user who goes quiet is told to no one, and
/// shows online to whoever renders a page, by `isOnline`. A test lets the
/// time pass (`Now.plus`).
const owed_retry_ns: i128 = 30 * std.time.ns_per_s;

/// **A TEST'S FRESH START**: nobody seen, nothing owed (a test that serves
/// the same requests twice must not find the first run's members online).
pub fn forgetForTest() void {
    var keys = last_seen.keyIterator();
    while (keys.next()) |k| gpa.free(k.*);
    last_seen.clearAndFree(gpa);
    owed.clearAndFree(gpa);
}

/// markActive bumps `uid`'s lastSeen and reports whether THIS bump was the
/// transition edge from offline to online (true on first-ever sighting OR after
/// >= PresenceWindow of inactivity), at the request's time `at`. Pure state
/// mutation: the Roc broadcasts the edge (metal-vmm QUEUE 288).
pub fn markActive(uid: []const u8, at: Now) bool {
    if (uid.len == 0) return false;
    const now: i128 = at.real_ns;
    const gop = last_seen.getOrPut(gpa, uid) catch return false;
    if (!gop.found_existing) {
        // getOrPut stored the borrowed (arena) key slice; replace it with a
        // process-lifetime dupe so the map never dangles after the request ends.
        gop.key_ptr.* = gpa.dupe(u8, uid) catch {
            _ = last_seen.remove(uid);
            return false;
        };
        gop.value_ptr.* = now;
        return true;
    }
    const prev = gop.value_ptr.*;
    gop.value_ptr.* = now;
    if ((now - prev) >= window_ns) {
        _ = owed.remove(gop.key_ptr.*);
        return true;
    }
    // An edge owed, tried again once its wait is over.
    if (owed.getPtr(gop.key_ptr.*)) |tried| if (now - tried.* >= owed_retry_ns) {
        _ = owed.remove(gop.key_ptr.*);
        return true;
    };
    return false;
}

/// **THE EDGE GIVEN BACK** (Host.presence_unspent!, metal-vmm QUEUE 172,
/// 288): the Roc could not tell it, so `uid` is owed, and their first
/// markActive (a request) after `owed_retry_ns` is the edge again. Its last
/// sighting stands, so it is still online (177.6: it was set back a window,
/// which showed an active user offline).
pub fn giveBack(uid: []const u8, at: Now) void {
    const key = last_seen.getKey(uid) orelse return;
    owed.put(gpa, key, at.real_ns) catch {};
}

/// **SEEN WHERE NO ONE IS TOLD** (/settings, metal-vmm QUEUE 288): `uid`
/// counted online now, and an edge kept, owed at once, so the member's next
/// chat request is the edge the Roc broadcasts.
pub fn markSeen(uid: []const u8, at: Now) void {
    if (!markActive(uid, at)) return;
    const key = last_seen.getKey(uid) orelse return;
    owed.put(gpa, key, at.real_ns - owed_retry_ns) catch {};
}

/// isOnline reports whether `uid` was markActive'd within PresenceWindow of
/// the request's time `at`. Read-only; called by the sidebar payload to
/// compute each partner row's first-paint Online flag.
pub fn isOnline(uid: []const u8, at: Now) bool {
    if (uid.len == 0) return false;
    const v = last_seen.get(uid) orelse return false;
    return (@as(i128, at.real_ns) - v) < window_ns;
}

test "presence: an edge given back leaves its user online, and a lasting failure is tried again once a while, not on every request (metal-vmm QUEUE 177.6)" {
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const uid = "presence-owed-177";
    const t = Now.at(1_761_400_000);
    try std.testing.expect(markActive(uid, t));
    giveBack(uid, t);
    // Active a moment ago: online, whatever the broadcast did.
    try std.testing.expect(isOnline(uid, t.plus(1)));
    // Owed, but not tried again at once: the user list is not re-read on
    // every request while the failure lasts.
    try std.testing.expect(!markActive(uid, t.plus(1)));
    // Past the wait, the next request is the edge again.
    try std.testing.expect(markActive(uid, t.plus(32)));
    // And five minutes quiet is offline.
    try std.testing.expect(!isOnline(uid, t.plus(32 + 5 * 60)));
}

test "presence: a member seen on /settings is online, and their next chat request is still the edge (metal-vmm QUEUE 288)" {
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const uid = "presence-seen-288";
    const t = Now.at(1_761_400_000);
    markSeen(uid, t);
    try std.testing.expect(isOnline(uid, t.plus(1)));
    try std.testing.expect(markActive(uid, t.plus(1)));
    // Spent there: the next is not.
    try std.testing.expect(!markActive(uid, t.plus(2)));
    // Seen again while online: no edge to keep.
    markSeen(uid, t.plus(3));
    try std.testing.expect(!markActive(uid, t.plus(4)));
}
