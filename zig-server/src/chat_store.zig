//! chat_store: the on-disk chat storage layer — reading and appending transcripts
//! (1:1 DMs and channels) under chat_root ({data_dir}/chat, wired by config.zig).
//! decodeChatFile parses a transcript off disk; appendMessage adds a message and
//! fans it out to live streams.
//!
//! On-disk shape:
//!   {chat_root}/<a>_<b>/sessions/<sid>.md              — a 1:1 DM transcript
//!   {chat_root}/<a>_<b>/sessions/<sid>.count           — its message count (a cache)
//!   {chat_root}/channels/<name>/sessions/<sid>.md      — a channel topic
//!   {chat_root}/channels/<name>.channel                — channel member uids
//!
//! Transcript file format: messages concatenated, joined by `sep`. Each block is
//!   MSG_<sid>_<n>\nfrom: <name>\ndate: <RFC3339>\n\n<markdown body>
//! decodeChatFile parses that, including the 13-hyphen separator-collision
//! unescape. Round-trips with the raw bytes (the /raw view serves them verbatim,
//! this decoder parses them).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const timefmt = @import("timefmt.zig");
const bus_mod = @import("bus.zig");
const Bus = bus_mod.Bus;
const users = @import("users.zig");
const recent_feed = @import("recent_feed.zig");
const images_store = @import("images_store.zig");
const code_store = @import("code_store.zig");

/// chat_root is {data_dir}/chat. config.zig overrides this at startup; the
/// default is repo-relative-from-zig-server like the others.
pub var chat_root: []const u8 = "../games/lynrummy/chat-data";

/// chat_mu serializes the read-count-then-append on the write path AND the
/// read-backlog-then-subscribe on the stream path. It's what makes a message land
/// in EITHER the backlog OR the live stream, never both and never neither (see
/// appendMessage / openStream).
var chat_mu: Io.Mutex = .init;

/// sep joins message blocks on disk: blank line, 13 hyphens, newline. A body
/// line that would collide with it is backslash-escaped (see unescapeBodyLine).
pub const sep = "\n\n-------------\n";
const dashes = "-------------"; // exactly 13; the collision shape

/// ChatMessage is one decoded block. id/from/date are slices into the source
/// buffer; markdown is freshly built (line-unescaped + rejoined). The `date` is
/// the raw RFC3339 header string, displayed as stored.
pub const ChatMessage = struct {
    id: []const u8,
    from: []const u8,
    date: []const u8,
    markdown: []const u8,
};

// ── decode ──────────────────────────────────────────────────────────────────

/// decodeChatFile parses a whole session file into messages. Splits on `sep`
/// (no trailing separator on disk, so one piece per message), skipping any
/// all-whitespace piece.
pub fn decodeChatFile(alloc: Alloc, data: []const u8) ![]ChatMessage {
    var out: std.ArrayList(ChatMessage) = .empty;
    var it = std.mem.splitSequence(u8, data, sep);
    while (it.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t\r\n").len == 0) continue;
        try out.append(alloc, try decodeChatBlock(alloc, piece));
    }
    return out.toOwnedSlice(alloc);
}

/// decodeChatBlock parses one block: a `MSG_` id line, `key: value` header lines
/// until a blank line, then the verbatim (line-unescaped) markdown body.
fn decodeChatBlock(alloc: Alloc, piece: []const u8) !ChatMessage {
    var lines: std.ArrayList([]const u8) = .empty;
    var lit = std.mem.splitScalar(u8, piece, '\n');
    while (lit.next()) |ln| try lines.append(alloc, ln);
    const ls = lines.items;

    var msg: ChatMessage = .{ .id = "", .from = "", .date = "", .markdown = "" };
    var i: usize = 0;
    if (i < ls.len and std.mem.startsWith(u8, ls[i], "MSG_")) {
        msg.id = ls[i]["MSG_".len..];
        i += 1;
    }
    while (i < ls.len) : (i += 1) {
        if (ls[i].len == 0) break; // blank line ends the header
        if (cutSeq(ls[i], ": ")) |kv| {
            if (std.mem.eql(u8, kv.before, "from")) {
                msg.from = kv.after;
            } else if (std.mem.eql(u8, kv.before, "date")) {
                msg.date = kv.after;
            }
        }
    }

    // body = lines[i+1..] (everything after the blank), each line unescaped.
    var body: std.ArrayList(u8) = .empty;
    var j = i + 1;
    var first = true;
    while (j < ls.len) : (j += 1) {
        if (!first) try body.append(alloc, '\n');
        first = false;
        try body.appendSlice(alloc, unescapeBodyLine(ls[j]));
    }
    msg.markdown = try body.toOwnedSlice(alloc);
    return msg;
}

