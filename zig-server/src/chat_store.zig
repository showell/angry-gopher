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
//!   MSG_<sid>_<n>\nfrom: <name>\ndate: <RFC3339>\nuid: <uid>\n\n<markdown body>
//! (`uid:` only on blocks written since it was added; a reader takes the
//! header lines it knows and passes over the rest, so a server from before it
//! reads these blocks as it always read blocks.)
//! decodeChatFile parses that, including the 13-hyphen separator-collision
//! unescape. Round-trips with the raw bytes (the /raw view serves them verbatim,
//! this decoder parses them).

const chat_codec = @import("chat_codec.zig");
const chatStoredForm = chat_codec.chatStoredForm;
const chat_fanout = @import("chat_fanout.zig");
const fanoutCrossPage = chat_fanout.fanoutCrossPage;
const chat_frame = @import("chat_frame.zig");
const fanoutFailed = chat_fanout.fanoutFailed;
const chat_count = @import("chat_count.zig");
const writeCount = chat_count.writeCount;
const messageCount = chat_count.messageCount;
const chat_paths = @import("chat_paths.zig");
const decodeChatFile = chat_codec.decodeChatFile;
const indexOf = chat_count.indexOf;
const dmConvDir = chat_paths.dmConvDir;
const transcriptPath = chat_paths.transcriptPath;
const readTranscript = chat_paths.readTranscript;

const std = @import("std");
const Now = @import("request_time.zig").Now;

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

/// ChatMessage is one decoded block. id/from/at/uid are slices into the
/// source buffer; markdown is freshly built (line-unescaped + rejoined). `at`
/// is when it was sent: the raw RFC3339 of the block's `date:` header,
/// displayed as stored. The code says `at` everywhere, as the frames, the
/// reactions and the feeds do; only the transcript's header, and the search
/// results' JSON, say `date`.
///
/// **WHO WROTE IT IS `uid`**, the author's account; `from` is the name they
/// had when they wrote it, shown as written. A block from before `uid:` was
/// written has none (""): who wrote it is known only by that name.
pub const ChatMessage = struct {
    id: []const u8,
    from: []const u8,
    at: []const u8,
    markdown: []const u8,
    uid: []const u8 = "",
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

/// openStream: inside one handler's turn, decode the topic backlog
/// AND register a live subscriber on `<conv_key>/<sid>` — atomically, so no
/// message slips between "what's in the backlog" and "what the subscriber sees".
/// A message appended concurrently is delivered exactly once (backlog xor live).
pub fn openStream(io: Io, alloc: Alloc, bus: *Bus, topic: TopicAddress) !Stream {
    const path = try transcriptPath(alloc, topic.dir, topic.sid);
    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ topic.key, topic.sid });

    // A topic nobody has written to is genuinely empty; a topic that will
    // not read is not, and showing it as empty is how a transcript looks lost.
    const raw = try store.readOrEmpty(io, alloc, path, .unlimited);
    const msgs = try decodeChatFile(alloc, raw);
    const sub = try bus.open(key);
    return .{ .backlog = msgs, .sub = sub };
}

