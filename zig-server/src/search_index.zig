//! search_index: every chat message's words, held in memory (metal-vmm QUEUE
//! 155(b)), so a search reads no disk.
//!
//! **DERIVED FROM THE TRANSCRIPTS, NEVER WRITTEN.** Built once at boot, after
//! the sidecar backfill, one transcript at a time (`buildAll`, which
//! `app_start.setup` calls); kept current by `chat_store.appendMessage` as each message lands
//! (`noteAppend`; docs.zig and login.zig append through it too); and built
//! again whole after a retire applies (`rebuild`), which is rare and always
//! right. A host that never builds it gets one built by the first search.
//!
//! **BEHAVIOUR, NOT STRUCTURE** (small scale: four people, ~10 MB of chat):
//! per conversation, its messages' text in one buffer (held, rather than
//! offsets into the transcripts that would cost a read each), and a map from
//! each word to how many of its messages hold it. Words by prefix walk the
//! maps; the messages for a word are found by reading the text of each
//! conversation whose map holds the word. A query walks only the
//! conversations the viewer can see, given by the caller on every request
//! (`chat_paths.listVisibleConvs`), never a list kept from an earlier one.
//!
//! **FEW ALLOCATIONS, NOT FEW BYTES** (the measurements, 155(e)): Linux's
//! base allocator is the page allocator, a page at least for each, so a list
//! a word (132,000 of them in 10 MB) would hold hundreds of megabytes. Here
//! a conversation is a handful: its text, its messages, its map, and the
//! words in one arena.
//!
//! **ONE HANDLER AT A TIME** (server.zig's `turn`, zig-metal-unikernel's one loop):
//! nothing here locks.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_codec = @import("chat_codec.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const tokens = @import("search_tokens.zig");
const chat_store = @import("chat_store.zig");
const mem_meter = @import("webbox").mem_meter;

/// One message, as a query answers it: slices of the index's text, good
/// until the next message lands (one handler at a time: the answer is
/// written before then).
pub const Msg = struct {
    sid: []const u8,
    id: []const u8,
    from: []const u8,
    at: []const u8,
    markdown: []const u8,
};

/// Where a message's fields are in its conversation's text, one after another.
const Ref = struct { sid: u32, start: u32, id: u32, from: u32, at: u32, markdown: u32 };

const Conv = struct {
    text: std.ArrayList(u8) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    /// Its topics, each named once (in the index's arena).
    sids: std.ArrayList([]const u8) = .empty,
    /// A word (folded, in the index's arena) → how many messages hold it.
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    /// Transcripts of it the build could not read or decode (or the
    /// conversation itself, unlisted): a search here may miss their words.
    unreadable: u32 = 0,
    /// Past what the index's offsets hold (`add`): counted unreadable once,
    /// and nothing more of it indexed or read (metal-vmm QUEUE 177.6: each
    /// later topic was counted again, and each message landing there dropped
    /// the whole index).
    too_big: bool = false,

    fn deinit(c: *Conv, gpa: Alloc) void {
        c.text.deinit(gpa);
        c.refs.deinit(gpa);
        c.sids.deinit(gpa);
        c.counts.deinit(gpa);
    }

    fn msg(c: *const Conv, r: Ref) Msg {
        var at: usize = r.start;
        const t = c.text.items;
        const id = t[at..][0..r.id];
        at += r.id;
        const from = t[at..][0..r.from];
        at += r.from;
        const date = t[at..][0..r.at];
        at += r.at;
        return .{ .sid = c.sids.items[r.sid], .id = id, .from = from, .at = date, .markdown = t[at..][0..r.markdown] };
    }
};

/// What a build read, for the host's line and the measurements.
pub const Stats = struct {
    transcripts: usize = 0,
    messages: usize = 0,
    bytes: u64 = 0,
    /// Transcripts that could not be read or decoded: skipped and counted, so
    /// a search knows it may miss them.
    unreadable: usize = 0,
    /// Distinct words, summed over conversations.
    words: usize = 0,
};

pub const WordCount = struct { word: []const u8, count: usize };

pub const Found = struct {
    pub const Hit = struct { conv: chat_paths.Reach, msg: Msg };
    hits: []const Hit,
    /// Every message holding the word in the conversations walked, listed or not.
    matched: usize,
};