/// unescapeBodyLine reverses the body-line escaping: a line that is one-or-more
/// backslashes followed by exactly 13 hyphens (the `^\\+-------------$` shape)
/// loses one leading backslash. Everything else passes through.
fn unescapeBodyLine(line: []const u8) []const u8 {
    var k: usize = 0;
    while (k < line.len and line[k] == '\\') k += 1;
    if (k >= 1 and std.mem.eql(u8, line[k..], dashes)) return line[1..];
    return line;
}

// ── write path + live fan-out ───────────

/// Stream is the result of openStream: the decoded backlog + a live Subscriber.
/// The caller replays backlog[since..] then drains the subscriber, and MUST pair
/// this with `bus.close(sub)` when the connection ends.
///
/// Two lifetimes deliberately bundled here — keep them straight:
///   backlog: REQUEST-scoped. Decoded into openStream's arena `alloc`; valid only
///            for this request and never stored past it (it's replayed, then dropped).
///   sub:     SERVER-scoped. Owned by the bus on its base allocator; outlives the
///            request until `bus.close(sub)` removes + frees it.
pub const Stream = struct {
    backlog: []ChatMessage, // request-arena: consume in-request, never retain
    sub: *bus_mod.Subscriber, // bus-owned (base alloc): close it, don't free piecemeal
};

/// openStream: under chat_mu, decode the session backlog
/// AND register a live subscriber on `<conv_key>/<sid>` — atomically, so no
/// message slips between "what's in the backlog" and "what the subscriber sees".
/// A message appended concurrently is delivered exactly once (backlog xor live).
pub fn openStream(io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8) !Stream {
    const path = try sessionMdPath(alloc, conv_dir, sid);
    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });

    chat_mu.lockUncancelable(io);
    defer chat_mu.unlock(io);

    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
    const msgs = try decodeChatFile(alloc, raw);
    const sub = try bus.open(key);
    return .{ .backlog = msgs, .sub = sub };
}

/// appendMessage stores one message: under
/// chat_mu, read the current count → the message index, encode the on-disk block
/// (with separator + body-line escaping), append it, write the .lastauthor
/// companion, then publish a fan-out blob to the live subscribers — all under the
/// one lock so a concurrent openStream can't double- or zero-count it. Returns
/// the stored message (id + server-stamped date). NO render here: the blob
/// carries raw markdown; each stream renders per-viewer.
pub fn appendMessage(io: Io, alloc: Alloc, bus: *Bus, meta: ConvMeta, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, from_name: []const u8, from_id: []const u8, markdown: []const u8, cid: []const u8) !ChatMessage {
    const path = try sessionMdPath(alloc, conv_dir, sid);

    chat_mu.lockUncancelable(io);
    defer chat_mu.unlock(io);

    const index = try messageCount(io, alloc, conv_dir, sid);

    const id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ sid, index + 1 });
    const at = try timefmt.formatRFC3339UTC(alloc, nowUnix(io));
    const msg = ChatMessage{ .id = id, .from = from_name, .date = at, .markdown = markdown };

    const stored = try chatStoredForm(alloc, index, msg);
    const new_size = try appendRawBytes(io, path, stored);
    // A crash between the append and this leaves a count whose size is not the
    // transcript's — in either order — so messageCount refuses it and recounts.
    // The size check is the protection, not the ordering.
    writeCount(io, alloc, conv_dir, sid, index + 1, new_size);

    // Last-author companion (best-effort).
    const la = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", try std.fmt.allocPrint(alloc, "{s}.lastauthor", .{sid}) });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = la, .data = from_id }) catch {};

    // Fan out to live subscribers on this conv/sid (best-effort).
    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });
    const blob = try busBlob(alloc, index, from_name, at, id, cid, markdown);
    bus.publish(key, blob);

    // Cross-page fanout: notify + recent + images + code,
    // per member, to their per-uid bus, plus a sidebar topic-added on the
    // session's first message. Best-effort; runs under chat_mu so the lock order
    // is chat_mu → imagesMu (leaf).
    fanoutCrossPage(io, alloc, bus, meta, conv_key, sid, msg, from_id, index);

    return msg;
}

// ── reactions sidecar ─────────────────────────────────────────────────────────

/// reactionsPath is {conv_dir}/sessions/<sid>.reactions.jsonl — the per-topic
/// reaction sidecar: one JSON event per line, append-only like the transcript
/// it sits beside, and deliberately a SEPARATE file so the transcript never
/// changes shape. Read whole by the client, which folds the events itself.
pub fn reactionsPath(alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.reactions.jsonl", .{sid});
    return std.fs.path.join(alloc, &.{ conv_dir, "sessions", file });
}

