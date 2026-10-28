//! **THE CHAT'S TEST FIXTURES** (metal-vmm QUEUE 285): writers the chat's
//! tests still build their files with, whose production callers are gone
//! (the Roc writes transcripts, counts and feeds now): a message's stored
//! block (the Roc's Transcript.stored_form), the old count, a message stored
//! as a send stores it, a store over a throwaway directory, and the old
//! images.md and code.md entries. Tests only: nothing in the image imports it.

const std = @import("std");
const testing = std.testing;
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const Now = @import("request_time.zig").Now;
const store = @import("webbox").store;
const bus_mod = @import("webbox").bus;
const Bus = bus_mod.Bus;
const timefmt = @import("timefmt.zig");
const roots = @import("roots.zig");
const chat_store = @import("chat_store.zig");
const chat_count = @import("chat_count.zig");
const chat_codec = @import("chat_codec.zig");
const chat_paths = @import("chat_paths.zig");
const ChatMessage = chat_store.ChatMessage;
const TopicAddress = chat_store.TopicAddress;
const Author = chat_store.Author;
const storeMessage = chat_store.storeMessage;
const sep = chat_store.sep;
const dashes = chat_store.dashes;
const transcriptPath = chat_paths.transcriptPath;
const readTranscript = chat_paths.readTranscript;
const dmConvDir = chat_paths.dmConvDir;
const decodeChatFile = chat_codec.decodeChatFile;
const believedCount = chat_count.believedCount;
const readCount = chat_count.readCount;
const countBlocks = chat_count.countBlocks;

/// chatStoredForm is exactly what message `index` contributes to the file: its
/// block, preceded by `sep` for every message after the first.
pub fn chatStoredForm(alloc: Alloc, index: usize, msg: ChatMessage) ![]u8 {
    const block = try encodeChatBlock(alloc, msg);
    if (index == 0) return block;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ sep, block });
}

/// encodeChatBlock renders one message to its on-disk block: the MSG_ id line,
/// the from/date header and, when the author is known, `uid:`; a blank line,
/// then the body with each line escaped against a separator collision.
pub fn encodeChatBlock(alloc: Alloc, msg: ChatMessage) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, msg.markdown, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try body.append(alloc, '\n');
        first = false;
        try body.appendSlice(alloc, try escapeBodyLine(alloc, line));
    }
    if (msg.uid.len == 0) return std.fmt.allocPrint(alloc, "MSG_{s}\nfrom: {s}\ndate: {s}\n\n{s}", .{ msg.id, msg.from, msg.at, body.items });
    return std.fmt.allocPrint(alloc, "MSG_{s}\nfrom: {s}\ndate: {s}\nuid: {s}\n\n{s}", .{ msg.id, msg.from, msg.at, msg.uid, body.items });
}

/// escapeBodyLine protects a body line that would collide with `sep` by
/// prepending a backslash — it matches `^\\*-------------$` (ZERO or more
/// backslashes then exactly 13 hyphens). Symmetric with unescapeBodyLine.
pub fn escapeBodyLine(alloc: Alloc, line: []const u8) ![]const u8 {
    var k: usize = 0;
    while (k < line.len and line[k] == '\\') k += 1;
    if (std.mem.eql(u8, line[k..], dashes)) return std.fmt.allocPrint(alloc, "\\{s}", .{line});
    return line;
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

pub const CodeBlock = struct { lang: []const u8, body: []const u8 };

pub const CodeEntry = struct {
    source_id: []const u8,
    from: []const u8,
    conv: []const u8,
    at: []const u8,
    blocks: []const CodeBlock,
};

/// formatCodeEntry serializes an entry: the shared header line, then each block
/// as ```<lang>\n<body>\n``` (always backticks), blocks separated by one newline.
///
/// **NO BODY HOLDS THE SEPARATOR** (metal-vmm QUEUE 266): a fenced body is a
/// member's text, and one holding `code_sep` then a `Sent by …` header would
/// read back as an entry of its own, from a sender who never sent it. Each
/// body line is escaped as a transcript's are (chat_codec.escapeBodyLine: a
/// line of backslashes then exactly 13 hyphens gains one backslash), so no
/// line of a body is the separator's; parseCodeFile takes the one off.
pub fn formatCodeEntry(alloc: Alloc, e: CodeEntry) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "Sent by {s} at {s}, source MSG_{s} in {s}:", .{ e.from, e.at, e.source_id, e.conv });
    for (e.blocks, 0..) |blk, i| {
        if (i > 0) try b.append(alloc, '\n');
        try b.print(alloc, "\n```{s}\n", .{blk.lang});
        var it = std.mem.splitScalar(u8, blk.body, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try b.append(alloc, '\n');
            first = false;
            try b.appendSlice(alloc, try escapeBodyLine(alloc, line));
        }
        try b.appendSlice(alloc, "\n```");
    }
    return b.toOwnedSlice(alloc);
}

/// images_sep joins entries on disk (blank line, 13 hyphens, blank line).
pub const images_sep = "\n\n-------------\n\n";

/// ImagesEntry is one decoded/encoded block. `at` is the RFC3339 string as
/// stored — the read+wire path needs no parsed timestamp, so the string suffices.
pub const ImagesEntry = struct {
    source_id: []const u8,
    from: []const u8,
    conv: []const u8,
    at: []const u8,
    images: []const []const u8,
};

/// formatImagesEntry serializes an entry to its on-disk text form (no leading or
/// trailing separator — the caller joins with images_sep).
pub fn formatImagesEntry(alloc: Alloc, e: ImagesEntry) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "Sent by {s} at {s}, source MSG_{s} in {s}:", .{ e.from, e.at, e.source_id, e.conv });
    for (e.images) |tag| {
        try b.append(alloc, '\n');
        // **A TAG IS ONE LINE** (metal-vmm QUEUE 185): a newline inside one
        // could carry `images_sep` and a header, planting a forged entry in
        // every member's images.md. In a tag it is whitespace, as a space is.
        for (tag) |c| try b.append(alloc, if (c == '\n' or c == '\r') ' ' else c);
    }
    return b.toOwnedSlice(alloc);
}
