//! reactions: emoji reactions on chat messages — the HTTP edge.
//!
//! Storage is a per-topic sidecar beside the transcript,
//! `sessions/<sid>.reactions.jsonl`: one event per line, append-only, so the
//! transcript itself never changes shape (chat_store owns the bytes, the lock
//! and the line format). The server never folds the events: GET ships the
//! file as-is, a POST appends one line and fans it out live on the topic's
//! stream as an `event: reaction`, and the CLIENT marries lines to bubbles
//! (chat/chat_reactions.js). The emoji whitelist is the client's too
//! (chat/chat_emoji.js) — here we check only that a reaction has the SHAPE of
//! one glyph.
//!
//! Routes (DM and channel alike), the Roc's since C4 (roc-webbox
//! chat/main.roc `act!`): what is here is the form's twin and the old
//! store's part, the oracles the Roc is held to.
//!   GET  /<…>/<sid>/reactions   the sidecar bytes (ndjson; empty when none)
//!   POST /<…>/<sid>/react       form msg=<n> emoji=<glyph> on=<1|0> → 204

const std = @import("std");
const Now = @import("request_time.zig").Now;
const decimal = @import("decimal.zig");
const limits = @import("limits.zig");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const users = @import("users.zig");
const store = @import("chat_store.zig");
const Bus = @import("webbox").bus.Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// A react form is three short fields; anything bigger is not a reaction.
pub const max_body_bytes = limits.body.reaction;
/// The longest whitelisted glyph is a base character plus a variation selector
/// (7 bytes); 16 leaves room without admitting a sentence.
pub const max_emoji_bytes = 16;

/// A reaction as its form says it.
pub const Reacted = struct { msg: usize, emoji: []const u8, on: bool };

/// The react form's answer: a reaction, or why not (a 400's one line).
pub const ReactForm = union(enum) { reacted: Reacted, bad: []const u8 };

/// **WHAT THE REACT FORM SAYS**, judged before anything is stored: every
/// field read first (a malformed one is `error.MalformedForm`, whichever it
/// is), then `msg` a message number, `emoji` one glyph, `on` "1" (or absent)
/// to add it and anything else to take it back. Roc's twin: roc-webbox
/// chat/Reaction.roc.
pub fn parseReactForm(alloc: Alloc, body: []const u8) !ReactForm {
    const msg_s = (try http.formField(alloc, body, "msg")) orelse "";
    const emoji = (try http.formField(alloc, body, "emoji")) orelse "";
    const on_s = (try http.formField(alloc, body, "on")) orelse "1";
    const msg = decimal.parseInt(usize, msg_s) orelse return .{ .bad = "react: msg must be a message number\n" };
    if (!validEmoji(emoji)) return .{ .bad = "react: emoji must be one glyph\n" };
    return .{ .reacted = .{ .msg = msg, .emoji = emoji, .on = std.mem.eql(u8, on_s, "1") } };
}

/// **THE STORE'S PART OF A REACTION, AS THE OLD ZIG DID IT**: the author's
/// name looked up, the line appended and sent live, or no such message in
/// the topic. The twins' oracle (chat_actions_twin.zig); the router's are
/// the Roc's (roc-webbox chat/main.roc `reacted!`).
pub fn storeReaction(io: Io, alloc: Alloc, bus: *Bus, topic: store.TopicAddress, uid: []const u8, now: Now, r: Reacted) !enum { stored, no_such_message } {
    const from_name = try users.getUserName(io, alloc, uid);
    _ = store.appendReaction(io, alloc, bus, now, topic, r.msg, .{ .name = from_name, .id = uid }, r.emoji, r.on) catch |e| switch (e) {
        error.NoSuchMessage => return .no_such_message,
        else => return e,
    };
    return .stored;
}

/// validEmoji: the SHAPE of one emoji glyph — 1..16 bytes of valid UTF-8 with
/// no ASCII byte at all. Every emoji codepoint is above U+2000, and so are the
/// variation selector and ZWJ, so this rejects names, digits, spaces, controls
/// and quotes without the server knowing the client's whitelist.
pub fn validEmoji(s: []const u8) bool {
    if (s.len == 0 or s.len > max_emoji_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    for (s) |c| if (c < 0x80) return false;
    return true;
}

const testing = std.testing;

test "validEmoji accepts one glyph, with or without a variation selector" {
    try testing.expect(validEmoji("👍"));
    try testing.expect(validEmoji("❤️")); // U+2764 U+FE0F
    try testing.expect(validEmoji("💯"));
}

test "validEmoji rejects empty, ASCII, mixed, overlong and invalid UTF-8" {
    try testing.expect(!validEmoji(""));
    try testing.expect(!validEmoji("thumbsup"));
    try testing.expect(!validEmoji(":100:"));
    try testing.expect(!validEmoji("👍 "));
    try testing.expect(!validEmoji("👍\n"));
    try testing.expect(!validEmoji("\"👍\""));
    try testing.expect(!validEmoji("👍👍👍👍👍")); // 20 bytes
    try testing.expect(!validEmoji("\xf0\x9f\x91")); // truncated sequence
}
