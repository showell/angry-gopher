//! presence: who's actively touching the chat subsystem RIGHT NOW (port of
//! server/chat/chat_presence.go). A user is "online" if any counted chat route
//! marked them active within the last 5 minutes. No client polling, no idle
//! detection — the server's view of "is this user touching things?" IS the
//! definition.
//!
//! Lifecycle (mirrors Go): every counted page/action route runs through
//! markActiveAndBroadcast, which bumps the user's lastSeen. On the offline→online
//! edge (first sighting OR >= PresenceWindow of inactivity) it fans a came-online
//! event to every OTHER authorized user across both attention streams — the
//! sidebar bus (the partner-row presence dot) and the notify bus (the status
//! strip). No background sweeper, no offline broadcast: a row goes gray lazily on
//! the next page render when isOnline returns false.
//!
//! In-memory only, lost on restart, 5-minute fuzz — same posture as Go's. The
//! lastSeen map outlives any one request, so its keys are duped from the
//! process-lifetime page allocator, NOT the per-request arena.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const Bus = @import("bus.zig").Bus;

/// PresenceWindow: a markActive within this window means online. Go uses 5 min.
const window_ns: i128 = 5 * std.time.ns_per_min;

/// The lastSeen map (uid → most-recent markActive, in real-clock ns) and its
/// guard. Process-lifetime; keys are page-allocator-owned dupes.
var gpa = std.heap.page_allocator;
var mu: Io.Mutex = .init;
var last_seen: std.StringHashMapUnmanaged(i128) = .empty;

fn nowNs(io: Io) i128 {
    return Io.Clock.now(.real, io).nanoseconds;
}

/// markActive bumps `uid`'s lastSeen and reports whether THIS bump was the
/// transition edge from offline to online (true on first-ever sighting OR after
/// >= PresenceWindow of inactivity). Pure state mutation — callers that need to
/// broadcast use markActiveAndBroadcast. Mirrors Go's MarkActive.
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
    return (now - prev) >= window_ns;
}

/// isOnline reports whether `uid` was markActive'd within PresenceWindow.
/// Read-only; called by the sidebar payload to compute each partner row's
/// first-paint Online flag. Mirrors Go's IsOnline.
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
/// swallowed. Mirrors Go's markActiveAndBroadcast.
pub fn markActiveAndBroadcast(io: Io, alloc: Alloc, bus: *Bus, uid: []const u8) void {
    if (!markActive(io, uid)) return;
    const name = users.getUserName(io, alloc, uid) catch return;
    const authorized = users.listAuthorized(io, alloc) catch return;
    const text = std.fmt.allocPrint(alloc, "{s} has come online.", .{name}) catch return;

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