/// **ONE BLOCK OF A TRANSCRIPT, READ IN PLACE** (155's review): what
/// `chat_codec.decodeChatFile` makes of it, as slices of `piece` with no
/// copy, so the build's scratch is the transcript and not several times it.
/// A block whose body holds an escaped separator line, which the decoder
/// unescapes, goes through the decoder (into `a`).
///
/// Null for a block that is not a message (`chat_codec.isMessage`), refused
/// and counted as the decoder does: the two read the same messages.
fn inPlace(a: Alloc, piece: []const u8) !?chat_store.ChatMessage {
    if (std.mem.indexOf(u8, piece, "\\-------------") != null) {
        const got = try chat_codec.decodeChatFile(a, piece);
        return if (got.len > 0) got[0] else null;
    }
    const m = inPlaceRead(piece);
    if (!chat_codec.isMessage(m)) {
        chat_codec.refuseBlock(piece);
        return null;
    }
    return m;
}

fn inPlaceRead(piece: []const u8) chat_store.ChatMessage {
    var m: chat_store.ChatMessage = .{ .id = "", .from = "", .at = "", .markdown = "" };
    var lines = std.mem.splitScalar(u8, piece, '\n');
    var first = true;
    while (lines.next()) |ln| {
        if (first) {
            first = false;
            if (std.mem.startsWith(u8, ln, "MSG_")) {
                m.id = ln["MSG_".len..];
                continue;
            }
        }
        // A blank line ends the header; the body is everything after it.
        if (ln.len == 0) {
            m.markdown = piece[lines.index orelse piece.len ..];
            return m;
        }
        if (std.mem.indexOf(u8, ln, ": ")) |at| {
            const k = ln[0..at];
            if (std.mem.eql(u8, k, "from")) m.from = ln[at + 2 ..] else if (std.mem.eql(u8, k, "date")) m.at = ln[at + 2 ..];
        }
    }
    return m;
}

/// What a listing of messages may cost: `bytes` of what `cost` says each
/// message costs, which is what its caller sends of it (the review of 157:
/// the route sends an excerpt, and was charged the whole message).
pub const Budget = struct {
    bytes: usize = std.math.maxInt(usize),
    cost: *const fn (markdown: []const u8, word: []const u8) usize = wholeCost,
};

/// A message sent whole: its text as a JSON string writes it.
pub fn wholeCost(markdown: []const u8, _: []const u8) usize {
    return jsonCost(markdown);
}

/// **WHAT `s` COSTS AS A JSON STRING, AT MOST** (the review of 155's
/// follow-ups): a control byte as `\u00XX` (6), a quote or backslash
/// escaped (2), a byte >= 0x80 as U+FFFD if it is not UTF-8 (3, so every
/// such byte is charged 3). Raw bytes undercount it up to six times.
pub fn jsonCost(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += switch (c) {
        0...0x1F => 6,
        '"', '\\' => 2,
        0x80...0xFF => 3,
        else => 1,
    };
    return n;
}

/// Whether `markdown` holds `word` (folded) as a word of its own.
fn holds(markdown: []const u8, word: []const u8) bool {
    return wordAt(markdown, word) != null;
}

/// Where `word` (folded) first stands in `markdown` as a word of its own, as
/// the tokenizer reads one: the byte offset, or null. What a search marks
/// (chat_search's excerpt), so the mark is the word the index counted.
pub fn wordAt(markdown: []const u8, word: []const u8) ?usize {
    // Most messages do not hold it even as a substring: a quick no.
    if (std.ascii.findIgnoreCase(markdown, word) == null) return null;
    var it = tokens.words(markdown);
    while (it.next()) |w| {
        if (w.len == word.len and std.ascii.eqlIgnoreCase(w, word)) return @intFromPtr(w.ptr) - @intFromPtr(markdown.ptr);
    }
    return null;
}

