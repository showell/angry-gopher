//! chat_store: the on-disk chat storage layer — reading and appending transcripts
//! (1:1 DMs and channels) under chat_root ({data_dir}/chat, wired by roots.point).
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

const chat_codec = @import("chat_codec.zig");
const chatStoredForm = chat_codec.chatStoredForm;
const chat_fanout = @import("chat_fanout.zig");
const fanoutCrossPage = chat_fanout.fanoutCrossPage;
const busBlob = chat_fanout.busBlob;
const fanoutFailed = chat_fanout.fanoutFailed;
const chat_count = @import("chat_count.zig");
const writeCount = chat_count.writeCount;
pub const countPath = chat_count.countPath;
const messageCount = chat_count.messageCount;
const chat_paths = @import("chat_paths.zig");
pub const refusedText = chat_codec.refusedText;
pub const isMessage = chat_codec.isMessage;
pub const refuseBlock = chat_codec.refuseBlock;
pub const decodeChatFile = chat_codec.decodeChatFile;
pub const recentBusKey = chat_fanout.recentBusKey;
pub const imagesBusKey = chat_fanout.imagesBusKey;
pub const codeBusKey = chat_fanout.codeBusKey;
pub const notifyBusKey = chat_fanout.notifyBusKey;
pub const sidebarBusKey = chat_fanout.sidebarBusKey;
pub const convKeyBaseURL = chat_fanout.convKeyBaseURL;
pub const fanoutText = chat_fanout.fanoutText;
pub const LastMessage = chat_count.LastMessage;
pub const lastMessage = chat_count.lastMessage;
pub const backfillSidecars = chat_count.backfillSidecars;
pub const backfillAll = chat_count.backfillAll;
pub const countBlocks = chat_count.countBlocks;
pub const indexOf = chat_count.indexOf;
pub const Reach = chat_paths.Reach;
pub const visibleConvs = chat_paths.visibleConvs;
pub const listConvDirs = chat_paths.listConvDirs;
pub const dmConvDir = chat_paths.dmConvDir;
pub const channelConvDir = chat_paths.channelConvDir;
pub const sessionMdPath = chat_paths.sessionMdPath;
pub const rawSession = chat_paths.rawSession;
pub const listSessions = chat_paths.listSessions;
pub const defaultSession = chat_paths.defaultSession;
pub const channelMembers = chat_paths.channelMembers;
pub const hasMember = chat_paths.hasMember;
pub const malformedText = chat_paths.malformedText;
pub const listUserChannels = chat_paths.listUserChannels;
pub const chatKeyParticipant = chat_paths.chatKeyParticipant;
pub const chatPairKey = chat_paths.chatPairKey;
pub const validSessionID = chat_paths.validSessionID;
pub const validMsgRefID = chat_paths.validMsgRefID;
pub const validChannelName = chat_paths.validChannelName;

const std = @import("std");

const Io = @import("host_io").Io;

const Alloc = std.mem.Allocator;

const timefmt = @import("timefmt.zig");

const store = @import("webbox").store;

const bus_mod = @import("webbox").bus;

const Bus = bus_mod.Bus;

const search_index = @import("search_index.zig");

/// chat_root is {data_dir}/chat. roots.point overrides this at startup; the
/// default is repo-relative-from-zig-server like the others.
pub var chat_root: []const u8 = "../games/lynrummy/chat-data";

// No lock: a handler runs only inside the host's turn, one at a time
// (zig-metal-unikernel HOST.md), so the read-count-then-append on the write path
// and the read-backlog-then-subscribe on the stream path never interleave. That
// is what makes a message land in EITHER the backlog OR the live stream, never
// both and never neither (see appendMessage / openStream).

/// sep joins message blocks on disk: blank line, 13 hyphens, newline. A body
/// line that would collide with it is backslash-escaped (see unescapeBodyLine).
pub const sep = "\n\n-------------\n";

pub const dashes = "-------------"; // exactly 13; the collision shape

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

/// Stream is the result of openStream: the decoded backlog + a live Subscriber.
/// The caller replays backlog[since..] and holds the subscriber (`Bus.hold`),
/// which either keeps it for the host or closes it (157(a)).
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

/// openStream: inside one handler's turn, decode the session backlog
/// AND register a live subscriber on `<conv_key>/<sid>` — atomically, so no
/// message slips between "what's in the backlog" and "what the subscriber sees".
/// A message appended concurrently is delivered exactly once (backlog xor live).
pub fn openStream(io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8) !Stream {
    const path = try sessionMdPath(alloc, conv_dir, sid);
    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });

    // A session nobody has written to is genuinely empty; a session that will
    // not read is not, and showing it as empty is how a transcript looks lost.
    const raw = try store.readOrEmpty(io, alloc, path, .unlimited);
    const msgs = try decodeChatFile(alloc, raw);
    const sub = try bus.open(key);
    return .{ .backlog = msgs, .sub = sub };
}