/// readReactions returns the sidecar's bytes, or "" when nobody has reacted yet.
pub fn readReactions(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]const u8 {
    const path = try reactionsPath(alloc, conv_dir, sid);
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
}

/// appendReaction records one event `{msg, uid, from, emoji, on, at}` on the
/// sidecar and fans it out live on the topic's bus key, wrapped as
/// `{"reaction":<line>}` so the transcript stream can tell it from a message
/// blob. Under chat_mu so `msg_num` (1-based, the N of MSG_<sid>_N) is checked
/// against the transcript's real count. Returns the stored line.
pub fn appendReaction(io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, msg_num: usize, uid: []const u8, from_name: []const u8, emoji: []const u8, on: bool) ![]const u8 {
    chat_mu.lockUncancelable(io);
    defer chat_mu.unlock(io);

    const count = try messageCount(io, alloc, conv_dir, sid);
    if (msg_num == 0 or msg_num > count) return error.NoSuchMessage;

    const at = try timefmt.formatRFC3339UTC(alloc, nowUnix(io));
    const line = try reactionLine(alloc, msg_num, uid, from_name, emoji, on, at);
    _ = try appendRawBytes(io, try reactionsPath(alloc, conv_dir, sid), try std.fmt.allocPrint(alloc, "{s}\n", .{line}));

    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });
    bus.publish(key, try std.fmt.allocPrint(alloc, "{{\"reaction\":{s}}}", .{line}));
    return line;
}

/// reactionLine is the ONE place the sidecar's line shape is written. `on`
/// false is a retraction: the client folds by last-event-wins per
/// (msg, uid, emoji), so the file stays append-only.
fn reactionLine(alloc: Alloc, msg_num: usize, uid: []const u8, from: []const u8, emoji: []const u8, on: bool, at: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"msg\":{d},\"uid\":{f},\"from\":{f},\"emoji\":{f},\"on\":{},\"at\":{f}}}", .{
        msg_num,                  std.json.fmt(uid, .{}), std.json.fmt(from, .{}),
        std.json.fmt(emoji, .{}), on,                     std.json.fmt(at, .{}),
    });
}

test "reactionLine is one JSON object with the six fields, strings escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try reactionLine(a, 3, "1", "Ste\"ve", "👍", false, "2026-09-10T12:00:00Z");
    try std.testing.expectEqualStrings(
        "{\"msg\":3,\"uid\":\"1\",\"from\":\"Ste\\\"ve\",\"emoji\":\"👍\",\"on\":false,\"at\":\"2026-09-10T12:00:00Z\"}",
        line,
    );
}

/// ConvKind discriminates the conversation shapes for the fanout (DM "where"
/// names the other party; channel "where" names the channel).
pub const ConvKind = enum { dm, channel };

/// ConvMeta carries what the cross-page fanout needs that the storage path
/// doesn't otherwise know: the conv kind and its member uids (recipients).
pub const ConvMeta = struct { kind: ConvKind, members: []const []const u8 };

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

