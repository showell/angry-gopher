//! presence: who's actively touching the chat subsystem RIGHT NOW.
//! A user is "online" if any counted chat route
//! marked them active within the last 5 minutes. No client polling, no idle
//! detection — the server's view of "is this user touching things?" IS the
//! definition.
//!
//! Lifecycle: every counted page/action route runs through
//! markActiveAndBroadcast, which bumps the user's lastSeen. On the offline→online
//! edge (first sighting OR >= PresenceWindow of inactivity) it fans a came-online
//! event to every OTHER authorized user across both attention streams — the
//! sidebar bus (the partner-row presence dot) and the notify bus (the status
//! strip). No background sweeper, no offline broadcast: a row goes gray lazily on
//! the next page render when isOnline returns false.
//!
//! In-memory only, lost on restart, 5-minute fuzz. The
//! lastSeen map outlives any one request, so its keys are duped from the
//! process-lifetime page allocator, NOT the per-request arena.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const mem_meter = @import("webbox").mem_meter;
const Bus = @import("webbox").bus.Bus;

/// PresenceWindow: a markActive within this window (5 min) means online.
const window_ns: i128 = 5 * std.time.ns_per_min;

/// The lastSeen map (uid → most-recent markActive, in real-clock ns) and its
/// guard. Process-lifetime; keys are dupes owned by the metered base allocator
/// (mem_meter) so this map's growth shows up in the leak meter. Captured at
/// module level, so the route table reaches the meter's singleton: that is why
/// the meter's child has no default. It once defaulted to page_allocator, "so
/// base() is valid even before init() runs", and that mmap was the one thing
/// standing between gopher-metal and angry-gopher's real dispatch.
const gpa = mem_meter.base();
var mu: Io.Mutex = .init;
var last_seen: std.StringHashMapUnmanaged(i128) = .empty;
/// Came-online broadcasts owed (one that could not start), uid → when it
/// was last tried (metal-vmm QUEUE 177.6): kept apart from `last_seen`, so
/// an active user stays online while it is owed. Keys are `last_seen`'s.
var owed: std.StringHashMapUnmanaged(i128) = .empty;
/// How long an owed broadcast waits before it is tried again: a lasting
/// failure (the user list unreadable) is not read on every request. A test
/// sets 0 to try again at once.
pub var owed_retry_ns: i128 = 30 * std.time.ns_per_s;

fn nowNs(io: Io) i128 {
    return Io.Clock.now(.real, io).nanoseconds;
}

/// markActive bumps `uid`'s lastSeen and reports whether THIS bump was the
/// transition edge from offline to online (true on first-ever sighting OR after
/// >= PresenceWindow of inactivity). Pure state mutation — callers that need to
/// broadcast use markActiveAndBroadcast.
pub fn markActive(io: Io, uid: []const u8) bool {
    if (uid.len == 0) return false;
    const now = nowNs(io);
    mu.lockUncancelable(io);
    defer mu.unlock(io);
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

/// `uid`'s came-online edge given back, owed: a markActive after
/// `owed_retry_ns` is the edge again. Its last sighting stands, so it is
/// still online (177.6: it was set back a window, which showed an active
/// user offline).
fn unmark(io: Io, uid: []const u8) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const key = last_seen.getKey(uid) orelse return;
    owed.put(gpa, key, nowNs(io)) catch {};
}

/// isOnline reports whether `uid` was markActive'd within PresenceWindow.
/// Read-only; called by the sidebar payload to compute each partner row's
/// first-paint Online flag.
pub fn isOnline(io: Io, uid: []const u8) bool {
    if (uid.len == 0) return false;
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const v = last_seen.get(uid) orelse return false;
    return (nowNs(io) - v) < window_ns;
}

/// markActiveAndBroadcast bumps `uid` and, ONLY on the came-online edge, fans the
/// event out to every OTHER authorized user across both attention streams:
/// sidebar (the partner-row dot) + notify (the status strip + favicon flash).
/// Self is excluded. Best-effort — a failure for one recipient/surface is
/// swallowed.
pub fn markActiveAndBroadcast(io: Io, alloc: Alloc, bus: *Bus, uid: []const u8) void {
    if (!markActive(io, uid)) return;
    // **AN EDGE NOT TOLD IS NOT SPENT** (metal-vmm QUEUE 172): a broadcast
    // that cannot start gives the edge back, so the next request tries again
    // (it was lost until the user had been idle five minutes).
    // absent-ok: a best-effort online broadcast: nothing is written from it, and the edge is kept.
    const name = users.getUserName(io, alloc, uid) catch return unmark(io, uid);
    // absent-ok: the same.
    const authorized = users.listAuthorized(io, alloc) catch return unmark(io, uid);
    const text = std.fmt.allocPrint(alloc, "{s} has come online.", .{name}) catch return unmark(io, uid);

    for (authorized) |other| {
        if (std.mem.eql(u8, other.id, uid)) continue;

        // sidebar: flip the partner row's presence dot (user-online, UserID-only).
        if (store.sidebarBusKey(alloc, other.id)) |k| {
            const ev = std.fmt.allocPrint(alloc, "{{\"kind\":\"user-online\",\"user_id\":{f},\"user_name\":{f}}}", .{
                std.json.fmt(uid, .{}), std.json.fmt(name, .{}),
            }) catch continue;
            bus.publish(k, ev);
        } else |_| {}

        // notify: status strip. LinkURL = the recipient's default conv with the
        // user who came online (pair-key is per-recipient — convs sort numerically).
        if (store.notifyBusKey(alloc, other.id)) |k| {
            const pk = store.chatPairKey(alloc, other.id, uid) catch continue;
            const link = std.fmt.allocPrint(alloc, "/chat/c/{s}", .{pk}) catch continue;
            const ev = std.fmt.allocPrint(alloc, "{{\"text\":{f},\"link_url\":{f}}}", .{
                std.json.fmt(text, .{}), std.json.fmt(link, .{}),
            }) catch continue;
            bus.publish(k, ev);
        } else |_| {}
    }
}

test "presence: a broadcast that could not start leaves its user online, and a lasting failure is tried again once a while, not on every request (metal-vmm QUEUE 177.6)" {
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var hub = @import("webbox").bus.Hub.init(io, std.testing.allocator);
    defer hub.entries.deinit(std.testing.allocator);
    var bus = Bus.of(&hub);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const uid = "presence-owed-177";
    markActiveAndBroadcast(io, failing.allocator(), &bus, uid);
    // Active a moment ago: online, whatever the broadcast did.
    try std.testing.expect(isOnline(io, uid));
    // Owed, but not tried again at once: the user list is not re-read on
    // every request while the failure lasts.
    try std.testing.expect(!markActive(io, uid));
}

test "presence: a came-online edge whose broadcast could not start is not spent: the next request tries again (metal-vmm QUEUE 172)" {
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var hub = @import("webbox").bus.Hub.init(io, std.testing.allocator);
    defer hub.entries.deinit(std.testing.allocator);
    var bus = Bus.of(&hub);
    // Nothing to be had: the name, the members, the text.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const uid = "presence-edge-172";
    owed_retry_ns = 0;
    defer owed_retry_ns = 30 * std.time.ns_per_s;
    markActiveAndBroadcast(io, failing.allocator(), &bus, uid);
    // Not told to anyone, so still the edge.
    try std.testing.expect(markActive(io, uid));
}
