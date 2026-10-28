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

/// **A MESSAGE STORED, AS A PRIMITIVE** (the Roc's `Host.store_message!`;
/// roc-webbox chat/main.roc `appended!` decides the rest of what
/// `appendMessage` does): `stored`, message `index`'s block as
/// chatStoredForm writes it (the Roc's Transcript.stored_form), appended to
/// the topic's transcript, then the `.count` and the search index told of
/// `msg`. The count cache and the search index are the store's
/// infrastructure, so they go with the append. An append that failed is
/// the error, nothing stored; past it nothing fails.
pub fn storeMessage(io: Io, alloc: Alloc, topic: TopicAddress, stored: []const u8, index: usize, msg: ChatMessage) !void {
    const path = try transcriptPath(alloc, topic.dir, topic.sid);
    const new_size = try store.append(io, alloc, path, stored);
    // A crash between the append and this leaves a count whose size is not the
    // transcript's — in either order — so messageCount refuses it and recounts.
    // The size check is the protection, not the ordering.
    writeCount(io, alloc, topic.dir, topic.sid, index + 1, new_size, .{
        .offset = new_size - stored.len,
        .uid = msg.uid,
    });
    // **SEARCH SEES IT AS IT LANDS** (metal-vmm 155(b)): the index in memory
    // takes the message, or drops itself whole if it cannot.
    search_index.noteAppend(io, topic.dir, topic.sid, msg);
}

/// A message stored as the Roc's send stores it (`Host.store_message!`,
/// roc-webbox chat/main.roc `append_message!`): numbered by the count,
/// stamped `now`, its block appended by `storeMessage`. For the tests that
/// need messages on disk; a send's frame and fan-out are the Roc's.
pub fn storeForTest(io: Io, alloc: Alloc, now: Now, topic: TopicAddress, from: Author, markdown: []const u8) !ChatMessage {
    const index = try messageCount(io, alloc, topic.dir, topic.sid);
    const id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ topic.sid, index + 1 });
    const at = try timefmt.formatRFC3339UTC(alloc, now.unixSecs());
    const msg = ChatMessage{ .id = id, .from = from.name, .at = at, .markdown = markdown, .uid = from.id };
    try storeMessage(io, alloc, topic, try chatStoredForm(alloc, index, msg), index, msg);
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

/// **ONE LINE APPENDED TO AN APPEND-ONLY LINE FILE** (the Roc's
/// `Host.append_line!`): `line` and a newline at the end of the file at
/// `path`, its folders made as `store.append` makes them. **A TORN LINE
/// STAYS ITS OWN LINE**: an append a stop cut short leaves a line with no
/// newline, and the next one glued to it is one line that reads as neither:
/// two lost where one was. So a file that does not end in a newline gets
/// one first. Read before the store, so a read that fails stores nothing.
pub fn appendLine(io: Io, alloc: Alloc, path: []const u8, line: []const u8) !void {
    const lead = if (try endsMidLine(io, alloc, path)) "\n" else "";
    _ = try store.append(io, alloc, path, try std.mem.concat(alloc, u8, &.{ lead, line, "\n" }));
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
    const dir = try dmConvDir(a, "1_2");
    _ = try storeForTest(io, a, Now.read(io), .{ .dir = dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "1" }, "hello world");

    const msgs = try decodeChatFile(a, (try readTranscript(io, a, dir, "topic")).?);
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
        return storeForTest(self.io, self.arena.allocator(), Now.read(self.io), .{ .dir = self.dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "1" }, text);
    }

    /// A message as a server from before `uid:` stored it: its block names
    /// its author by name only, for the tests of how such a block is credited.
    pub fn sendLegacy(self: *CountFixture, text: []const u8) !ChatMessage {
        return storeForTest(self.io, self.arena.allocator(), Now.read(self.io), .{ .dir = self.dir, .key = "1_2", .sid = "topic" }, .{ .name = "Tester", .id = "" }, text);
    }

    pub fn decoded(self: *CountFixture) !usize {
        const a = self.arena.allocator();
        return (try decodeChatFile(a, (try readTranscript(self.io, a, self.dir, "topic")).?)).len;
    }
};

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

test "a line after a torn one starts its own line: the torn line is lost, the next is not" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try reactionsPath(a, f.dir, "topic");
    // A stop cut the last append short: no newline after it.
    const torn = "{\"msg\":1,\"uid\":\"1\",\"fr";
    _ = try store.append(f.io, a, path, torn);

    const line = "{\"msg\":1}";
    try appendLine(f.io, a, path, line);
    const after = try readReactions(f.io, a, f.dir, "topic");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ torn, line }), after);
    // The next line needs no newline of its own: the file ended in one.
    const second = "{\"msg\":2}";
    try appendLine(f.io, a, path, second);
    const twice = try readReactions(f.io, a, f.dir, "topic");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}{s}\n", .{ after, second }), twice);
}