/// fanoutCrossPage publishes one new message to every cross-page attention feed
///: notify (status strip), recent (Recent page), images /
/// code (per-user transcripts) per member, plus a sidebar topic-added on the
/// session's FIRST message (index == 0). Best-effort: a failure for one
/// member/surface is swallowed so it never blocks the write.
fn fanoutCrossPage(io: Io, alloc: Alloc, bus: *Bus, meta: ConvMeta, conv_key: []const u8, sid: []const u8, msg: ChatMessage, from_id: []const u8, index: usize) void {
    const base = convKeyBaseURL(alloc, conv_key) catch return;
    const rec_url = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid }) catch return;
    const excerpt = recent_feed.recentExcerpt(alloc, msg.markdown) catch "";
    const tags = images_store.extractImageTags(alloc, msg.markdown) catch &.{};
    const blocks = code_store.extractCodeBlocks(alloc, msg.markdown) catch &.{};
    const src_url = images_store.imagesSourceURL(alloc, base, msg.id) catch base;

    // notify text is viewer-invariant (rec_url is the per-conv topic URL, the
    // notify-strip link). DMs read "X sent you a message on <sid>."; channels
    // read "X posted to <key> > <sid>."
    const notify_text = (if (meta.kind == .channel)
        std.fmt.allocPrint(alloc, "{s} posted to {s} > {s}.", .{ msg.from, conv_key, sid })
    else
        std.fmt.allocPrint(alloc, "{s} sent you a message on {s}.", .{ msg.from, sid })) catch "";
    // topic-added (sidebar) — only on the session's first message; viewer-invariant.
    const topic_added = if (index == 0)
        std.fmt.allocPrint(alloc, "{{\"kind\":\"topic-added\",\"conv\":{f},\"sid\":{f},\"url\":{f}}}", .{
            std.json.fmt(conv_key, .{}), std.json.fmt(sid, .{}), std.json.fmt(rec_url, .{}),
        }) catch ""
    else
        "";

    for (meta.members) |uid| {
        // notify — every member EXCEPT the author is pinged. The favicon dot
        // means "a partner did something"; you don't notify yourself about your
        // own message (the author already sees the self-confirm via the main
        // feed echo). Skipping the author here is the real invariant — the
        // open-feed conv+session suppression in notify.js only covers the
        // currently-viewed thread, so author-skip is what keeps the dot quiet
        // when you send to a thread you're not actively staring at.
        if (!std.mem.eql(u8, uid, from_id)) {
            var nj: std.ArrayList(u8) = .empty;
            nj.print(alloc, "{{\"conv\":{f},\"session\":{f},\"text\":{f},\"link_url\":{f}}}", .{
                std.json.fmt(conv_key, .{}), std.json.fmt(sid, .{}),
                std.json.fmt(notify_text, .{}), std.json.fmt(rec_url, .{}),
            }) catch {};
            if (nj.items.len > 0) {
                if (notifyBusKey(alloc, uid)) |k| bus.publish(k, nj.items) else |_| {}
            }
        }

        // sidebar — topic-added to every member on the first message only.
        if (topic_added.len > 0) {
            if (sidebarBusKey(alloc, uid)) |k| bus.publish(k, topic_added) else |_| {}
        }

        // recent — every member sees the row (sender included). `who` renders
        // "You" for the recipient who authored it; everyone else sees the name.
        const where = recentWhere(io, alloc, meta, conv_key, uid) catch "";
        const who = if (std.mem.eql(u8, uid, from_id)) "You" else msg.from;
        var rj: std.ArrayList(u8) = .empty;
        recent_feed.encodeChatEvent(&rj, alloc, msg.date, rec_url, who, where, sid, excerpt, meta.kind == .dm) catch continue;
        if (recentBusKey(alloc, uid)) |k| bus.publish(k, rj.items) else |_| {}

        // images — only when the message carried <img> tags.
        if (tags.len > 0) {
            const e = images_store.ImagesEntry{
                .source_id = msg.id,
                .from = msg.from,
                .conv = conv_key,
                .at = msg.date,
                .images = tags,
            };
            images_store.appendImagesEntry(io, alloc, uid, e) catch continue;
            var ij: std.ArrayList(u8) = .empty;
            images_store.encodeImagesEvent(&ij, alloc, e, src_url) catch continue;
            if (imagesBusKey(alloc, uid)) |k| bus.publish(k, ij.items) else |_| {}
        }

        // code — only when the message carried fenced code blocks.
        if (blocks.len > 0) {
            const e = code_store.CodeEntry{
                .source_id = msg.id,
                .from = msg.from,
                .conv = conv_key,
                .at = msg.date,
                .blocks = blocks,
            };
            code_store.appendCodeEntry(io, alloc, uid, e) catch continue;
            var cj: std.ArrayList(u8) = .empty;
            code_store.encodeCodeEvent(&cj, alloc, e, src_url) catch continue;
            if (codeBusKey(alloc, uid)) |k| bus.publish(k, cj.items) else |_| {}
        }
    }
}

/// recentWhere is the per-recipient context label the What column reads as
/// "message <where> (<topic>)": a channel names itself ("in <name>"); a DM names
/// the OTHER party ("to <name>").
fn recentWhere(io: Io, alloc: Alloc, meta: ConvMeta, conv_key: []const u8, viewer: []const u8) ![]const u8 {
    if (meta.kind == .channel) return std.fmt.allocPrint(alloc, "in {s}", .{conv_key});
    var other: []const u8 = "";
    for (meta.members) |m| {
        if (!std.mem.eql(u8, m, viewer)) other = m;
    }
    const name = try users.getUserName(io, alloc, other);
    return std.fmt.allocPrint(alloc, "to {s}", .{name});
}