pub const Index = struct {
    gpa: Alloc,
    /// The words and the topic names: small, many, never freed one by one.
    strings: std.heap.ArenaAllocator,
    /// By conversation directory, as `chat_store` spells it (in `strings`).
    convs: std.StringHashMapUnmanaged(Conv) = .empty,
    /// One message's words, each once: kept between messages, cleared.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    fold: std.ArrayList(u8) = .empty,
    stats: Stats = .{},
    /// Every conversation's text, in all (`text_most_total`).
    text_bytes: u64 = 0,

    pub fn init(gpa: Alloc) Index {
        return .{ .gpa = gpa, .strings = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Index) void {
        var it = self.convs.valueIterator();
        while (it.next()) |c| c.deinit(self.gpa);
        self.convs.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.fold.deinit(self.gpa);
        self.strings.deinit();
    }

    fn convOf(self: *Index, conv_dir: []const u8) !*Conv {
        const gop = try self.convs.getOrPut(self.gpa, conv_dir);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.strings.allocator().dupe(u8, conv_dir) catch |e| {
                self.convs.removeByPtr(gop.key_ptr);
                return e;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn unreadableIn(self: *Index, conv_dir: []const u8) !void {
        (try self.convOf(conv_dir)).unreadable += 1;
        self.stats.unreadable += 1;
    }

    /// One message, at the end of its conversation.
    pub fn add(self: *Index, conv_dir: []const u8, sid: []const u8, m: chat_store.ChatMessage) !void {
        const s = self.strings.allocator();
        const c = try self.convOf(conv_dir);
        if (c.too_big) return error.ConversationTooBig;
        // The topic: the last one named, as a build names them in turn.
        const sid_at: u32 = for (0..c.sids.items.len) |k| {
            const back = c.sids.items.len - 1 - k;
            if (std.mem.eql(u8, c.sids.items[back], sid)) break @intCast(back);
        } else blk: {
            try c.sids.append(self.gpa, try s.dupe(u8, sid));
            break :blk @intCast(c.sids.items.len - 1);
        };
        const start = c.text.items.len;
        const len = m.id.len + m.from.len + m.at.len + m.markdown.len;
        // A size the index's offsets cannot hold: said as what it is, never
        // as memory run out (metal-vmm QUEUE 172). **AND ALL OF IT, AT MOST
        // `text_most_total`** (metal-vmm QUEUE 184): any member's messages
        // grew the base heap (the kernel's fixed one) without bound. Past it,
        // the conversation the message is in is past what is indexed, as one
        // too big for its offsets is: said once, and searched no further.
        if (start + len > text_most_for_test orelse std.math.maxInt(u32) or
            self.text_bytes + len > total_most_for_test orelse text_most_total)
        {
            c.too_big = true;
            c.unreadable += 1;
            self.stats.unreadable += 1;
            return error.ConversationTooBig;
        }
        try c.refs.ensureUnusedCapacity(self.gpa, 1);
        try c.text.ensureUnusedCapacity(self.gpa, m.id.len + m.from.len + m.at.len + m.markdown.len);
        for ([_][]const u8{ m.id, m.from, m.at, m.markdown }) |f| c.text.appendSliceAssumeCapacity(f);
        self.text_bytes += len;
        c.refs.appendAssumeCapacity(.{ .sid = sid_at, .start = @intCast(start), .id = @intCast(m.id.len), .from = @intCast(m.from.len), .at = @intCast(m.at.len), .markdown = @intCast(m.markdown.len) });
        self.stats.messages += 1;

        // Each word of it, once.
        self.seen.clearRetainingCapacity();
        var it = tokens.words(m.markdown);
        while (it.next()) |w| {
            try self.fold.resize(self.gpa, w.len);
            const k = tokens.fold(w, self.fold.items);
            const p = try c.counts.getOrPut(self.gpa, k);
            if (!p.found_existing) {
                p.key_ptr.* = s.dupe(u8, k) catch |e| {
                    c.counts.removeByPtr(p.key_ptr);
                    return e;
                };
                p.value_ptr.* = 0;
                self.stats.words += 1;
            }
            // Keyed by the map's own copy, which lives as long as the index.
            const once = try self.seen.getOrPut(self.gpa, p.key_ptr.*);
            if (!once.found_existing) p.value_ptr.* += 1;
        }
    }

    /// Every transcript of `conv_dirs`, read one at a time into `scratch`'s
    /// arena and given back before the next; then each text trimmed to fit.
    ///
    /// **OUT OF MEMORY FAILS THE BUILD** (155's review): a transcript too big
    /// for the scratch is not one that cannot be read, and an index that
    /// quietly missed it would answer with confidence and wrong counts. Only
    /// a transcript that will not read or decode is counted unreadable, in
    /// its conversation, and a search there says so.
    pub fn build(self: *Index, io: Io, scratch: Alloc, conv_dirs: []const []const u8) !void {
        var per = std.heap.ArenaAllocator.init(scratch);
        defer per.deinit();
        for (conv_dirs) |dir| {
            // absent-ok: a conversation that will not list is counted unreadable and skipped; nothing is written from it.
            const sids = chat_paths.listTopics(io, scratch, dir) catch |e| {
                if (e == error.OutOfMemory) return e;
                try self.unreadableIn(dir);
                continue;
            };
            for (sids) |sid| {
                // Past what is indexed: its later topics are not read.
                if (self.convs.getPtr(dir)) |c| if (c.too_big) break;
                _ = per.reset(.retain_capacity);
                const a = per.allocator();
                self.stats.transcripts += 1;
                // absent-ok: a transcript that cannot be read is counted unreadable, never taken as empty.
                const raw = (chat_paths.readTranscript(io, a, dir, sid) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    try self.unreadableIn(dir);
                    continue;
                }) orelse {
                    try self.unreadableIn(dir);
                    continue;
                };
                self.stats.bytes += raw.len;
                var blocks = std.mem.splitSequence(u8, raw, chat_store.sep);
                while (blocks.next()) |piece| {
                    if (std.mem.trim(u8, piece, " \t\r\n").len == 0) continue;
                    if (try inPlace(a, piece)) |m| self.add(dir, sid, m) catch |e| switch (e) {
                        // That conversation is past what is indexed: unreadable
                        // in it (once, `add`), and the rest of the site still
                        // searched.
                        error.ConversationTooBig => break,
                        else => return e,
                    };
                }
            }
        }
        // **ROOM LEFT TO GROW** (the box's review of 155): trimmed to the
        // byte, the first message to land would grow a buffer by half, both
        // copies live at once; an eighth more is room for a while.
        // Shrunk in place where the allocator can; left as grown where not.
        var it = self.convs.valueIterator();
        while (it.next()) |c| {
            const t = c.text.items.len + c.text.items.len / 8;
            if (t < c.text.capacity and self.gpa.resize(c.text.allocatedSlice(), t)) c.text.capacity = t;
            const r = c.refs.items.len + c.refs.items.len / 8;
            if (r < c.refs.capacity and self.gpa.resize(c.refs.allocatedSlice(), r)) c.refs.capacity = r;
        }
        self.seen.clearAndFree(self.gpa);
        self.fold.clearAndFree(self.gpa);
    }

    /// Transcripts the build could not read, in the conversations of `reach`.
    pub fn unreadableFor(self: *const Index, reach: []const chat_paths.Reach) usize {
        var n: usize = 0;
        for (reach) |r| n += if (self.convs.getPtr(r.dir)) |c| c.unreadable else 0;
        return n;
    }

    /// At most `most` words beginning with `prefix` (a key, folded), each
    /// with how many messages hold it in the conversations of `reach` and no
    /// others: most first, then by word.
    pub fn wordsFor(self: *const Index, alloc: Alloc, reach: []const chat_paths.Reach, prefix: []const u8, most: usize) ![]WordCount {
        var sums: std.StringHashMapUnmanaged(usize) = .empty;
        for (reach) |r| {
            const c = self.convs.getPtr(r.dir) orelse continue;
            var it = c.counts.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.len > tokens.max_word) continue; // no key names it
                if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
                const g = try sums.getOrPut(alloc, e.key_ptr.*);
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += e.value_ptr.*;
            }
        }
        var out: std.ArrayList(WordCount) = .empty;
        var it = sums.iterator();
        while (it.next()) |e| try out.append(alloc, .{ .word = e.key_ptr.*, .count = e.value_ptr.* });
        std.mem.sort(WordCount, out.items, {}, mostFirst);
        return out.items[0..@min(most, out.items.len)];
    }

    /// The messages holding `word` (a key, folded) in the conversations of
    /// `reach` and no others, in `reach`'s order, each conversation's in the
    /// order they came; at most `most` listed, and what they cost at most
    /// `budget.bytes` (past it the listing stops; the first is always
    /// listed), every one counted.
    pub fn messagesFor(self: *const Index, alloc: Alloc, reach: []const chat_paths.Reach, word: []const u8, most: usize, budget: Budget) !Found {
        var hits: std.ArrayList(Found.Hit) = .empty;
        var matched: usize = 0;
        var bytes: usize = 0;
        var full = false;
        for (reach) |r| {
            const c = self.convs.getPtr(r.dir) orelse continue;
            const n = c.counts.get(word) orelse continue;
            matched += n;
            if (full or hits.items.len == most) continue;
            var left = n;
            for (c.refs.items) |ref| {
                if (left == 0 or hits.items.len == most) break;
                const m = c.msg(ref);
                if (!holds(m.markdown, word)) continue;
                left -= 1;
                const cost = budget.cost(m.markdown, word);
                if (hits.items.len > 0 and bytes + cost > budget.bytes) {
                    full = true;
                    break;
                }
                bytes += cost;
                try hits.append(alloc, .{ .conv = r, .msg = m });
            }
        }
        return .{ .hits = hits.items, .matched = matched };
    }
};

