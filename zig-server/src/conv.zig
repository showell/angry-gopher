//! conv: the resolved-conversation domain types shared by the chat dispatcher
//! (chat.zig) and the page renderer (chat_page.zig). A Conv/Topic is produced
//! once by routing — where the dm/channel distinction is concrete — then travels
//! as data, so neither side has to re-discriminate the kind.

const std = @import("std");
const store = @import("chat_store.zig");

/// Conv is a resolved, access-checked conversation: the kind+members the fanout
/// needs (`meta`), plus the URL/storage coordinates every per-conv handler shares.
/// convRoute (DM) and handleChannel (channel) each build one once the viewer's
/// access is confirmed — that's where the dm/channel knowledge is concrete, so it
/// gets earned exactly once and travels as data from there on.
pub const Conv = struct {
    meta: store.ConvMeta, // kind + member uids — the single source of `kind`
    key: []const u8, // pair key "a_b" (DM) or channel name
    base: []const u8, // URL base: /chat/c/<key> or /channel/<key>
    dir: []const u8, // on-disk conv dir

    /// Whether this conv remembers the viewer's spot (the /chat/default resume
    /// pointer). DMs do; channels don't. Call sites ask this question by name
    /// instead of re-testing the kind — the predicate is what they actually mean.
    pub fn persistsCursor(self: Conv) bool {
        return self.meta.kind == .dm;
    }
};

/// Topic is a Conv plus a validated session id and its page title — the unit the
/// per-topic tail (topicRoute and below) operates on.
pub const Topic = struct { conv: Conv, sid: []const u8, title: []const u8 };