/// busBlob is the internal fan-out payload — every field a stream needs to build
/// its per-viewer wire event EXCEPT `mine` (viewer-relative) and `html` (rendered
/// per-stream from `markdown`). JSON for robustness over arbitrary markdown bytes.
fn busBlob(alloc: Alloc, index: usize, from: []const u8, at: []const u8, id: []const u8, cid: []const u8, markdown: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"index\":{d},\"from\":{f},\"at\":{f},\"id\":{f},\"cid\":{f},\"markdown\":{f}}}", .{
        index,
        std.json.fmt(from, .{}),
        std.json.fmt(at, .{}),
        std.json.fmt(id, .{}),
        std.json.fmt(cid, .{}),
        std.json.fmt(markdown, .{}),
    });
}

/// chatStoredForm is exactly what message `index` contributes to the file: its
/// block, preceded by `sep` for every message after the first.
fn chatStoredForm(alloc: Alloc, index: usize, msg: ChatMessage) ![]u8 {
    const block = try encodeChatBlock(alloc, msg);
    if (index == 0) return block;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ sep, block });
}

/// encodeChatBlock renders one message to its on-disk block: the MSG_ id line,
/// the from/date header, a blank line, then the body with each line escaped
/// against a separator collision.
fn encodeChatBlock(alloc: Alloc, msg: ChatMessage) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, msg.markdown, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try body.append(alloc, '\n');
        first = false;
        try body.appendSlice(alloc, try escapeBodyLine(alloc, line));
    }
    return std.fmt.allocPrint(alloc, "MSG_{s}\nfrom: {s}\ndate: {s}\n\n{s}", .{ msg.id, msg.from, msg.date, body.items });
}

/// escapeBodyLine protects a body line that would collide with `sep` by
/// prepending a backslash — it matches `^\\*-------------$` (ZERO or more
/// backslashes then exactly 13 hyphens). Symmetric with unescapeBodyLine.
fn escapeBodyLine(alloc: Alloc, line: []const u8) ![]const u8 {
    var k: usize = 0;
    while (k < line.len and line[k] == '\\') k += 1;
    if (std.mem.eql(u8, line[k..], dashes)) return std.fmt.allocPrint(alloc, "\\{s}", .{line});
    return line;
}

/// appendRawBytes appends `bytes` verbatim at the current end of `path` (creating
/// parents), and answers the file's size afterwards. Unlike appendTextLine it
/// adds no newline — chatStoredForm is already the exact bytes. Single
/// positional write at EOF; see the top-of-file atomicity note (chat_mu
/// serializes this process; the file is only ever appended).
fn appendRawBytes(io: Io, path: []const u8, bytes: []const u8) !u64 {
    try mkParentDirs(io, path);
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
    return st.size + bytes.len;
}

// ── the message count ─────────

/// countPath is {conv_dir}/sessions/<sid>.count — the session's message count,
/// and the transcript size it was taken at: "<count> <size>\n".
fn countPath(alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.count", .{sid});
    return std.fs.path.join(alloc, &.{ conv_dir, "sessions", file });
}

/// messageCount is how many messages a session holds — the N that numbers the
/// next one — WITHOUT reading the transcript when the count sidecar can say.
///
/// Numbering a message used to mean reading and decoding the whole transcript
/// on every send. That is cheap out of Linux's page cache and was the largest
/// cost of a send on a host without one, growing with the conversation.
///
/// **THE SIDECAR IS A CACHE; THE TRANSCRIPT IS THE TRUTH.** The count is
/// trusted only when the transcript is still the size it was taken at — one
/// stat, not a read. Anything else is recounted from the transcript: a
/// conversation from before the sidecar existed, a crash between an append and
/// its count, or the file edited by hand. The one thing a size cannot catch is
/// a rewrite to exactly the same length with a different number of messages.
fn messageCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !usize {
    const md = try sessionMdPath(alloc, conv_dir, sid);
    const size = (Io.Dir.cwd().statFile(io, md, .{}) catch return 0).size;
    if (readCount(io, alloc, conv_dir, sid)) |c| {
        if (c.size == size) return c.count;
    }
    const raw = Io.Dir.cwd().readFileAlloc(io, md, alloc, .unlimited) catch "";
    return (try decodeChatFile(alloc, raw)).len;
}

const Count = struct { count: usize, size: u64 };

/// readCount parses the sidecar, or null for anything that is not exactly
/// "<count> <size>" — a malformed sidecar is a stale one.
fn readCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) ?Count {
    const path = countPath(alloc, conv_dir, sid) catch return null;
    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64)) catch return null;
    var it = std.mem.tokenizeAny(u8, raw, " \n");
    const count = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const size = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .count = count, .size = size };
}