fn mostFirst(_: void, a: WordCount, b: WordCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.word, b.word);
}

// ── the one index the routes ask ─────────────────────────────────────────────

var the: ?Index = null;
/// When the last build failed (the monotonic clock, ms), if it did: a search
/// does not build again until `retry_ms` after, so a corpus too big for the
/// memory is not read whole on every search.
var failed_at_ms: ?i64 = null;
/// Why the last build failed, for the start's report (it guessed "out of
/// memory?" for every failure: metal-vmm QUEUE 172).
pub var failed_with: ?anyerror = null;
/// A test's own limit on a conversation's indexed text, in place of what
/// the offsets hold (4 GiB, which no test writes).
pub var text_most_for_test: ?u64 = null;
/// The most text the index holds in all (its words and refs come on top,
/// about as much again): 64 MiB.
pub const text_most_total: u64 = 64 << 20;
pub var total_most_for_test: ?u64 = null;
pub const retry_ms = 60_000;

/// Every transcript on disk into memory, once, before the first request:
/// `app_start.setup` calls it after the sidecar backfill. `scratch` is for the
/// reading only, given back as each transcript is done; the index itself
/// lives on the process's allocator (`mem_meter.base()`). Answers what it
/// read; on failure (out of memory) there is no index, and the first search
/// tries again.
pub fn buildAll(io: Io, scratch: Alloc) ?Stats {
    drop();
    var idx = Index.init(mem_meter.base());
    // absent-ok: no conversations listed is no index, and the first search builds again; nothing is written.
    const dirs = chat_paths.listConvDirs(io, scratch) catch |e| {
        idx.deinit();
        failed_at_ms = readNowMs(io);
        failed_with = e;
        return null;
    };
    idx.build(io, scratch, dirs) catch |e| {
        idx.deinit();
        failed_at_ms = readNowMs(io);
        failed_with = e;
        return null;
    };
    the = idx;
    failed_at_ms = null;
    failed_with = null;
    return idx.stats;
}