/// appendMessage stores one message, inside one handler's turn: read the current count → the message index, encode the on-disk block
/// (with separator + body-line escaping), append it, record the count and the
/// author in the `.count`, then publish a fan-out blob to the live subscribers — all in
/// one turn, so no other handler's openStream can double- or zero-count it. Returns
/// the stored message (id + server-stamped date). NO render here: the blob
/// carries raw markdown; each stream renders per-viewer.
pub fn appendMessage(io: Io, alloc: Alloc, bus: *Bus, meta: ConvMeta, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, from_name: []const u8, from_id: []const u8, markdown: []const u8, cid: []const u8) !ChatMessage {
    // **NO MESSAGE WITHOUT AN AUTHOR** (the review of 156): the decoder
    // refuses such a block on every read, so it would go out live and be gone
    // on reload. A nameless member (a release cut short) cannot post.
    if (from_name.len == 0) return error.NoAuthor;
    const path = try sessionMdPath(alloc, conv_dir, sid);

    const index = try messageCount(io, alloc, conv_dir, sid);

    const id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ sid, index + 1 });
    const at = try timefmt.formatRFC3339UTC(alloc, nowUnix(io));
    const msg = ChatMessage{ .id = id, .from = from_name, .date = at, .markdown = markdown };

    const stored = try chatStoredForm(alloc, index, msg);
    // **THE ECHO IS MADE BEFORE THE STORE** (metal-vmm QUEUE 177.1): the live
    // publish's key and blob, so nothing can fail between the append and the
    // (void) publish. A live publish that failed after the append answered
    // success with no echo on the sender's stream, whose client then sent the
    // message again: a duplicate.
    const live_key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });
    const live_blob = try busBlob(alloc, index, from_name, at, id, cid, markdown);
    // **NO `.lastauthor`** (zig-metal-unikernel 153(1)): the `.count` carries the
    // author, and nothing reads one an older server left.
    const new_size = try store.append(io, alloc, path, stored);
    // A crash between the append and this leaves a count whose size is not the
    // transcript's — in either order — so messageCount refuses it and recounts.
    // The size check is the protection, not the ordering.
    writeCount(io, alloc, conv_dir, sid, index + 1, new_size, .{
        .offset = new_size - stored.len,
        .uid = from_id,
    });
    // **SEARCH SEES IT AS IT LANDS** (metal-vmm 155(b)): the index in memory
    // takes the message, or drops itself whole if it cannot.
    search_index.noteAppend(io, conv_dir, sid, msg);

    // **STORED IS DONE** (metal-vmm QUEUE 172): from here nothing fails the
    // send, which a client would answer by sending the message again. The
    // live publish cannot fail (it was made above); every surface after it
    // is best-effort, each failure counted and said (/admin/host).
    bus.publish(live_key, live_blob);

    // Cross-page fanout: notify + recent + images + code,
    // per member, to their per-uid bus, plus a sidebar topic-added on the
    // session's first message. Best-effort; inside the same handler's turn.
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
    return store.readOrEmpty(io, alloc, path, .unlimited);
}

/// appendReaction records one event `{msg, uid, from, emoji, on, at}` on the
/// sidecar and fans it out live on the topic's bus key, wrapped as
/// `{"reaction":<line>}` so the transcript stream can tell it from a message
/// blob. Inside one handler's turn, so `msg_num` (1-based, the N of MSG_<sid>_N) is checked
/// against the transcript's real count. Returns the stored line.
pub fn appendReaction(io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, msg_num: usize, uid: []const u8, from_name: []const u8, emoji: []const u8, on: bool) ![]const u8 {
    const count = try messageCount(io, alloc, conv_dir, sid);
    if (msg_num == 0 or msg_num > count) return error.NoSuchMessage;

    const at = try timefmt.formatRFC3339UTC(alloc, nowUnix(io));
    const line = try reactionLine(alloc, msg_num, uid, from_name, emoji, on, at);
    // The echo made before the store, as a message's (177.1).
    const live_key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });
    const live_blob = try std.fmt.allocPrint(alloc, "{{\"reaction\":{s}}}", .{line});
    _ = try store.append(io, alloc, try reactionsPath(alloc, conv_dir, sid), try std.fmt.allocPrint(alloc, "{s}\n", .{line}));

    // Stored is done (as for a message): the live publish cannot fail.
    bus.publish(live_key, live_blob);
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

/// A uid that is not known is written as this, because a field left empty would
/// make the line one field short and the whole record unreadable — which is
/// exactly the case the backfill exists for.
pub const no_uid = "-";

/// How much of the tail is read looking for the last block. A message longer
/// than this is served the old way, by reading the whole transcript.
pub const tail_window = 64 * 1024;

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

const Cut = struct { before: []const u8, after: []const u8 };

/// cutSeq splits `s` at the first `needle`, returning the parts, or null when
/// absent.
pub fn cutSeq(s: []const u8, needle: []const u8) ?Cut {
    const idx = std.mem.indexOf(u8, s, needle) orelse return null;
    return .{ .before = s[0..idx], .after = s[idx + needle.len ..] };
}

