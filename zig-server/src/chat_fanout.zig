//! chat_fanout: a stored message, out to everyone who should see it: the
//! topic's live stream and every member's cross-page surfaces (notify, sidebar,
//! recent, images, code), each failure counted (metal-vmm QUEUE 156(c), 172;
//! split from chat_store.zig by 174).
//!
//! **THE FAN-OUT IS THE ROC'S** (roc-webbox chat/Fanout.roc, over the host's
//! `append!` in an aside and `count!`, chat_router.zig; metal-vmm QUEUE 279
//! took the last Zig writer). What stays: the bus keys the streams
//! subscribe on, and the encoders and `recentWhere` chat_twin_test.zig holds
//! the Roc's to.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// recentBusKey / imagesBusKey are the per-uid bus keys for the cross-page
/// streams. Namespaced so they can't collide with the per-conv "<key>/<sid>"
/// stream keys. Builder lives here (the publisher) so the stream handlers
/// subscribe with the SAME function — no string drift.
pub fn recentBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "rec:{s}",
        .{uid},
    );
}

pub fn imagesBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "img:{s}",
        .{uid},
    );
}

pub fn codeBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "code:{s}",
        .{uid},
    );
}

/// notifyBusKey / sidebarBusKey are the per-uid keys for the two cross-page
/// attention streams.
/// Namespaced like the recent/images/code keys so nothing collides.
pub fn notifyBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "ntf:{s}",
        .{uid},
    );
}

pub fn sidebarBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "sb:{s}",
        .{uid},
    );
}

/// convKeyBaseURL returns the URL root for a conv addressed by its storage key.
/// DM keys contain '_' (channel names exclude it), a sufficient discriminator.
pub fn convKeyBaseURL(alloc: Alloc, conv_key: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(
        u8,
        conv_key,
        '_',
    ) != null) {
        return std.fmt.allocPrint(
            alloc,
            "/chat/c/{s}",
            .{conv_key},
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "/channel/{s}",
        .{conv_key},
    );
}