fn readNowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

/// The index, built now if no host built it, or a failure dropped it, but
/// not within `retry_ms` of a build that failed.
pub fn indexOrBuild(io: Io, scratch: Alloc) ?*Index {
    if (the == null) {
        const now = readNowMs(io);
        const waiting = if (failed_at_ms) |t| now >= t and now - t < retry_ms else false;
        if (!waiting) _ = buildAll(io, scratch);
    }
    return if (the) |*i| i else null;
}

/// A message that landed (`chat_store.appendMessage`). Before the index is
/// built there is nothing to do: the build reads it from the disk. A failure
/// drops the whole index, so no search answers from one that misses it, and
/// waits `retry_ms` as a failed build does: the memory that refused one
/// message would refuse a build at once (the box's review of 155).
pub fn noteAppend(io: Io, conv_dir: []const u8, sid: []const u8, m: chat_store.ChatMessage) void {
    if (the) |*i| i.add(conv_dir, sid, m) catch |e| switch (e) {
        // Past what is indexed: the index says so, once, and stands (177.6).
        error.ConversationTooBig => {},
        else => {
            drop();
            failed_at_ms = readNowMs(io);
        },
    };
}

/// After a retire applies: the whole index again, from the disk. With no
/// index there is nothing to do: the next search builds one.
pub fn rebuild(io: Io, scratch: Alloc) void {
    if (the == null) return;
    _ = buildAll(io, scratch);
}

/// **FOR A TEST: NO INDEX NOW, AND NONE AFTER** (`defer emptied.end()`;
/// 157(e)), where tests dropped it at their start and deferred a second drop
/// by hand.
pub fn emptyForTest() Emptied {
    drop();
    return .{};
}

pub const Emptied = struct {
    pub fn end(_: Emptied) void {
        drop();
    }
};

/// No index: the next search builds one. For tests, and failures.
pub fn drop() void {
    if (the) |*i| i.deinit();
    the = null;
    failed_at_ms = null;
}