/// writeCount records the count. Best effort, like `.lastauthor`: a count that
/// fails to write is a count recomputed next time, never a wrong one.
fn writeCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, count: usize, size: u64) void {
    const path = countPath(alloc, conv_dir, sid) catch return;
    const text = std.fmt.allocPrint(alloc, "{d} {d}\n", .{ count, size }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

/// mkParentDirs creates the directory containing `path` (mkdir -p). No-op when
/// `path` has no directory component.
fn mkParentDirs(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| {
        try Io.Dir.cwd().createDirPath(io, d);
    }
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

const Cut = struct { before: []const u8, after: []const u8 };

/// cutSeq splits `s` at the first `needle`, returning the parts, or null when
/// absent.
fn cutSeq(s: []const u8, needle: []const u8) ?Cut {
    const idx = std.mem.indexOf(u8, s, needle) orelse return null;
    return .{ .before = s[0..idx], .after = s[idx + needle.len ..] };
}

// ── conversation paths + access ─────────

/// dmConvDir is {chat_root}/<conv>. `conv` is the already-canonical pair key
/// (e.g. "1_2"); callers gate it through chatKeyParticipant first.
pub fn dmConvDir(alloc: Alloc, conv: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ chat_root, conv });
}

/// channelConvDir is {chat_root}/channels/<name>.
pub fn channelConvDir(alloc: Alloc, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ chat_root, "channels", name });
}


/// sessionMdPath is {conv_dir}/sessions/<sid>.md.
pub fn sessionMdPath(alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.md", .{sid});
    return std.fs.path.join(alloc, &.{ conv_dir, "sessions", file });
}

/// rawSession reads a session's literal on-disk transcript bytes, or null when
/// the file is missing/unreadable.
/// The /raw view serves
/// these bytes verbatim.
pub fn rawSession(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !?[]u8 {
    const path = try sessionMdPath(alloc, conv_dir, sid);
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
}

/// listSessions returns the session ids (the `.md` basenames) under
/// {conv_dir}/sessions, sorted ascending. Missing dir → empty.
pub fn listSessions(io: Io, alloc: Alloc, conv_dir: []const u8) ![][]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions" });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const sid = entry.name[0 .. entry.name.len - ".md".len];
        try out.append(alloc, try alloc.dupe(u8, sid));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

/// defaultSession prefers "ChitChat" when present, else the alphabetically-first
/// session, else "" (empty conv).
pub fn defaultSession(io: Io, alloc: Alloc, conv_dir: []const u8) ![]const u8 {
    const sessions = try listSessions(io, alloc, conv_dir);
    for (sessions) |s| {
        if (std.mem.eql(u8, s, "ChitChat")) return s;
    }
    if (sessions.len > 0) return sessions[0];
    return "";
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── channels ───────────────────────────────────────────

/// channelMembers reads {chat_root}/channels/<name>.channel: one uid per line,
/// blank/`#`-comment lines skipped. Missing file → null (the channel does not
/// exist).
pub fn channelMembers(io: Io, alloc: Alloc, name: []const u8) !?[][]const u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.channel", .{name});
    const path = try std.fs.path.join(alloc, &.{ chat_root, "channels", file });
    const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(alloc, line);
    }
    return try out.toOwnedSlice(alloc);
}

/// hasMember reports whether `uid` is in `members`.
pub fn hasMember(members: [][]const u8, uid: []const u8) bool {
    for (members) |m| {
        if (std.mem.eql(u8, m, uid)) return true;
    }
    return false;
}

/// listUserChannels returns the names of channels `uid` is a member of, sorted.
/// Scans {chat_root}/channels/*.channel. Missing dir → empty.
pub fn listUserChannels(io: Io, alloc: Alloc, uid: []const u8) ![][]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ chat_root, "channels" });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".channel")) continue;
        const name = entry.name[0 .. entry.name.len - ".channel".len];
        const members = (try channelMembers(io, alloc, name)) orelse continue;
        if (!hasMember(members, uid)) continue;
        try out.append(alloc, try alloc.dupe(u8, name));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

// ── validators / access ──────────────────────────────

/// chatKeyParticipant reports whether `user` participates in DM key `key`
/// ("<a>_<b>"). The key must be canonical (smaller numeric id first) — a
/// non-canonical or malformed key is rejected.
pub fn chatKeyParticipant(alloc: Alloc, key: []const u8, user: []const u8) !bool {
    const cut = cutSeq(key, "_") orelse return false;
    const x = cut.before;
    const y = cut.after;
    if (x.len == 0 or y.len == 0) return false;
    if (std.mem.indexOfScalar(u8, y, '_') != null) return false; // exactly one '_'
    const canon = try chatPairKey(alloc, x, y);
    if (!std.mem.eql(u8, canon, key)) return false;
    return std.mem.eql(u8, user, x) or std.mem.eql(u8, user, y);
}

