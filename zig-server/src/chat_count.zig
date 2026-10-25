//! chat_count: what a topic holds without reading its transcript: the
//! `.count` sidecar (its message count, the size it was taken at, its last
//! message's place and author), the last message for /chat/recent, and the
//! startup backfill (split from chat_store.zig by metal-vmm QUEUE 174).

const std = @import("std");
const Now = @import("request_time.zig").Now;
const decimal = @import("decimal.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const bus_mod = @import("webbox").bus;
const Bus = bus_mod.Bus;
const users = @import("users.zig");
const testing = std.testing;
const chat_store = @import("chat_store.zig");
const chat_codec = @import("chat_codec.zig");
const chat_paths = @import("chat_paths.zig");
const channelConvDir = chat_paths.channelConvDir;
const appendReaction = chat_store.appendReaction;
const decodeChatFile = chat_codec.decodeChatFile;
const tail_window = chat_store.tail_window;
const CountFixture = chat_store.CountFixture;
const no_uid = chat_store.no_uid;
const sep = chat_store.sep;
const ChatMessage = chat_store.ChatMessage;
const listConvDirs = chat_paths.listConvDirs;
const listTopics = chat_paths.listTopics;
const readTranscript = chat_paths.readTranscript;
const transcriptPath = chat_paths.transcriptPath;

/// What a topic's last message is, for a listing that must not read the
/// transcript: the words, when they were sent, and the uid that sent them
/// (where the sidecar does not say, the member the last message names; empty
/// when none does: never an older author, zig-metal-unikernel 153(1)).
pub const LastMessage = struct {
    markdown: []const u8,
    at: []const u8,
    uid: []const u8,
    /// Which message of the topic this is, counting from one.
    number: usize,
};

/// lastMessage answers a topic's last message **without a stat and without
/// reading the whole transcript**, when the sidecar can say where it begins:
/// one small read of the sidecar, one bounded read of the tail.
///
/// **NO STAT.** /chat/recent used to order by file mtime, which meant statting
/// every topic; the message carries its own date, so neither is needed. The
/// price is that a transcript appended to behind this server's back is not
/// noticed until the next message or the next read of the whole thing — which
/// for a listing is a stale excerpt, where for `messageCount` it would be a
/// misnumbered message. That is why the count checks the size and this does
/// not.
///
/// It is not trusted blindly: the last block in the window must be a message of
/// this topic, numbered at least what the sidecar says. Anything else — a
/// hand-edited transcript, a sidecar from another file, a message too long for
/// the window — falls back to reading the whole thing.
pub fn lastMessage(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !?LastMessage {
    const counted = readCount(io, alloc, conv_dir, sid);
    if (counted) |c| {
        if (c.last) |l| if (c.count > 0) {
            const path = try transcriptPath(alloc, conv_dir, sid);
            const buf = try alloc.alloc(u8, tail_window);
            // absent-ok: the sidecar is a cache: a window that will not read falls back to the transcript.
            const n = store.readAt(io, alloc, path, l.offset, buf) catch return fallbackLast(io, alloc, conv_dir, sid, counted);
            _ = alloc.resize(buf, n);
            if (try windowLast(alloc, c.count, buf[0..n], n == tail_window, sid)) |w| return .{
                .markdown = w.msg.markdown,
                .at = w.msg.at,
                // A current record's answer stands, nobody included;
                // a record behind: the newer message's author.
                .uid = if (w.current) l.uid else authorOf(io, alloc, w.msg),
                .number = w.number,
            };
        };
    }
    return fallbackLast(io, alloc, conv_dir, sid, counted);
}

/// What the window read at the sidecar's offset says the last message is,
/// or null when it cannot be believed: its last block must be a message of
/// `sid`, numbered at least `count`. `current` when numbered exactly that:
/// the record speaks for it.
///
/// **A WINDOW THAT CAME BACK FULL MAY HAVE CUT A MESSAGE IN HALF**, and
/// nothing here could tell: `full` is never believed.
///
/// **AT LEAST what the sidecar says, not exactly.** A crash or a failed
/// write between appending a message and recording it leaves an offset one
/// message behind — and it would VERIFY, because the count is one behind
/// too. Reading to the end of the file instead of to a recorded size means
/// the newer message is right there, so the answer is the true last one and
/// the record repairs itself on the next send.
pub fn windowLast(alloc: Alloc, count: usize, window: []const u8, full: bool, sid: []const u8) !?struct { msg: ChatMessage, number: usize, current: bool } {
    if (full) return null;
    const msgs = try decodeChatFile(alloc, window);
    if (msgs.len == 0) return null;
    const got = msgs[msgs.len - 1];
    const number = numberIn(got.id, sid) orelse return null;
    if (number < count) return null;
    return .{ .msg = got, .number = number, .current = number == count };
}

/// **THE AUTHOR WHERE NO SIDECAR SAYS** (the box's must-fix after 153(1)):
/// where the record is behind its transcript or missing, the message's own
/// `uid:`, or, for a block written before it had one, the member named
/// `from`, the last message's name (names are unique among members; login
/// finds members by name), else "". The backfill records it; a send records
/// its own author. Never an older author.
///
/// **A CURRENT RECORD IS NOT ASKED AGAIN** (the review): one that says
/// nobody was looked up when it was written, and a name a member released
/// and a newcomer took would credit the newcomer, "You" included; and the
/// lookup reads every account, on every read.
///
/// **ONE MEMBER, OR NOBODY** (the box's review of 155): a name two members
/// share (108's sign-up race) names neither.
fn authorOf(io: Io, alloc: Alloc, msg: ChatMessage) []const u8 {
    // absent-ok: an author that cannot be looked up is shown as nobody, for this read only: nothing records it.
    return lookupAuthor(io, alloc, msg) catch "";
}

/// `authorOf`, its failure kept: what the backfill records is believed
/// for good (a current record is never asked again), so a lookup that
/// failed must record nothing, never nobody (the box's should-fix). A
/// message that names its author is not looked up at all.
fn lookupAuthor(io: Io, alloc: Alloc, msg: ChatMessage) ![]const u8 {
    if (msg.uid.len > 0) return msg.uid;
    if (msg.from.len == 0) return "";
    return (try users.onlyMemberNamed(io, alloc, msg.from)) orelse "";
}

/// The N of a `<sid>_<N>` message id, or null when the id is not this
/// topic's — which is what a sidecar pointing at the wrong place looks like.
pub fn numberIn(id: []const u8, sid: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, sid)) return null;
    const rest = id[sid.len..];
    if (rest.len < 2 or rest[0] != '_') return null;
    return decimal.parseInt(usize, rest[1..]);
}