/// appendMessage stores one message, inside one handler's turn: read the current count → the message index, encode the on-disk block
/// (with separator + body-line escaping), append it, record the count and the
/// author in the `.count`, then publish the message's frame to the live subscribers — all in
/// one turn, so no other handler's openStream can double- or zero-count it. Returns
/// the stored message (id + server-stamped date). **THE RENDER IS HERE, ONCE**
/// (chat_frame.zig): the published blob is the finished SSE frame, the same
/// for every viewer, which each open stream writes as it is.
pub fn appendMessage(io: Io, alloc: Alloc, bus: *Bus, now: Now, meta: ConvMeta, topic: TopicAddress, from: Author, markdown: []const u8, cid: []const u8) !ChatMessage {
    // **NO MESSAGE WITHOUT AN AUTHOR** (the review of 156): the decoder
    // refuses such a block on every read, so it would go out live and be gone
    // on reload. A nameless member (a release cut short) cannot post.
    if (from.name.len == 0) return error.NoAuthor;
    const path = try transcriptPath(alloc, topic.dir, topic.sid);

    const index = try messageCount(io, alloc, topic.dir, topic.sid);

    const id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ topic.sid, index + 1 });
    const at = try timefmt.formatRFC3339UTC(alloc, now.unixSecs());
    const msg = ChatMessage{ .id = id, .from = from.name, .at = at, .markdown = markdown, .uid = from.id };

    const stored = try chatStoredForm(alloc, index, msg);
    // **THE ECHO IS MADE BEFORE THE STORE** (metal-vmm QUEUE 177.1): the live
    // publish's key and blob, so nothing can fail between the append and the
    // (void) publish. A live publish that failed after the append answered
    // success with no echo on the sender's stream, whose client then sent the
    // message again: a duplicate.
    const live_key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ topic.key, topic.sid });
    const live_blob = try chat_frame.messageFrame(alloc, .{ .index = index, .from = from.name, .from_uid = from.id, .at = at, .id = id, .markdown = markdown, .cid = cid });
    // **NO `.lastauthor`** (zig-metal-unikernel 153(1)): the `.count` carries the
    // author, and nothing reads one an older server left.
    const new_size = try store.append(io, alloc, path, stored);
    // A crash between the append and this leaves a count whose size is not the
    // transcript's — in either order — so messageCount refuses it and recounts.
    // The size check is the protection, not the ordering.
    writeCount(io, alloc, topic.dir, topic.sid, index + 1, new_size, .{
        .offset = new_size - stored.len,
        .uid = from.id,
    });
    // **SEARCH SEES IT AS IT LANDS** (metal-vmm 155(b)): the index in memory
    // takes the message, or drops itself whole if it cannot.
    search_index.noteAppend(io, topic.dir, topic.sid, msg);

    // **STORED IS DONE** (metal-vmm QUEUE 172): from here nothing fails the
    // send, which a client would answer by sending the message again. The
    // live publish cannot fail (it was made above); every surface after it
    // is best-effort, each failure counted and said (/admin/host).
    bus.publish(live_key, live_blob);

    // Cross-page fanout: notify + recent + images + code,
    // per member, to their per-uid bus, plus a sidebar topic-added on the
    // topic's first message. Best-effort; inside the same handler's turn.
    fanoutCrossPage(io, alloc, bus, meta, topic.key, topic.sid, msg, from.id, index);

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
/// sidecar and fans it out live on the topic's bus key as its finished
/// `event: reaction` frame (chat_frame.reactionFrame), the line verbatim.
/// Inside one handler's turn, so `msg_num` (1-based, the N of MSG_<sid>_N) is
/// checked against the transcript's real count. Returns the stored line.
pub fn appendReaction(io: Io, alloc: Alloc, bus: *Bus, now: Now, topic: TopicAddress, msg_num: usize, from: Author, emoji: []const u8, on: bool) ![]const u8 {
    const count = try messageCount(io, alloc, topic.dir, topic.sid);
    if (msg_num == 0 or msg_num > count) return error.NoSuchMessage;

    const at = try timefmt.formatRFC3339UTC(alloc, now.unixSecs());
    const line = try reactionLine(alloc, msg_num, from.id, from.name, emoji, on, at);
    // The echo made before the store, as a message's (177.1).
    const live_key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ topic.key, topic.sid });
    const live_blob = try chat_frame.reactionFrame(alloc, line);
    const path = try reactionsPath(alloc, topic.dir, topic.sid);
    // **A TORN LINE STAYS ITS OWN LINE**: an append a stop cut short leaves a
    // line with no newline, and the next one glued to it is one line that
    // reads as neither (the client drops a line it cannot parse): two events
    // lost where one was. So a sidecar that does not end in a newline gets one
    // first. Read before the store, so a read that fails stores nothing.
    const lead = if (try endsMidLine(io, alloc, path)) "\n" else "";
    _ = try store.append(io, alloc, path, try std.fmt.allocPrint(alloc, "{s}{s}\n", .{ lead, line }));

    // Stored is done (as for a message): the live publish cannot fail.
    bus.publish(live_key, live_blob);
    return line;
}

