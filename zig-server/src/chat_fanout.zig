//! chat_fanout: a stored message, out to everyone who should see it: the
//! topic's live stream and every member's cross-page surfaces (notify, sidebar,
//! recent, images, code), each failure counted (metal-vmm QUEUE 156(c), 172;
//! split from chat_store.zig by 174).
//!
//! **THE FAN-OUT IS THE ROC'S** (roc-webbox chat/Fanout.roc, over the host's
//! `append_entry!` and `report_fanout_failure!`, chat_router.zig; metal-vmm
//! QUEUE 279 took the last Zig writer). What stays: the bus keys the streams
//! subscribe on, the encoders and `recentWhere` chat_twin_test.zig holds the
//! Roc's to, and the count of failures and the last one, the process's,
//! said on /admin/host.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const Now = @import("request_time.zig").Now;
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const bus_mod = @import("webbox").bus;
const Bus = bus_mod.Bus;
const users = @import("users.zig");
const recent_feed = @import("recent_feed.zig");
const images_store = @import("images_store.zig");
const code_store = @import("code_store.zig");
const testing = std.testing;
const chat_store = @import("chat_store.zig");
const ChatMessage = chat_store.ChatMessage;
const CountFixture = chat_store.CountFixture;
const ConvMeta = chat_store.ConvMeta;

/// recentBusKey / imagesBusKey are the per-uid bus keys for the cross-page
/// streams. Namespaced so they can't collide with the per-conv "<key>/<sid>"
/// stream keys. Builder lives here (the publisher) so the stream handlers
/// subscribe with the SAME function — no string drift.
pub fn recentBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "rec:{s}", .{uid});
}

pub fn imagesBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "img:{s}", .{uid});
}

pub fn codeBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "code:{s}", .{uid});
}

/// notifyBusKey / sidebarBusKey are the per-uid keys for the two cross-page
/// attention streams.
/// Namespaced like the recent/images/code keys so nothing collides.
pub fn notifyBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "ntf:{s}", .{uid});
}

pub fn sidebarBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "sb:{s}", .{uid});
}

/// convKeyBaseURL returns the URL root for a conv addressed by its storage key.
/// DM keys contain '_' (channel names exclude it), a sufficient discriminator.
pub fn convKeyBaseURL(alloc: Alloc, conv_key: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, conv_key, '_') != null) {
        return std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv_key});
    }
    return std.fmt.allocPrint(alloc, "/channel/{s}", .{conv_key});
}

/// The fan-out's failures since boot: a surface that failed for one member
/// (metal-vmm QUEUE 156(c)). Said on /admin/host (`fanoutText`), with the
/// last one named: the route table has no stderr of its own.
pub var fanout_failures: usize = 0;

var fanout_last_buf: [192]u8 = undefined;

var fanout_last: []const u8 = "";

/// A fan-out step that failed, counted and said.
pub fn fanoutFailed(surface: []const u8, who: []const u8, e: anyerror, conv_key: []const u8, sid: []const u8) void {
    fanout_failures += 1;
    fanout_last = std.fmt.bufPrint(&fanout_last_buf, "{s} for member {s}, {s}, on {s}/{s}", .{ surface, who, @errorName(e), conv_key, sid }) catch surface;
}

/// The fan-out's failures as /admin/host shows them.
pub fn fanoutText(alloc: Alloc) ![]const u8 {
    if (fanout_failures == 0) return "none";
    return std.fmt.allocPrint(alloc, "{d}; the last: {s}", .{ fanout_failures, fanout_last });
}

/// The notify strip's line: DMs read "X sent you a message on <sid>.";
/// channels read "X posted to <key> > <sid>.".
pub fn notifyText(alloc: Alloc, kind: chat_store.ConvKind, from: []const u8, conv_key: []const u8, sid: []const u8) Alloc.Error![]const u8 {
    return if (kind == .channel)
        std.fmt.allocPrint(alloc, "{s} posted to {s} > {s}.", .{ from, conv_key, sid })
    else
        std.fmt.allocPrint(alloc, "{s} sent you a message on {s}.", .{ from, sid });
}

/// The notify stream's event (`ntf:<uid>`).
pub fn notifyEvent(alloc: Alloc, conv_key: []const u8, sid: []const u8, text: []const u8, url: []const u8) Alloc.Error![]const u8 {
    return std.fmt.allocPrint(alloc, "{{\"conv\":{f},\"session\":{f},\"text\":{f},\"link_url\":{f}}}", .{
        std.json.fmt(conv_key, .{}), std.json.fmt(sid, .{}),
        std.json.fmt(text, .{}),     std.json.fmt(url, .{}),
    });
}

/// The sidebar stream's topic-added (`sb:<uid>`), a topic's first message.
pub fn topicAddedEvent(alloc: Alloc, conv_key: []const u8, sid: []const u8, url: []const u8) Alloc.Error![]const u8 {
    return std.fmt.allocPrint(alloc, "{{\"kind\":\"topic-added\",\"conv\":{f},\"sid\":{f},\"url\":{f}}}", .{
        std.json.fmt(conv_key, .{}), std.json.fmt(sid, .{}), std.json.fmt(url, .{}),
    });
}

/// recentWhere is the per-recipient context label the What column reads as
/// "message <where> (<topic>)": a channel names itself ("in <name>"); a DM names
/// the OTHER party ("to <name>").
pub fn recentWhere(io: Io, alloc: Alloc, meta: ConvMeta, conv_key: []const u8, viewer: []const u8) ![]const u8 {
    if (meta.kind == .channel) return std.fmt.allocPrint(alloc, "in {s}", .{conv_key});
    var other: []const u8 = "";
    for (meta.members) |m| {
        if (!std.mem.eql(u8, m, viewer)) other = m;
    }
    const name = try users.getUserName(io, alloc, other);
    return std.fmt.allocPrint(alloc, "to {s}", .{name});
}