/// What the last build read, and what has landed since, or null with no index.
pub fn stats() ?Stats {
    return if (the) |i| i.stats else null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const roots = @import("roots.zig");

fn msg(id: []const u8, text: []const u8) chat_store.ChatMessage {
    return .{ .id = id, .from = "Tester", .at = "2026-10-10T00:00:00Z", .markdown = text };
}

test "words by prefix, counted by message, only in the conversations asked about" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try idx.add("c/1_2", "t", msg("t_1", "The layout, the LAYOUT, and a layover"));
    try idx.add("c/1_2", "t", msg("t_2", "a player plays"));
    try idx.add("c/2_3", "u", msg("u_1", "the layaway plan"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mine = [_]chat_paths.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
    const got = try idx.wordsFor(a, &mine, "lay", 20);
    try testing.expectEqual(@as(usize, 2), got.len);
    // "layout" in one message, however often; "layaway" not here.
    try testing.expectEqualStrings("layout", got[0].word);
    try testing.expectEqual(@as(usize, 1), got[0].count);
    try testing.expectEqualStrings("layover", got[1].word);
    // "the" twice in t_1 is one message; "the layaway" is not in mine.
    const the_words = try idx.wordsFor(a, &mine, "the", 20);
    try testing.expectEqual(@as(usize, 1), the_words.len);
    try testing.expectEqual(@as(usize, 1), the_words[0].count);
    // Both conversations: counts sum.
    const both = [_]chat_paths.Reach{ mine[0], .{ .dir = "c/2_3", .base = "/chat/c/2_3", .kind = .dm } };
    const summed = try idx.wordsFor(a, &both, "the", 20);
    try testing.expectEqual(@as(usize, 2), summed[0].count);
    // At most `most`, the most held first.
    try testing.expectEqual(@as(usize, 1), (try idx.wordsFor(a, &both, "", 1)).len);
}

test "messages for a word, at most so many listed and every one counted" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    for (0..7) |i| {
        var buf: [16]u8 = undefined;
        try idx.add("c/1_2", "t", msg(try std.fmt.bufPrint(&buf, "t_{d}", .{i + 1}), if (i % 2 == 0) "dinner tonight?" else "no"));
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mine = [_]chat_paths.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
    const f = try idx.messagesFor(arena.allocator(), &mine, "tonight", 3, .{});
    try testing.expectEqual(@as(usize, 4), f.matched);
    try testing.expectEqual(@as(usize, 3), f.hits.len);
    try testing.expectEqualStrings("t_1", f.hits[0].msg.id);
    try testing.expectEqualStrings("t_3", f.hits[1].msg.id);
    try testing.expectEqualStrings("dinner tonight?", f.hits[0].msg.markdown);
    // A word that is only a prefix finds nothing: words are whole.
    try testing.expectEqual(@as(usize, 0), (try idx.messagesFor(arena.allocator(), &mine, "tonig", 10, .{})).matched);
}

test "an index that runs out of memory part way can be dropped without a leak" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 7 });
    var idx = Index.init(failing.allocator());
    defer idx.deinit();
    var hit_oom = false;
    for (0..20) |i| {
        var buf: [16]u8 = undefined;
        idx.add("c/1_2", "t", msg(try std.fmt.bufPrint(&buf, "t_{d}", .{i}), "some words here and there")) catch {
            hit_oom = true;
            break;
        };
    }
    try testing.expect(hit_oom);
}

test "fs: a build out of memory fails, never an index missing what it could not hold; an append out of memory drops the index (155's review)" {
    const store = @import("webbox").store;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    var body: std.ArrayList(u8) = .empty;
    for (0..200) |i| {
        if (i > 0) try body.appendSlice(a, chat_store.sep);
        try body.print(a, "MSG_t_{d}\nfrom: Tester\ndate: 2026-10-10T00:00:00Z\n\nwords of message {d}, and more words", .{ i + 1, i });
    }
    try store.write(io, a, try chat_paths.transcriptPath(a, try chat_paths.dmConvDir(a, "1_2"), "t"), body.items, .{});

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const meter = mem_meter.useForTest(failing.allocator());
    defer meter.restore();
    const emptied = emptyForTest();
    defer emptied.end();

    // A scratch too small for the transcript: no index, not one without it.
    var small: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&small);
    try testing.expectEqual(@as(?Stats, null), buildAll(io, fba.allocator()));
    try testing.expectEqual(@as(?Stats, null), stats());
    // And a search does not build again at once.
    try testing.expectEqual(@as(?*Index, null), indexOrBuild(io, fba.allocator()));

    // With room: every message, none unreadable.
    const s = buildAll(io, a).?;
    try testing.expectEqual(@as(usize, 200), s.messages);
    try testing.expectEqual(@as(usize, 0), s.unreadable);

    // An append the memory refuses drops the whole index.
    failing.fail_index = failing.alloc_index;
    noteAppend(io, try chat_paths.dmConvDir(a, "1_2"), "t", msg("t_201", "a brand new word"));
    try testing.expectEqual(@as(?Stats, null), stats());
    // And a search does not build it again at once (the box's review of 155, 3).
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(@as(?*Index, null), indexOrBuild(io, a));
}