/// The whole transcript, decoded, for a topic whose sidecar cannot say. What
/// every topic cost before the sidecar carried a last message.
///
/// **THE AUTHOR FROM THE SIDECAR, WHERE IT SPEAKS FOR THIS MESSAGE**
/// (zig-metal-unikernel 153(1)'s review): a message too long for the window, or a
/// tail that would not read, still has its author in the `.count` when the
/// transcript is exactly the one it counted, in messages and in size.
/// Otherwise none: unknown, never an older author.
fn fallbackLast(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, counted: ?Count) !?LastMessage {
    const raw = (try readTranscript(io, alloc, conv_dir, sid)) orelse return null;
    const msgs = try decodeChatFile(alloc, raw);
    if (msgs.len == 0) return null;
    const last = msgs[msgs.len - 1];
    // The record's answer where it speaks for this transcript, nobody
    // included; else the last author by name.
    const blocks = countBlocks(raw);
    return .{ .markdown = last.markdown, .at = last.at, .uid = recordedAuthor(counted, blocks, raw.len) orelse authorOf(io, alloc, last), .number = blocks };
}

/// The author the record names, nobody included, when it speaks for a
/// transcript of `blocks` blocks and `size` bytes: exactly the one it
/// counted. Else null: unknown, never an older author.
pub fn recordedAuthor(counted: ?Count, blocks: usize, size: u64) ?[]const u8 {
    const c = counted orelse return null;
    const l = c.last orelse return null;
    return if (c.count == blocks and c.size == size) l.uid else null;
}

/// **EVERY TOPIC GETS A SIDECAR AT BOOT.** A conversation written before this
/// existed, or repaired by hand, would otherwise cost a whole-transcript read
/// on every listing for as long as nobody posts to it. Both hosts run this —
/// the Linux server and the machine with no operating system — because they are
/// judged on the files they leave behind as well as the answers they give.
///
/// One pass over the conversations, reading only what it has to: a topic
/// whose sidecar already says where its last message is costs one small read.
/// Answers how many it wrote.
pub fn backfillSidecars(io: Io, alloc: Alloc, conv_dirs: []const []const u8) usize {
    var wrote: usize = 0;
    // **ONE TOPIC'S TRANSCRIPT AT A TIME.** The first boot after this arrives
    // reads every transcript there is; holding them all at once would make the
    // pass cost the whole corpus, several times over, on the one host with no
    // operating system to ask for more.
    var per_topic = std.heap.ArenaAllocator.init(alloc);
    defer per_topic.deinit();
    for (conv_dirs) |dir| {
        // absent-ok: the startup backfill skips a conversation it cannot list; it writes only what it can derive.
        const sids = listTopics(io, alloc, dir) catch continue;
        for (sids) |sid| {
            _ = per_topic.reset(.retain_capacity);
            const a = per_topic.allocator();
            if (readCount(io, a, dir, sid)) |c| if (c.last != null) continue;
            // absent-ok: the same, for a transcript it cannot read: no sidecar is written for it.
            const raw = (readTranscript(io, a, dir, sid) catch continue) orelse continue;
            const msgs = decodeChatFile(a, raw) catch continue;
            if (msgs.len == 0) continue;
            // The last block begins at the last separator; a lone message
            // begins at the start of the file.
            const offset = if (std.mem.lastIndexOf(u8, raw, sep)) |at| at else 0;
            // The last message's author, found by name (the box's must-fix
            // after 153(1)); "", when no member has it. A lookup that fails
            // writes nothing: the next boot asks again.
            // absent-ok: the startup backfill skips a topic whose author it cannot look up; reads find the author by name meanwhile.
            const uid = lookupAuthor(io, a, msgs[msgs.len - 1]) catch continue;
            // Counted only when written (metal-vmm QUEUE 172): the start's
            // report said "backfilled N" for writes that failed.
            // absent-ok: a sidecar that will not write is recounted by the next read, and asked again next boot.
            tryWriteCount(io, a, dir, sid, countBlocks(raw), raw.len, .{ .offset = offset, .uid = uid }) catch continue;
            wrote += 1;
        }
    }
    return wrote;
}