/// chatPairKey is the canonical DM key: the smaller numeric id first, joined by
/// '_'.
pub fn chatPairKey(alloc: Alloc, a: []const u8, b: []const u8) ![]u8 {
    return if (atoiOr0(a) <= atoiOr0(b))
        std.fmt.allocPrint(alloc, "{s}_{s}", .{ a, b })
    else
        std.fmt.allocPrint(alloc, "{s}_{s}", .{ b, a });
}

fn atoiOr0(s: []const u8) i64 {
    return std.fmt.parseInt(i64, s, 10) catch 0;
}

/// validSessionID matches `^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$`
/// in 1..80 chars — alphanumerics joined by single hyphens, no leading/trailing/
/// double hyphen, no underscore/dot/slash. Doubles as the path-traversal guard
/// for any sid that flows into a sessions/<sid> filesystem path.
pub fn validSessionID(sid: []const u8) bool {
    if (sid.len == 0 or sid.len > 80) return false;
    if (sid[0] == '-' or sid[sid.len - 1] == '-') return false;
    var prev_hyphen = false;
    for (sid) |c| {
        if (c == '-') {
            if (prev_hyphen) return false; // no double hyphen
            prev_hyphen = true;
        } else if (isAlnum(c)) {
            prev_hyphen = false;
        } else {
            return false;
        }
    }
    return true;
}

/// validMsgRefID matches `^[A-Za-z0-9-]+_[0-9]+$` — a session slug, an
/// underscore, a decimal message index. The canonical message-ref id check,
/// shared by the /chat/msg/<id> lookup and reading_list's saved-ref parse (and a
/// path guard for the embedded sid). One home so the two can't drift.
pub fn validMsgRefID(id: []const u8) bool {
    const cut = std.mem.lastIndexOfScalar(u8, id, '_') orelse return false;
    const left = id[0..cut];
    const right = id[cut + 1 ..];
    if (left.len == 0 or right.len == 0) return false;
    for (left) |c| {
        if (!isAlnum(c) and c != '-') return false;
    }
    for (right) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// validChannelName matches `^[A-Za-z][A-Za-z0-9-]{0,39}$`
/// — a letter, then up to 39 of letter/digit/hyphen (1..40 chars total).
pub fn validChannelName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    if (!isAlpha(name[0])) return false;
    for (name[1..]) |c| {
        if (!isAlnum(c) and c != '-') return false;
    }
    return true;
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

const testing = std.testing;

test "validMsgRefID: accepts slug_index, rejects everything off-shape" {
    // canonical shapes (DM date-sid, channel word-sid, hyphenated sid)
    try testing.expect(validMsgRefID("2026-05-28_5"));
    try testing.expect(validMsgRefID("general1_3"));
    try testing.expect(validMsgRefID("smoke-dm-topic_12"));
    // off-shape: no underscore, empty halves, non-digit index, trailing junk
    try testing.expect(!validMsgRefID("nodigits"));
    try testing.expect(!validMsgRefID("yo_"));
    try testing.expect(!validMsgRefID("_5"));
    try testing.expect(!validMsgRefID("yo_5x"));
    try testing.expect(!validMsgRefID("yo_5_"));
    try testing.expect(!validMsgRefID(""));
}

test "fs: a posted message round-trips through the store (real Io over a temp dir)" {
    // The shape lib/std uses to test its own file I/O (cf. the std.Io writer
    // tests): hand the real code a real Io over a throwaway directory and assert
    // on the bytes that come back. Ours mints its own Io.Threaded instead of
    // borrowing std.testing.io — a reminder the io is just a value you can make.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    chat_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var bus = Bus.init(io, a);

    const dir = try dmConvDir(a, "1_2");
    const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{} };
    _ = try appendMessage(io, a, &bus, meta, dir, "1_2", "topic", "Tester", "1", "hello world", "");

    const msgs = try decodeChatFile(a, (try rawSession(io, a, dir, "topic")).?);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("Tester", msgs[0].from);
    try testing.expectEqualStrings("hello world", msgs[0].markdown);
}