test "a block read in place is what the decoder makes of it (155's review)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sep = chat_store.sep;
    const file = "MSG_t_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nhello\nthere\n\n  indented" ++ sep ++
        "MSG_t_2\nfrom: A: B\nnote: x\ndate: d\n\n" ++ sep ++ // an empty body; a colon in the name
        "MSG_t_3\nfrom: C\ndate: d\n" ++ sep ++ // no blank line: no body
        "\nfrom: D\ndate: d\n\nno id line" ++ sep ++ // the first line empty: refused by both
        "MSG_t_5\nfrom: E\ndate: d\n\nabove\n\\-------------\nbelow" ++ sep ++ // an escaped separator line
        "not a header\n\nbody" ++ sep ++ "  \n\t" ++ sep ++ "MSG_t_8\nfrom: F\ndate: d\n\nlast" ++ sep ++
        "MSG_t_9\nfrom: G\n\nno date" ++ sep ++ // refused by both
        // A `uid:` line, which this reader does not take, as a server from
        // before `uid:` did not: the rest of the block reads the same.
        "MSG_t_10\nfrom: H\ndate: d\nuid: 7\n\nwith its author's account";
    const want = try chat_codec.decodeChatFile(a, file);
    var got: std.ArrayList(chat_store.ChatMessage) = .empty;
    var blocks = std.mem.splitSequence(u8, file, sep);
    while (blocks.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t\r\n").len == 0) continue;
        if (try inPlace(a, piece)) |m| try got.append(a, m);
    }
    try testing.expectEqual(@as(usize, 6), want.len); // t_1, t_2, t_3, t_5, t_8, t_10
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqualStrings(w.id, g.id);
        try testing.expectEqualStrings(w.from, g.from);
        try testing.expectEqualStrings(w.at, g.at);
        try testing.expectEqualStrings(w.markdown, g.markdown);
    }
    try testing.expectEqualStrings("7", want[5].uid);
    try testing.expectEqualStrings("with its author's account", got.items[5].markdown);
}

test "messages for a word stop at a byte budget, every one still counted (the box's review of 155, 1)" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    const long = "word " ++ &@as([995]u8, @splat('x'));
    for (0..3) |i| {
        var buf: [16]u8 = undefined;
        try idx.add("c/1_2", "t", msg(try std.fmt.bufPrint(&buf, "t_{d}", .{i + 1}), long));
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mine = [_]chat_paths.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
    const f = try idx.messagesFor(arena.allocator(), &mine, "word", 10, .{ .bytes = 2500 });
    try testing.expectEqual(@as(usize, 3), f.matched);
    try testing.expectEqual(@as(usize, 2), f.hits.len);
    // One message past the whole budget is still listed: the first always is.
    try testing.expectEqual(@as(usize, 1), (try idx.messagesFor(arena.allocator(), &mine, "word", 10, .{ .bytes = 10 })).hits.len);
}

test "a word too long to ask for is never suggested (the box's review of 155, 2)" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try idx.add("c/1_2", "t", msg("t_1", &@as([tokens.max_word + 1]u8, @splat('a')) ++ " " ++ &@as([tokens.max_word]u8, @splat('a'))));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mine = [_]chat_paths.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
    const got = try idx.wordsFor(arena.allocator(), &mine, "aaa", 20);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(tokens.max_word, got[0].word.len);
    // And what is suggested, a key of it finds.
    var buf: [tokens.max_word]u8 = undefined;
    const k = tokens.key(got[0].word, &buf);
    try testing.expectEqual(@as(usize, 1), (try idx.messagesFor(arena.allocator(), &mine, k, 10, .{})).matched);
}