/// backfillAll gives every topic on disk a last-message record. **Both hosts
/// call this once at startup** — see `backfillSidecars`.
pub fn backfillAll(io: Io, alloc: Alloc) usize {
    // absent-ok: the startup backfill does nothing if it cannot list: nothing is written.
    const dirs = listConvDirs(io, alloc) catch return 0;
    return backfillSidecars(io, alloc, dirs);
}

// ── the message count ─────────

/// countPath is {conv_dir}/sessions/<sid>.count — the topic's message count,
/// and the transcript size it was taken at: "<count> <size>\n".
pub fn countPath(alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.count", .{sid});
    return std.fs.path.join(alloc, &.{ conv_dir, "sessions", file });
}

/// messageCount is how many messages a topic holds — the N that numbers the
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
pub fn messageCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !usize {
    const md = try transcriptPath(alloc, conv_dir, sid);
    // No transcript is no messages; a transcript that cannot be looked at or
    // read is an error, never 0: numbering from 0 would glue the next message
    // onto the last and count wrong from then on.
    const size = (store.stat(io, alloc, md) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    }).size;
    if (believedCount(readCount(io, alloc, conv_dir, sid), size)) |n| return n;
    return countBlocks(try store.read(io, alloc, md, .unlimited));
}

/// The count a sidecar gives, believed only when the transcript is still
/// the `size` it was taken at; else null, and the transcript is counted.
pub fn believedCount(counted: ?Count, size: u64) ?usize {
    const c = counted orelse return null;
    return if (c.size == size) c.count else null;
}

/// **MESSAGES ARE NUMBERED BY BLOCK** (the review of 156): a block the
/// decoder refuses keeps its number, so a recount, which numbers the next
/// message, counts every block that is not blank, and never gives a number
/// twice; readers take a message's index from its id (`indexOf`), not its
/// place among the ones that decoded.
pub fn countBlocks(raw: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, raw, sep);
    while (it.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t\r\n").len != 0) n += 1;
    }
    return n;
}

/// A message's index (its number less one) from its id in `sid`, or null.
pub fn indexOf(id: []const u8, sid: []const u8) ?usize {
    const n = numberIn(id, sid) orelse return null;
    return if (n == 0) null else n - 1;
}

/// **WHERE THE LAST MESSAGE STARTS, WHEN IT WAS SENT, AND BY WHOM** — the
/// second line of the sidecar, and everything /chat/recent needs to list a
/// topic without reading its transcript.
///
/// **THE OFFSET, NOT THE WORDS, AND NOT THE DATE EITHER.** Keeping the text
/// here would be a second copy of it on disk, and a rendered excerpt would be a
/// copy that goes stale the day excerpts are rendered differently. The offset
/// points at the last block, which is read positionally and decoded by the one
/// decoder — so the words, and the date they carry, live in exactly one place,
/// and the cache can be wrong about nothing but where to start reading.
///
/// The uid is here because the transcript does not hold one: a block records
/// the author's NAME, and "is this the viewer" is a question about the uid.
pub const Last = struct { offset: u64, uid: []const u8 };

pub const Count = struct { count: usize, size: u64, last: ?Last = null };