/// Whether the file at `path` has bytes and its last is not a newline: an
/// append that was cut short. No file, or an empty one, is not.
fn endsMidLine(io: Io, alloc: Alloc, path: []const u8) !bool {
    const st = (try store.statOrNull(io, alloc, path)) orelse return false;
    if (st.size == 0) return false;
    var last: [1]u8 = undefined;
    if (try store.readAt(io, alloc, path, st.size - 1, &last) != 1) return error.ShortRead;
    return last[0] != '\n';
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

/// **WHERE A TOPIC IS**, as the store and the bus find it: its conversation's
/// folder (`dir`), its conversation's key (`key`, the first half of the
/// topic's bus key `<key>/<sid>`), and its id (`sid`). Not chat_conv.Topic,
/// the routed topic a handler holds (its conversation, id and title), from
/// which this is made.
pub const TopicAddress = struct { dir: []const u8, key: []const u8, sid: []const u8 };

/// Who writes: the display name stored with the message, and the uid.
pub const Author = struct { name: []const u8, id: []const u8 };

/// ConvKind discriminates the conversation shapes for the fanout (DM "where"
/// names the other party; channel "where" names the channel).
pub const ConvKind = enum { dm, channel };

/// ConvMeta carries what the cross-page fanout needs that the storage path
/// doesn't otherwise know: the conv kind and its member uids (recipients),
/// each once.
pub const ConvMeta = struct {
    kind: ConvKind,
    members: []const []const u8,

    /// A DM between `a` and `b`. **EACH PERSON ONCE**: in the DM with
    /// yourself (`1_1`) the two are one, and listed twice they were sent
    /// every notice twice and had every image and code block written to
    /// their images.md and code.md twice.
    pub fn dm(alloc: Alloc, a: []const u8, b: []const u8) !ConvMeta {
        const members = try alloc.alloc([]const u8, if (std.mem.eql(u8, a, b)) 1 else 2);
        members[0] = a;
        if (members.len == 2) members[1] = b;
        return .{ .kind = .dm, .members = members };
    }
};

/// A uid that is not known is written as this, because a field left empty would
/// make the line one field short and the whole record unreadable — which is
/// exactly the case the backfill exists for.
pub const no_uid = "-";

/// How much of the tail is read looking for the last block. A message longer
/// than this is served the old way, by reading the whole transcript.
pub const tail_window = 64 * 1024;

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
    _ = try appendMessage(io, a, &bus, Now.read(io), meta, .{ .dir = dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "1" }, "hello world", "");

    const msgs = try decodeChatFile(a, (try readTranscript(io, a, dir, "topic")).?);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("Tester", msgs[0].from);
    try testing.expectEqualStrings("hello world", msgs[0].markdown);
}