// ── conversation paths + access ─────────

const testing = std.testing;

const roots = @import("roots.zig");

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
    // Every root under the temp tree, and back after (157(c)): it set this
    // one and never put it back.
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var hub = bus_mod.Hub.init(io, a);
    var bus = Bus.of(&hub);

    const dir = try dmConvDir(a, "1_2");
    const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{} };
    _ = try appendMessage(io, a, &bus, meta, dir, "1_2", "topic", "Tester", "1", "hello world", "");

    const msgs = try decodeChatFile(a, (try rawSession(io, a, dir, "topic")).?);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("Tester", msgs[0].from);
    try testing.expectEqualStrings("hello world", msgs[0].markdown);
}

/// A store over a throwaway directory, for the count tests below. The test
/// makes the Io and hands it in: the host's thread pool may only be named inside
/// a `test {}` block (tools/lint_portable.shale).
pub const CountFixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    io: Io,
    hub: bus_mod.Hub,
    bus: Bus,
    dir: []const u8,
    saved: roots.Saved,

    pub fn init(self: *CountFixture, io: Io) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.tmp = testing.tmpDir(.{});
        // Every root under its own tree (157(c)), accounts included, empty
        // unless a test makes one: an author is looked up by name where no
        // sidecar says.
        self.saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path }));
        self.io = io;
        self.hub = bus_mod.Hub.init(io, a);
        self.bus = Bus.of(&self.hub);
        self.dir = try dmConvDir(a, "1_2");
    }

    pub fn deinit(self: *CountFixture) void {
        self.saved.restore();
        self.tmp.cleanup();
        self.arena.deinit();
    }

    pub fn send(self: *CountFixture, text: []const u8) !ChatMessage {
        const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{} };
        return appendMessage(self.io, self.arena.allocator(), &self.bus, meta, self.dir, "1_2", "topic", "Tester", "1", text, "");
    }

    pub fn decoded(self: *CountFixture) !usize {
        const a = self.arena.allocator();
        return (try decodeChatFile(a, (try rawSession(self.io, a, self.dir, "topic")).?)).len;
    }
};

test "a send that answers an error stored nothing, and one that stored answers success and is echoed: memory that runs out after the append is a counted fan-out failure (metal-vmm QUEUE 172, 177.1)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{ "1", "2" } };
    const text = "a message with <img src=\"/x.png\"> and\n\n```\ncode\n```";
    const live = try f.bus.open("1_2/topic");
    defer f.bus.close(live);
    var fail_at: usize = 0;
    var stored_one = false;
    while (fail_at < 400) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_at });
        const before = try messageCount(f.io, a, f.dir, "topic");
        const sent = appendMessage(f.io, failing.allocator(), &f.bus, meta, f.dir, "1_2", "topic", "Tester", "1", text, "");
        const after = try messageCount(f.io, a, f.dir, "topic");
        if (sent) |m| {
            try testing.expectEqual(before + 1, after);
            // **A STORED MESSAGE IS ECHOED** (metal-vmm QUEUE 177.1): the
            // sender's own stream shows it, or the client, with no echo,
            // sends it again.
            if (!echoed(live, m.id)) {
                std.debug.print("allocation {d} failed: stored, answered success, and never echoed\n", .{fail_at});
                return error.TestUnexpectedResult;
            }
            if (!failing.has_induced_failure) break; // every allocation passed
            stored_one = true;
        } else |_| {
            if (after != before) {
                std.debug.print("allocation {d} failed after the append: stored, and answered an error\n", .{fail_at});
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expect(stored_one);
}

/// Whether the subscriber has been sent a blob holding `needle` since it was
/// last drained; drains it.
fn echoed(sub: *bus_mod.Subscriber, needle: []const u8) bool {
    var found = false;
    while (sub.poll()) |blob| {
        defer sub.gpa.free(blob);
        if (std.mem.indexOf(u8, blob, needle) != null) found = true;
    }
    return found;
}

test "a reaction that answers an error stored nothing, and one that answers success is echoed (metal-vmm QUEUE 172, 177.1)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("something to react to");
    const live = try f.bus.open("1_2/topic");
    defer f.bus.close(live);
    var fail_at: usize = 0;
    while (fail_at < 100) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_at });
        const before = (try readReactions(f.io, a, f.dir, "topic")).len;
        const got = appendReaction(f.io, failing.allocator(), &f.bus, f.dir, "1_2", "topic", 1, "1", "Tester", "👍", true);
        const after = (try readReactions(f.io, a, f.dir, "topic")).len;
        if (got) |_| {
            if (!echoed(live, "\"reaction\"")) {
                std.debug.print("allocation {d} failed: stored, answered success, and never echoed\n", .{fail_at});
                return error.TestUnexpectedResult;
            }
            if (!failing.has_induced_failure) break;
        } else |_| if (after != before) {
            std.debug.print("allocation {d} failed after the append: stored, and answered an error\n", .{fail_at});
            return error.TestUnexpectedResult;
        }
    }
}