/// readCount parses the sidecar: "<count> <size>" on the first line, and
/// optionally "<offset> <uid>" on the second. Null for a first line that
/// is not exactly two numbers — a malformed sidecar is a stale one. A second
/// line that does not parse is simply absent: the count is still good, and the
/// caller falls back to the transcript for the rest.
///
/// An older build reading a sidecar written here sees a second line, refuses
/// the whole thing and recounts from the transcript — slower, never wrong.
pub fn readCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) ?Count {
    const path = countPath(alloc, conv_dir, sid) catch return null;
    // absent-ok: a cache: a count that will not read is recounted from the transcript (messageCount).
    const raw = store.read(io, alloc, path, .limited(1024)) catch return null;
    return parseCount(raw);
}

/// A sidecar's bytes as `readCount` believes them.
pub fn parseCount(raw: []const u8) ?Count {
    // **WHOLE, OR NOT AT ALL**: written by `write`, a crash can leave it cut
    // short, and a uid cut short is another uid (the review of 153(1)).
    // Every record ends in a newline.
    if (raw.len == 0 or raw[raw.len - 1] != '\n') return null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var head = std.mem.tokenizeScalar(u8, lines.next() orelse return null, ' ');
    const count = decimal.parseInt(usize, head.next() orelse return null) orelse return null;
    const size = decimal.parseInt(u64, head.next() orelse return null) orelse return null;
    if (head.next() != null) return null;
    return .{ .count = count, .size = size, .last = parseLast(lines.next() orelse "") };
}

fn parseLast(line: []const u8) ?Last {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const offset = decimal.parseInt(u64, it.next() orelse return null) orelse return null;
    const uid = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .offset = offset, .uid = if (std.mem.eql(u8, uid, no_uid)) "" else uid };
}

/// writeCount records the count and, when there is one, where the last message
/// begins. Best effort: a sidecar that fails to write is one recomputed next
/// time, never a wrong one.
pub fn writeCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, count: usize, size: u64, last: ?Last) void {
    // absent-ok: a cache, checked against the transcript's size: one not written is recounted.
    tryWriteCount(io, alloc, conv_dir, sid, count, size, last) catch {};
}

/// writeCount, saying whether it wrote (the backfill counts only what did).
fn tryWriteCount(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8, count: usize, size: u64, last: ?Last) !void {
    const path = try countPath(alloc, conv_dir, sid);
    const text = try countText(alloc, count, size, last);
    // **A `write`, NOT A `replace`** (zig-metal-unikernel 153(1)): the sidecar is a
    // cache, checked against the transcript's size, so one a crash left
    // empty or torn is recounted, on either host (and `readCount` refuses
    // one cut short of its newline); on zig-metal-unikernel a write is as safe as a
    // replace besides (STORE.md), at about half the disk requests.
    try store.write(io, alloc, path, text, .{});
}

/// A sidecar's bytes, as `tryWriteCount` writes them.
pub fn countText(alloc: Alloc, count: usize, size: u64, last: ?Last) ![]u8 {
    const head = try std.fmt.allocPrint(alloc, "{d} {d}\n", .{ count, size });
    const l = last orelse return head;
    return std.fmt.allocPrint(alloc, "{s}{d} {s}\n", .{ head, l.offset, if (l.uid.len > 0) l.uid else no_uid });
}

// The fixture's reads and writes of the files it made, beside the tests
// that use them (a test helper, so it may touch the disk directly).
fn fixtureSidecar(self: *CountFixture) !?[]u8 {
    const a = self.arena.allocator();
    return Io.Dir.cwd().readFileAlloc(self.io, try countPath(a, self.dir, "topic"), a, .limited(1024)) catch null;
}

fn fixtureSetSidecar(self: *CountFixture, text: []const u8) !void {
    const a = self.arena.allocator();
    try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try countPath(a, self.dir, "topic"), .data = text });
}

fn fixtureTranscriptSize(self: *CountFixture) !u64 {
    const a = self.arena.allocator();
    return (try Io.Dir.cwd().statFile(self.io, try transcriptPath(a, self.dir, "topic"), .{})).size;
}

test "a message's number has one spelling: digits after the topic and its underscore" {
    try testing.expectEqual(@as(?usize, 0), indexOf("topic_1", "topic"));
    try testing.expectEqual(@as(?usize, 9), indexOf("topic_10", "topic"));
    // Spellings Zig's parseInt took, each a second name for some message.
    for ([_][]const u8{ "topic_1_0", "topic_+5", "topic_-0", "topic_ 1", "topic_", "topic_0", "topic1" }) |id| {
        try testing.expectEqual(@as(?usize, null), indexOf(id, "topic"));
    }
}

test "count: every send records the count and the transcript size it was taken at" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (0..5) |_| _ = try f.send("hello");
    const a = f.arena.allocator();
    const size = try fixtureTranscriptSize(&f);
    const text = (try fixtureSidecar(&f)).?;
    var lines = std.mem.splitScalar(u8, text, '\n');
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "5 {d}", .{size}), lines.next().?);
    // And where the last message begins, and who sent it.
    const last = parseLast(lines.next().?).?;
    try testing.expect(last.offset < size);
    try testing.expectEqualStrings("1", last.uid);
    try testing.expectEqual(@as(usize, 5), try f.decoded());
}