test "the budget is charged what the JSON costs, not the raw bytes (the review of 155's follow-ups)" {
    try testing.expectEqual(@as(usize, 6 + 2 + 2 + 3 + 1), jsonCost("\x01\"\\\xff" ++ "a"));
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    // Two messages of 1000 raw bytes, nearly all control bytes: 6000 each.
    const hostile = "word " ++ repeated("\x01", 995);
    try idx.add("c/1_2", "t", msg("t_1", hostile));
    try idx.add("c/1_2", "t", msg("t_2", hostile));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mine = [_]chat_paths.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
    const f = try idx.messagesFor(arena.allocator(), &mine, "word", 10, .{ .bytes = 8000 });
    try testing.expectEqual(@as(usize, 2), f.matched);
    try testing.expectEqual(@as(usize, 1), f.hits.len);
}

test "a build that cannot list the conversations says why: its error, never a guess of memory (metal-vmm QUEUE 172)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = try @import("roots.zig").pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved.restore();
    const meter = mem_meter.useForTest(std.testing.allocator);
    defer meter.restore();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The chat root is a file: it cannot be listed.
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(chat_store.chat_root).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = chat_store.chat_root, .data = "not a folder" });
    try std.testing.expect(buildAll(io, a) == null);
    try std.testing.expect(failed_with != null);
    try std.testing.expect(failed_with.? != error.OutOfMemory);
}

test "a conversation past what the index holds is unreadable once, and a message landing there keeps the index (metal-vmm QUEUE 177.6)" {
    text_most_for_test = 64;
    defer text_most_for_test = null;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const meter = mem_meter.useForTest(testing.allocator);
    defer meter.restore();
    const emptied = emptyForTest();
    defer emptied.end();
    the = Index.init(testing.allocator);
    try the.?.add("c/1_2", "t", msg("t_1", "a word"));
    // Past the limit: unreadable in it, once, whatever lands after, in that
    // topic or a later one.
    try testing.expectError(error.ConversationTooBig, the.?.add("c/1_2", "t", msg("t_2", &@as([80]u8, @splat('x')))));
    try testing.expectError(error.ConversationTooBig, the.?.add("c/1_2", "u", msg("u_1", "y")));
    try testing.expectEqual(@as(u32, 1), the.?.convs.getPtr("c/1_2").?.unreadable);
    // A message landing there: the index stands (it was dropped, and built
    // again, for every message), and says the conversation once.
    noteAppend(threaded.io(), "c/1_2", "t", msg("t_3", "z"));
    try testing.expect(the != null);
    try testing.expectEqual(@as(u32, 1), the.?.convs.getPtr("c/1_2").?.unreadable);
    // Another conversation is indexed as before.
    noteAppend(threaded.io(), "c/1_3", "t", msg("t_1", "fine"));
    try testing.expectEqual(@as(usize, 2), the.?.stats.messages);
}

test "the index holds at most its total of text: past it, the conversation a message lands in is unreadable once, and the index stands (metal-vmm QUEUE 184)" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    const one = msg("t_1", "a word");
    const len = one.id.len + one.from.len + one.at.len + one.markdown.len;
    total_most_for_test = 3 * len;
    defer total_most_for_test = null;
    // Exactly the total, over two conversations: all held.
    try idx.add("c/1_2", "t", one);
    try idx.add("c/1_2", "t", msg("t_2", "a word"));
    try idx.add("c/1_3", "t", msg("t_1", "a word"));
    try testing.expectEqual(@as(u64, 3 * len), idx.text_bytes);
    // One more: unreadable in its conversation, once, and nothing grows.
    try testing.expectError(error.ConversationTooBig, idx.add("c/1_4", "t", msg("t_1", "a word")));
    try testing.expectError(error.ConversationTooBig, idx.add("c/1_4", "t", msg("t_2", "a word")));
    try testing.expectEqual(@as(u32, 1), idx.convs.getPtr("c/1_4").?.unreadable);
    try testing.expectEqual(@as(u64, 3 * len), idx.text_bytes);
    try testing.expectEqual(@as(usize, 3), idx.stats.messages);
}

/// `s` repeated `n` times, built at comptime (Zig 0.17 removed `s ** n`).
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        var a: [s.len * n]u8 = undefined;
        @setEvalBranchQuota(1000 + n);
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}