test "a message's live frame is the frame a stream's backlog makes of it, the same for every viewer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("first");
    const ann = try f.bus.open("1_2/topic");
    defer f.bus.close(ann);
    const bob = try f.bus.open("1_2/topic");
    defer f.bus.close(bob);

    const sent = try f.send("**second**, with a [link](/chat)\n\n```\ncode\n```");

    const live = ann.poll() orelse return error.TestUnexpectedResult;
    defer ann.gpa.free(live);
    const also = bob.poll() orelse return error.TestUnexpectedResult;
    defer bob.gpa.free(also);
    try testing.expectEqualStrings(live, also);

    // The backlog's frame for the same message, from what was stored.
    const msgs = try decodeChatFile(a, (try readTranscript(f.io, a, f.dir, "topic")).?);
    try testing.expectEqualStrings(sent.id, msgs[1].id);
    const replayed = try chat_frame.messageFrame(a, .{ .index = indexOf(msgs[1].id, "topic").?, .from = msgs[1].from, .from_uid = msgs[1].uid, .at = msgs[1].at, .id = msgs[1].id, .markdown = msgs[1].markdown });
    try testing.expectEqualStrings(replayed, live);
    try testing.expect(std.mem.startsWith(u8, live, "id: 1\ndata: "));
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
        return appendMessage(self.io, self.arena.allocator(), &self.bus, Now.read(self.io), meta, .{ .dir = self.dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "1" }, text, "");
    }

    /// A message as a server from before `uid:` stored it: its block names
    /// its author by name only, for the tests of how such a block is credited.
    pub fn sendLegacy(self: *CountFixture, text: []const u8) !ChatMessage {
        const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{} };
        return appendMessage(self.io, self.arena.allocator(), &self.bus, Now.read(self.io), meta, .{ .dir = self.dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "" }, text, "");
    }

    pub fn decoded(self: *CountFixture) !usize {
        const a = self.arena.allocator();
        return (try decodeChatFile(a, (try readTranscript(self.io, a, self.dir, "topic")).?)).len;
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
        const sent = appendMessage(f.io, failing.allocator(), &f.bus, Now.read(f.io), meta, .{ .dir = f.dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "1" }, text, "");
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
        const got = appendReaction(f.io, failing.allocator(), &f.bus, Now.read(f.io), .{ .dir = f.dir, .key = "1_2", .sid = "topic" }, 1, .{ .name = "Tester", .id = "1" }, "👍", true);
        const after = (try readReactions(f.io, a, f.dir, "topic")).len;
        if (got) |_| {
            if (!echoed(live, "event: reaction\n")) {
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

test "a reaction after a torn one starts its own line: the torn line is lost, the next is not" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("something to react to");
    const topic: TopicAddress = .{ .dir = f.dir, .key = "1_2", .sid = "topic" };
    // A stop cut the last append short: no newline after it.
    const torn = "{\"msg\":1,\"uid\":\"1\",\"fr";
    _ = try store.append(f.io, a, try reactionsPath(a, f.dir, "topic"), torn);

    const line = try appendReaction(f.io, a, &f.bus, Now.read(f.io), topic, 1, .{ .name = "Tester", .id = "1" }, "👍", true);
    const after = try readReactions(f.io, a, f.dir, "topic");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ torn, line }), after);
    // The next reaction needs no newline of its own: the file ended in one.
    const second = try appendReaction(f.io, a, &f.bus, Now.read(f.io), topic, 1, .{ .name = "Tester", .id = "1" }, "🎉", true);
    const twice = try readReactions(f.io, a, f.dir, "topic");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}{s}\n", .{ after, second }), twice);
}

test "a message and a reaction are stamped with the request's time, not the clock's" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    const now = Now.at(1_761_400_000);
    const meta = ConvMeta{ .kind = .dm, .members = &[_][]const u8{} };
    const topic: TopicAddress = .{ .dir = f.dir, .key = "1_2", .sid = "topic" };
    const sent = try appendMessage(f.io, a, &f.bus, now, meta, topic, .{ .name = "Tester", .id = "1" }, "hi", "");
    try testing.expectEqualStrings("2025-10-25T13:46:40Z", sent.at);
    const stored = try decodeChatFile(a, (try readTranscript(f.io, a, f.dir, "topic")).?);
    try testing.expectEqualStrings("2025-10-25T13:46:40Z", stored[0].at);
    const line = try appendReaction(f.io, a, &f.bus, now.plus(60), topic, 1, .{ .name = "Tester", .id = "1" }, "👍", true);
    try testing.expect(std.mem.endsWith(u8, line, ",\"at\":\"2025-10-25T13:47:40Z\"}"));
}