test "count: ids stay consecutive, and agree with the transcript's own numbering" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (1..8) |n| {
        const m = try f.send("x");
        const want = try std.fmt.allocPrint(f.arena.allocator(), "topic_{d}", .{n});
        try testing.expectEqualStrings(want, m.id);
    }
}

test "count: a conversation from before the sidecar is counted from its transcript" {
    // Prod has every existing conversation in this state on the first deploy.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (0..3) |_| _ = try f.send("old");
    const a = f.arena.allocator();
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    const m = try f.send("new");
    try testing.expectEqualStrings("topic_4", m.id);
    try testing.expect((try fixtureSidecar(&f)) != null);
}

test "count: a count taken at another size is not believed" {
    // A crash between the append and its count leaves exactly this: a count
    // one short, recorded at the transcript's previous size.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (0..4) |_| _ = try f.send("x");
    try fixtureSetSidecar(&f, "3 1\n");
    const m = try f.send("after the crash");
    try testing.expectEqualStrings("topic_5", m.id);
}

test "count: a sidecar that does not parse is a stale one" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (0..2) |_| _ = try f.send("x");
    for ([_][]const u8{ "", "banana", "2", "2 x", "2 10 extra", "-1 10", "2 10\n0" }) |junk| {
        try fixtureSetSidecar(&f, junk);
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (0..2) |_| _ = try f.send("x");
    const a = f.arena.allocator();
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "41 {d}\n", .{try fixtureTranscriptSize(&f)}));
    const m = try f.send("x");
    try testing.expectEqualStrings("topic_42", m.id);
}

test "count: a reaction is checked against the count" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    for (0..2) |_| _ = try f.send("x");
    const io = f.io;
    const a = f.arena.allocator();
    _ = try appendReaction(io, a, &f.bus, Now.read(io), .{ .dir = f.dir, .key = "1_2", .sid = "topic" }, 2, .{ .name = "Tester", .id = "1" }, "+1", true);
    try testing.expectError(error.NoSuchMessage, appendReaction(io, a, &f.bus, Now.read(io), .{ .dir = f.dir, .key = "1_2", .sid = "topic" }, 3, .{ .name = "Tester", .id = "1" }, "+1", true));
    try testing.expectError(error.NoSuchMessage, appendReaction(io, a, &f.bus, Now.read(io), .{ .dir = f.dir, .key = "1_2", .sid = "topic" }, 0, .{ .name = "Tester", .id = "1" }, "+1", true));
}

test "count: an empty conversation has none, and its first message is number one" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), try messageCount(f.io, f.arena.allocator(), f.dir, "topic"));
    const m = try f.send("first");
    try testing.expectEqualStrings("topic_1", m.id);
}

test "count: a transcript that cannot be read is an error, never no messages" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    // A folder where the transcript should be: there, and unreadable.
    try store.makeDir(f.io, a, try transcriptPath(a, f.dir, "topic"));
    try testing.expect(std.meta.isError(messageCount(f.io, a, f.dir, "topic")));
}

test "last message: the sidecar answers without reading the transcript" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("first");
    _ = try f.send("second");
    const sent = try f.send("the last word");

    const got = (try lastMessage(f.io, f.arena.allocator(), f.dir, "topic")).?;
    try testing.expectEqualStrings("the last word", got.markdown);
    try testing.expectEqualStrings(sent.at, got.at);
    try testing.expectEqualStrings("1", got.uid);
    try testing.expectEqual(@as(usize, 3), got.number);
}

test "last message: one message, and the block that begins the file" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("alone");
    const got = (try lastMessage(f.io, f.arena.allocator(), f.dir, "topic")).?;
    try testing.expectEqualStrings("alone", got.markdown);
    try testing.expectEqual(@as(usize, 1), got.number);
}

test "last message: a body that contains the separator still comes back whole" {
    // The transcript escapes a body line that would look like the separator;
    // reading the tail goes through the same decoder, so it is unescaped there.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("innocent");
    const nasty = "before\n-------------\nafter";
    _ = try f.send(nasty);
    const got = (try lastMessage(f.io, f.arena.allocator(), f.dir, "topic")).?;
    try testing.expectEqualStrings(nasty, got.markdown);
    try testing.expectEqual(@as(usize, 2), got.number);
}