/// A store over a throwaway directory, for the count tests below.
const CountFixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    bus: Bus,
    dir: []const u8,

    fn init(self: *CountFixture) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.tmp = testing.tmpDir(.{});
        chat_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        self.threaded = std.Io.Threaded.init(a, .{});
        self.bus = Bus.init(self.threaded.io(), a);
        self.dir = try dmConvDir(a, "1_2");
    }

    fn deinit(self: *CountFixture) void {
        self.threaded.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn send(self: *CountFixture, text: []const u8) !ChatMessage {
        const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{} };
        return appendMessage(self.threaded.io(), self.arena.allocator(), &self.bus, meta, self.dir, "1_2", "topic", "Tester", "1", text, "");
    }

    fn sidecar(self: *CountFixture) !?[]u8 {
        const a = self.arena.allocator();
        return Io.Dir.cwd().readFileAlloc(self.threaded.io(), try countPath(a, self.dir, "topic"), a, .limited(64)) catch null;
    }

    fn setSidecar(self: *CountFixture, text: []const u8) !void {
        const a = self.arena.allocator();
        try Io.Dir.cwd().writeFile(self.threaded.io(), .{ .sub_path = try countPath(a, self.dir, "topic"), .data = text });
    }

    fn transcriptSize(self: *CountFixture) !u64 {
        const a = self.arena.allocator();
        return (try Io.Dir.cwd().statFile(self.threaded.io(), try sessionMdPath(a, self.dir, "topic"), .{})).size;
    }

    fn decoded(self: *CountFixture) !usize {
        const a = self.arena.allocator();
        return (try decodeChatFile(a, (try rawSession(self.threaded.io(), a, self.dir, "topic")).?)).len;
    }
};

test "count: every send records the count and the transcript size it was taken at" {
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..5) |_| _ = try f.send("hello");
    const a = f.arena.allocator();
    const want = try std.fmt.allocPrint(a, "5 {d}\n", .{try f.transcriptSize()});
    try testing.expectEqualStrings(want, (try f.sidecar()).?);
    try testing.expectEqual(@as(usize, 5), try f.decoded());
}

test "count: ids stay consecutive, and agree with the transcript's own numbering" {
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (1..8) |n| {
        const m = try f.send("x");
        const want = try std.fmt.allocPrint(f.arena.allocator(), "topic_{d}", .{n});
        try testing.expectEqualStrings(want, m.id);
    }
}

test "count: a conversation from before the sidecar is counted from its transcript" {
    // Prod has every existing conversation in this state on the first deploy.
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..3) |_| _ = try f.send("old");
    const a = f.arena.allocator();
    try Io.Dir.cwd().deleteFile(f.threaded.io(), try countPath(a, f.dir, "topic"));
    const m = try f.send("new");
    try testing.expectEqualStrings("topic_4", m.id);
    try testing.expect((try f.sidecar()) != null);
}

test "count: a count taken at another size is not believed" {
    // A crash between the append and its count leaves exactly this: a count
    // one short, recorded at the transcript's previous size.
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..4) |_| _ = try f.send("x");
    try f.setSidecar("3 1\n");
    const m = try f.send("after the crash");
    try testing.expectEqualStrings("topic_5", m.id);
}

test "count: a sidecar that does not parse is a stale one" {
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..2) |_| _ = try f.send("x");
    for ([_][]const u8{ "", "banana", "2", "2 x", "2 10 extra", "-1 10" }) |junk| {
        try f.setSidecar(junk);
        const before = try f.decoded();
        const m = try f.send("x");
        const want = try std.fmt.allocPrint(f.arena.allocator(), "topic_{d}", .{before + 1});
        try testing.expectEqualStrings(want, m.id);
    }
}

test "count: a sidecar at the RIGHT size is believed — the transcript is not read" {
    // The point of the sidecar, pinned: when size agrees, the count is taken
    // as written. (This is also the documented blind spot: a rewrite to the
    // same length would go unnoticed.)
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..2) |_| _ = try f.send("x");
    const a = f.arena.allocator();
    try f.setSidecar(try std.fmt.allocPrint(a, "41 {d}\n", .{try f.transcriptSize()}));
    const m = try f.send("x");
    try testing.expectEqualStrings("topic_42", m.id);
}

test "count: a reaction is checked against the count" {
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..2) |_| _ = try f.send("x");
    const io = f.threaded.io();
    const a = f.arena.allocator();
    _ = try appendReaction(io, a, &f.bus, f.dir, "1_2", "topic", 2, "1", "Tester", "+1", true);
    try testing.expectError(error.NoSuchMessage, appendReaction(io, a, &f.bus, f.dir, "1_2", "topic", 3, "1", "Tester", "+1", true));
    try testing.expectError(error.NoSuchMessage, appendReaction(io, a, &f.bus, f.dir, "1_2", "topic", 0, "1", "Tester", "+1", true));
}

test "count: an empty conversation has none, and its first message is number one" {
    var f: CountFixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), try messageCount(f.threaded.io(), f.arena.allocator(), f.dir, "topic"));
    const m = try f.send("first");
    try testing.expectEqualStrings("topic_1", m.id);
}
