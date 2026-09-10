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
//! Routes (DM and channel alike, dispatched by chat.topicRoute):
//!   GET  /<…>/<sid>/reactions   the sidecar bytes (ndjson; empty when none)
//!   POST /<…>/<sid>/react       form msg=<n> emoji=<glyph> on=<1|0> → 204

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const chat = @import("chat.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// A react form is three short fields; anything bigger is not a reaction.
const max_body_bytes = 1024;
/// The longest whitelisted glyph is a base character plus a variation selector
/// (7 bytes); 16 leaves room without admitting a sentence.
pub const max_emoji_bytes = 16;

/// serveFile answers GET /<…>/<sid>/reactions with the sidecar's bytes.
pub fn serveFile(req: *Request, io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req);
    const bytes = try store.readReactions(io, alloc, conv_dir, sid);
    try req.respond(bytes, .{ .extra_headers = &.{http.ndjson_ct} });
}

/// handleReact answers POST /<…>/<sid>/react: validate the three fields, append
/// the event (which fans out live), 204. Bad input is a 400 with a one-line
/// reason; `msg` beyond the transcript's count is one of them.
pub fn handleReact(req: *Request, io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, uid: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);
    const body = (try http.readLimitedBody(req, alloc, max_body_bytes)) orelse return;
    const msg_s = (try chat.formField(alloc, body, "msg")) orelse "";
    const emoji = (try chat.formField(alloc, body, "emoji")) orelse "";
    const on_s = (try chat.formField(alloc, body, "on")) orelse "1";

    const msg_num = std.fmt.parseInt(usize, msg_s, 10) catch return badRequest(req, "react: msg must be a message number\n");
    if (!validEmoji(emoji)) return badRequest(req, "react: emoji must be one glyph\n");
    const on = std.mem.eql(u8, on_s, "1");

    const from_name = try users.getUserName(io, alloc, uid);
    _ = store.appendReaction(io, alloc, bus, conv_dir, conv_key, sid, msg_num, uid, from_name, emoji, on) catch |e| switch (e) {
        error.NoSuchMessage => return badRequest(req, "react: no such message\n"),
        else => return e,
    };
    try req.respond("", .{ .status = .no_content });
}

fn badRequest(req: *Request, msg: []const u8) !void {
    try req.respond(msg, .{ .status = .bad_request });
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