test "last message: a sidecar pointing at the wrong place is not believed" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("first");
    _ = try f.send("the real last");
    const a = f.arena.allocator();
    const size = try fixtureTranscriptSize(&f);
    // An offset into the middle of a block, and one that claims a message the
    // topic does not have.
    for ([_][]const u8{
        try std.fmt.allocPrint(a, "2 {d}\n7 1\n", .{size}), // into the middle of a block
        try std.fmt.allocPrint(a, "9 {d}\n0 1\n", .{size}), // a message the topic does not have
    }) |junk| {
        try fixtureSetSidecar(&f, junk);
        const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
        try testing.expectEqualStrings("the real last", got.markdown);
    }
}

test "last message: a session from before the sidecar is read from its transcript" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("first");
    _ = try f.send("second");
    const a = f.arena.allocator();
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("second", got.markdown);
    try testing.expectEqual(@as(usize, 2), got.number);
    // No sidecar says, and the message does: its own `uid:`.
    try testing.expectEqualStrings("1", got.uid);
}

test "last message: a block from before `uid:` names nobody where nothing else says (153(1))" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    // A transcript an older server wrote: no `uid:` lines, and no sidecar.
    // "Tester" is no member's name here, so nobody, never a guess.
    try store.write(f.io, a, try transcriptPath(a, f.dir, "topic"), "MSG_topic_1\nfrom: Tester\ndate: 2026-10-10T00:00:00Z\n\nfirst" ++ sep ++ "MSG_topic_2\nfrom: Tester\ndate: 2026-10-10T00:00:01Z\n\nsecond", .{});
    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("second", got.markdown);
    try testing.expectEqual(@as(usize, 2), got.number);
    try testing.expectEqualStrings("", got.uid);
}

test "backfill: a session with no last-message record gets one, and only once" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("first");
    _ = try f.send("last");
    const a = f.arena.allocator();
    // A sidecar as an older build left it: a count and a size, nothing more,
    // and the `.lastauthor` it wrote beside, which is no longer read
    // (zig-metal-unikernel 153(1)).
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "2 {d}\n", .{try fixtureTranscriptSize(&f)}));
    try store.write(f.io, a, try std.fs.path.join(a, &.{ f.dir, "sessions", "topic.lastauthor" }), "1", .{});

    const dirs = [_][]const u8{f.dir};
    try testing.expectEqual(@as(usize, 1), backfillSidecars(f.io, a, &dirs));
    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("last", got.markdown);
    // Not the `.lastauthor`: the message's own `uid:`.
    try testing.expectEqualStrings("1", got.uid);
    // A second pass finds nothing to do.
    try testing.expectEqual(@as(usize, 0), backfillSidecars(f.io, a, &dirs));
}

test "backfill: a session with no sidecar at all gets one" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("only");
    const a = f.arena.allocator();
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    const dirs = [_][]const u8{f.dir};
    try testing.expectEqual(@as(usize, 1), backfillSidecars(f.io, a, &dirs));
    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("only", got.markdown);
    try testing.expectEqual(@as(usize, 1), got.number);
}

test "backfill: one pass reaches DMs and channels alike" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("in a dm");
    // A channel with a topic of its own, written as the store lays it out.
    const chan = try channelConvDir(a, "general");
    const sessions = try std.fs.path.join(a, &.{ chan, "sessions" });
    try Io.Dir.cwd().createDirPath(f.io, sessions);
    try Io.Dir.cwd().writeFile(f.io, .{
        .sub_path = try std.fs.path.join(a, &.{ sessions, "topic.md" }),
        .data = "MSG_topic_1\nfrom: Tester\ndate: 2026-06-19T14:34:07Z\n\nin a channel",
    });

    const dirs = try listConvDirs(f.io, a);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    // The DM already has its record from the send; the channel does not.
    try testing.expectEqual(@as(usize, 1), backfillAll(f.io, a));
    const got = (try lastMessage(f.io, a, chan, "topic")).?;
    try testing.expectEqualStrings("in a channel", got.markdown);
    try testing.expectEqualStrings("2026-06-19T14:34:07Z", got.at);
}

test "backfill: the record it writes can be read back" {
    // **THE ASSERTION THAT WAS MISSING.** The backfill has no uid to record
    // (no `.lastauthor` is read, zig-metal-unikernel 153(1)), and a field left empty made the line one field short —
    // so the record was unreadable, `lastMessage` quietly read the whole
    // transcript instead, and every test still passed. What the backfill
    // writes has to PARSE, not merely lead to the right answer.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    const dir = try channelConvDir(a, "nameless");
    const sessions = try std.fs.path.join(a, &.{ dir, "sessions" });
    try Io.Dir.cwd().createDirPath(f.io, sessions);
    try Io.Dir.cwd().writeFile(f.io, .{
        .sub_path = try std.fs.path.join(a, &.{ sessions, "topic.md" }),
        .data = "MSG_topic_1\nfrom: Nobody\ndate: 2026-06-19T14:34:07Z\n\nwho said this",
    });

    const dirs = [_][]const u8{dir};
    try testing.expectEqual(@as(usize, 1), backfillSidecars(f.io, a, &dirs));
    const c = readCount(f.io, a, dir, "topic").?;
    try testing.expect(c.last != null); // it parses
    try testing.expectEqualStrings("", c.last.?.uid); // and says it does not know
    // Which makes the pass idempotent: nothing left to do next boot.
    try testing.expectEqual(@as(usize, 0), backfillSidecars(f.io, a, &dirs));

    const got = (try lastMessage(f.io, a, dir, "topic")).?;
    try testing.expectEqualStrings("who said this", got.markdown);
    try testing.expectEqualStrings("2026-06-19T14:34:07Z", got.at);
}

test "last message: a record left one behind still answers with the true last message" {
    // A crash, or a sidecar write that failed, between appending a message and
    // recording it: the count and the offset are BOTH one behind, so the block
    // at the offset is exactly the message the record claims — it verifies,
    // and a reader that stopped there would show the previous message, name
    // the previous author, and sort the row by the previous date, until
    // somebody posted again.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("the first");
    const after_first = try fixtureTranscriptSize(&f);
    _ = try f.send("the second");
    // The sidecar as it stood before the second message was recorded, and a
    // `.lastauthor` an older server left, naming someone else.
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "1 {d}\n0 9\n", .{after_first}));
    try store.write(f.io, a, try std.fs.path.join(a, &.{ f.dir, "sessions", "topic.lastauthor" }), "9", .{});

    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("the second", got.markdown);
    try testing.expectEqual(@as(usize, 2), got.number);
    // The stale uid is not used, nor a `.lastauthor` (zig-metal-unikernel 153(1)):
    // the newer message says who wrote it (its `uid:`), never a guess that
    // could be wrong (a "You" for a message the viewer did not write).
    try testing.expectEqualStrings("1", got.uid);
}

test "last message: one too long for the window is read the slow way, and is right" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("small");
    const huge = try a.alloc(u8, tail_window + 4096);
    for (huge, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    _ = try f.send(huge);

    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqual(huge.len, got.markdown.len);
    try testing.expectEqualStrings(huge, got.markdown);
    try testing.expectEqual(@as(usize, 2), got.number);
    // And its author, from the sidecar: no `.lastauthor` is written now
    // (zig-metal-unikernel 153(1)'s review).
    try testing.expectEqualStrings("1", got.uid);

    // A sidecar whose count matches but whose size does not (the transcript
    // edited by hand since) speaks for some other last message: not its uid
    // (9), but the last message's own.
    const c = readCount(f.io, a, f.dir, "topic").?;
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "{d} {d}\n{d} 9\n", .{ c.count, c.size + 1, c.last.?.offset }));
    try testing.expectEqualStrings("1", (try lastMessage(f.io, a, f.dir, "topic")).?.uid);
}

test "last message: a sidecar claiming a size far past the file does not ask for that much" {
    // The size field is never checked against the file — by design, since
    // nothing stats. It must therefore not be what a read is sized by.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.send("modest");
    try fixtureSetSidecar(&f, "1 999999999999\n0 1\n");
    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("modest", got.markdown);
}

test "a send writes no .lastauthor, and its .count names the author over one an older server left (zig-metal-unikernel 153(1); that none is read even behind is the one-behind test's)" {
    // The `.count` carries the author now. A `.lastauthor` left from before
    // names the previous author once a send no longer writes it: it is left
    // where it is, and nothing asks it.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    const la = try std.fs.path.join(a, &.{ f.dir, "sessions", "topic.lastauthor" });
    _ = try f.send("the first");
    try testing.expect(!try store.has(f.io, a, la));
    try store.write(f.io, a, la, "9", .{}); // as an older server left it
    _ = try f.send("the second");
    const got = (try lastMessage(f.io, a, f.dir, "topic")).?;
    try testing.expectEqualStrings("1", got.uid);
}

test "the last session and conversation are written only when they change (zig-metal-unikernel 153(1))" {
    const chat_state = @import("chat_state.zig");
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    try chat_state.setLastViewedTopic(f.io, a, "1", "1_2", "topic");
    const lc = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-conv" });
    const ls = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions", "1_2" });
    try testing.expectEqualStrings("1_2\n", try store.read(f.io, a, lc, .limited(64)));
    // The same values again, stored without their newline: a write would put
    // it back.
    try store.write(f.io, a, lc, "1_2", .{});
    try store.write(f.io, a, ls, "topic", .{});
    try chat_state.setLastViewedTopic(f.io, a, "1", "1_2", "topic");
    try testing.expectEqualStrings("1_2", try store.read(f.io, a, lc, .limited(64)));
    try testing.expectEqualStrings("topic", try store.read(f.io, a, ls, .limited(64)));
    // A new one is written.
    try chat_state.setLastViewedTopic(f.io, a, "1", "1_2", "other");
    try testing.expectEqualStrings("other\n", try store.read(f.io, a, ls, .limited(64)));
}

test "the author where no sidecar says is the member the last message names; the backfill writes it in (the box's must-fix)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    try users.setUserName(f.io, a, "1", "Tester");
    try users.setUserPassword(f.io, a, "1", "pw");
    _ = try f.sendLegacy("the first");
    const after_first = try fixtureTranscriptSize(&f);
    _ = try f.sendLegacy("the second");
    // One behind, its uid someone else's: the newer message's author by name.
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "1 {d}\n0 9\n", .{after_first}));
    try testing.expectEqualStrings("1", (try lastMessage(f.io, a, f.dir, "topic")).?.uid);
    // No sidecar at all: the slow path, and the backfill's record, by name.
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    try testing.expectEqualStrings("1", (try lastMessage(f.io, a, f.dir, "topic")).?.uid);
    const dirs = [_][]const u8{f.dir};
    try testing.expectEqual(@as(usize, 1), backfillSidecars(f.io, a, &dirs));
    try testing.expectEqualStrings("1", readCount(f.io, a, f.dir, "topic").?.last.?.uid);
    // A name no member has: nobody, never a guess.
    try users.setUserName(f.io, a, "1", "Renamed");
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "1 {d}\n0 9\n", .{after_first}));
    try testing.expectEqualStrings("", (try lastMessage(f.io, a, f.dir, "topic")).?.uid);
}

test "a current record that says nobody is believed: a name reused after its member left gets no credit (the Who cell's review)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    // The last message is "Tester"'s, and no member has that name now: the
    // backfill records nobody.
    _ = try f.sendLegacy("from someone since gone");
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    const dirs = [_][]const u8{f.dir};
    try testing.expectEqual(@as(usize, 1), backfillSidecars(f.io, a, &dirs));
    try testing.expectEqualStrings("", readCount(f.io, a, f.dir, "topic").?.last.?.uid);
    // A newcomer takes the name: the record still says nobody.
    try users.setUserName(f.io, a, "9", "Tester");
    try users.setUserPassword(f.io, a, "9", "pw");
    try testing.expectEqualStrings("", (try lastMessage(f.io, a, f.dir, "topic")).?.uid);
}

test "a name two members share names nobody (the box's review of 155, 4)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    for ([_][]const u8{ "1", "2" }) |id| {
        try users.setUserName(f.io, a, id, "Tester");
        try users.setUserPassword(f.io, a, id, "pw");
    }
    _ = try f.sendLegacy("the first");
    const after_first = try fixtureTranscriptSize(&f);
    _ = try f.sendLegacy("the second");
    try fixtureSetSidecar(&f, try std.fmt.allocPrint(a, "1 {d}\n0 9\n", .{after_first}));
    try testing.expectEqualStrings("", (try lastMessage(f.io, a, f.dir, "topic")).?.uid);
}

test "a lookup that fails at boot records nothing, so a later boot finds the author (the box's should-fix after fce504f)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    try users.setUserName(f.io, a, "1", "Tester");
    try users.setUserPassword(f.io, a, "1", "pw");
    // An account whose name will not read: the lookup fails.
    try Io.Dir.cwd().createDirPath(f.io, try std.fs.path.join(a, &.{ users.auth_root, "5", "name" }));
    _ = try f.sendLegacy("hello");
    try Io.Dir.cwd().deleteFile(f.io, try countPath(a, f.dir, "topic"));
    const dirs = [_][]const u8{f.dir};
    try testing.expectEqual(@as(usize, 0), backfillSidecars(f.io, a, &dirs));
    try testing.expect(readCount(f.io, a, f.dir, "topic") == null);
    // The account heals; the next boot finds the author.
    try Io.Dir.cwd().deleteTree(f.io, try std.fs.path.join(a, &.{ users.auth_root, "5" }));
    try testing.expectEqual(@as(usize, 1), backfillSidecars(f.io, a, &dirs));
    try testing.expectEqualStrings("1", readCount(f.io, a, f.dir, "topic").?.last.?.uid);
}

test "backfill: a sidecar that will not write is not counted as written (metal-vmm QUEUE 172: the start's report said 'backfilled N' for writes that failed)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    _ = try f.send("only");
    const a = f.arena.allocator();
    // The sidecar's place is a folder: its write fails.
    const sidecar = try countPath(a, f.dir, "topic");
    try Io.Dir.cwd().deleteFile(f.io, sidecar);
    try Io.Dir.cwd().createDirPath(f.io, sidecar);
    const dirs = [_][]const u8{f.dir};
    try testing.expectEqual(@as(usize, 0), backfillSidecars(f.io, a, &dirs));
}
