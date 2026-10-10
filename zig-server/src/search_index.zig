//! search_index: every chat message's words, held in memory (metal-vmm QUEUE
//! 155(b)), so a search reads no disk.
//!
//! **DERIVED FROM THE TRANSCRIPTS, NEVER WRITTEN.** Built once at boot, after
//! the sidecar backfill, one transcript at a time (`buildAll`, host contract
//! step 4b); kept current by `chat_store.appendMessage` as each message lands
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
//! (`chat_store.visibleConvs`), never a list kept from an earlier one.
//!
//! **FEW ALLOCATIONS, NOT FEW BYTES** (the measurements, 155(e)): Linux's
//! base allocator is the page allocator, a page at least for each, so a list
//! a word (132,000 of them in 10 MB) would hold hundreds of megabytes. Here
//! a conversation is a handful: its text, its messages, its map, and the
//! words in one arena.
//!
//! **ONE HANDLER AT A TIME** (server.zig's `turn`, gopher-metal's one loop):
//! nothing here locks.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const tokens = @import("search_tokens.zig");
const chat_store = @import("chat_store.zig");
const mem_meter = @import("mem_meter.zig");

/// One message, as a query answers it: slices of the index's text, good
/// until the next message lands (one handler at a time: the answer is
/// written before then).
pub const Msg = struct {
    sid: []const u8,
    id: []const u8,
    from: []const u8,
    date: []const u8,
    markdown: []const u8,
};

/// Where a message's fields are in its conversation's text, one after another.
const Ref = struct { sid: u32, start: u32, id: u32, from: u32, date: u32, markdown: u32 };

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
        const date = t[at..][0..r.date];
        at += r.date;
        return .{ .sid = c.sids.items[r.sid], .id = id, .from = from, .date = date, .markdown = t[at..][0..r.markdown] };
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
    pub const Hit = struct { conv: chat_store.Reach, msg: Msg };
    hits: []const Hit,
    /// Every message holding the word in the conversations walked, listed or not.
    matched: usize,
};

/// **ONE BLOCK OF A TRANSCRIPT, READ IN PLACE** (155's review): what
/// `chat_store.decodeChatFile` makes of it, as slices of `piece` with no
/// copy, so the build's scratch is the transcript and not several times it.
/// A block whose body holds an escaped separator line, which the decoder
/// unescapes, goes through the decoder (into `a`).
fn inPlace(a: Alloc, piece: []const u8) !chat_store.ChatMessage {
    if (std.mem.indexOf(u8, piece, "\\-------------") != null) return (try chat_store.decodeChatFile(a, piece))[0];
    var m: chat_store.ChatMessage = .{ .id = "", .from = "", .date = "", .markdown = "" };
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
            if (std.mem.eql(u8, k, "from")) m.from = ln[at + 2 ..] else if (std.mem.eql(u8, k, "date")) m.date = ln[at + 2 ..];
        }
    }
    return m;
}

/// Whether `markdown` holds `word` (folded) as a word of its own.
fn holds(markdown: []const u8, word: []const u8) bool {
    // Most messages do not hold it even as a substring: a quick no.
    if (std.ascii.indexOfIgnoreCase(markdown, word) == null) return false;
    var it = tokens.words(markdown);
    while (it.next()) |w| {
        if (w.len == word.len and std.ascii.eqlIgnoreCase(w, word)) return true;
    }
    return false;
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
        // The topic: the last one named, as a build names them in turn.
        const sid_at: u32 = for (0..c.sids.items.len) |k| {
            const back = c.sids.items.len - 1 - k;
            if (std.mem.eql(u8, c.sids.items[back], sid)) break @intCast(back);
        } else blk: {
            try c.sids.append(self.gpa, try s.dupe(u8, sid));
            break :blk @intCast(c.sids.items.len - 1);
        };
        const start = c.text.items.len;
        if (start + m.id.len + m.from.len + m.date.len + m.markdown.len > std.math.maxInt(u32)) return error.OutOfMemory;
        try c.refs.ensureUnusedCapacity(self.gpa, 1);
        try c.text.ensureUnusedCapacity(self.gpa, m.id.len + m.from.len + m.date.len + m.markdown.len);
        for ([_][]const u8{ m.id, m.from, m.date, m.markdown }) |f| c.text.appendSliceAssumeCapacity(f);
        c.refs.appendAssumeCapacity(.{ .sid = sid_at, .start = @intCast(start), .id = @intCast(m.id.len), .from = @intCast(m.from.len), .date = @intCast(m.date.len), .markdown = @intCast(m.markdown.len) });
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
            const sids = chat_store.listSessions(io, scratch, dir) catch |e| {
                if (e == error.OutOfMemory) return e;
                try self.unreadableIn(dir);
                continue;
            };
            for (sids) |sid| {
                _ = per.reset(.retain_capacity);
                const a = per.allocator();
                self.stats.transcripts += 1;
                // absent-ok: a transcript that cannot be read is counted unreadable, never taken as empty.
                const raw = (chat_store.rawSession(io, a, dir, sid) catch |e| {
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
                    try self.add(dir, sid, try inPlace(a, piece));
                }
            }
        }
        var it = self.convs.valueIterator();
        while (it.next()) |c| {
            c.text.shrinkAndFree(self.gpa, c.text.items.len);
            c.refs.shrinkAndFree(self.gpa, c.refs.items.len);
        }
        self.seen.clearAndFree(self.gpa);
        self.fold.clearAndFree(self.gpa);
    }

    /// Transcripts the build could not read, in the conversations of `reach`.
    pub fn unreadableFor(self: *const Index, reach: []const chat_store.Reach) usize {
        var n: usize = 0;
        for (reach) |r| n += if (self.convs.getPtr(r.dir)) |c| c.unreadable else 0;
        return n;
    }

    /// At most `most` words beginning with `prefix` (a key, folded), each
    /// with how many messages hold it in the conversations of `reach` and no
    /// others: most first, then by word.
    pub fn wordsFor(self: *const Index, alloc: Alloc, reach: []const chat_store.Reach, prefix: []const u8, most: usize) ![]WordCount {
        var sums: std.StringHashMapUnmanaged(usize) = .empty;
        for (reach) |r| {
            const c = self.convs.getPtr(r.dir) orelse continue;
            var it = c.counts.iterator();
            while (it.next()) |e| {
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
    /// order they came; at most `most` listed, every one counted.
    pub fn messagesFor(self: *const Index, alloc: Alloc, reach: []const chat_store.Reach, word: []const u8, most: usize) !Found {
        var hits: std.ArrayList(Found.Hit) = .empty;
        var matched: usize = 0;
        for (reach) |r| {
            const c = self.convs.getPtr(r.dir) orelse continue;
            const n = c.counts.get(word) orelse continue;
            matched += n;
            if (hits.items.len == most) continue;
            var left = n;
            for (c.refs.items) |ref| {
                if (left == 0 or hits.items.len == most) break;
                const m = c.msg(ref);
                if (!holds(m.markdown, word)) continue;
                left -= 1;
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
pub const retry_ms = 60_000;

/// **HOST CONTRACT STEP 4b**: once, after `chat_store.backfillAll`, before the
/// first request: every transcript on disk into memory. `scratch` is for the
/// reading only, given back as each transcript is done; the index itself
/// lives on the process's allocator (`mem_meter.base()`). Answers what it
/// read; on failure (out of memory) there is no index, and the first search
/// tries again.
pub fn buildAll(io: Io, scratch: Alloc) ?Stats {
    drop();
    var idx = Index.init(mem_meter.base());
    // absent-ok: no conversations listed is no index, and the first search builds again; nothing is written.
    const dirs = chat_store.listConvDirs(io, scratch) catch {
        idx.deinit();
        failed_at_ms = nowMs(io);
        return null;
    };
    idx.build(io, scratch, dirs) catch {
        idx.deinit();
        failed_at_ms = nowMs(io);
        return null;
    };
    the = idx;
    failed_at_ms = null;
    return idx.stats;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

/// The index, built now if no host built it, or a failure dropped it, but
/// not within `retry_ms` of a build that failed.
pub fn ready(io: Io, scratch: Alloc) ?*Index {
    if (the == null) {
        const now = nowMs(io);
        const waiting = if (failed_at_ms) |t| now >= t and now - t < retry_ms else false;
        if (!waiting) _ = buildAll(io, scratch);
    }
    return if (the) |*i| i else null;
}

/// A message that landed (`chat_store.appendMessage`). Before the index is
/// built there is nothing to do: the build reads it from the disk. A failure
/// drops the whole index, so no search answers from one that misses it.
pub fn noteAppend(conv_dir: []const u8, sid: []const u8, m: chat_store.ChatMessage) void {
    if (the) |*i| i.add(conv_dir, sid, m) catch drop();
}

/// After a retire applies: the whole index again, from the disk. With no
/// index there is nothing to do: the next search builds one.
pub fn rebuild(io: Io, scratch: Alloc) void {
    if (the == null) return;
    _ = buildAll(io, scratch);
}

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

fn msg(id: []const u8, text: []const u8) chat_store.ChatMessage {
    return .{ .id = id, .from = "Tester", .date = "2026-10-10T00:00:00Z", .markdown = text };
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
    const mine = [_]chat_store.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
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
    const both = [_]chat_store.Reach{ mine[0], .{ .dir = "c/2_3", .base = "/chat/c/2_3", .kind = .dm } };
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
    const mine = [_]chat_store.Reach{.{ .dir = "c/1_2", .base = "/chat/c/1_2", .kind = .dm }};
    const f = try idx.messagesFor(arena.allocator(), &mine, "tonight", 3);
    try testing.expectEqual(@as(usize, 4), f.matched);
    try testing.expectEqual(@as(usize, 3), f.hits.len);
    try testing.expectEqualStrings("t_1", f.hits[0].msg.id);
    try testing.expectEqualStrings("t_3", f.hits[1].msg.id);
    try testing.expectEqualStrings("dinner tonight?", f.hits[0].msg.markdown);
    // A word that is only a prefix finds nothing: words are whole.
    try testing.expectEqual(@as(usize, 0), (try idx.messagesFor(arena.allocator(), &mine, "tonig", 10)).matched);
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
    const store = @import("store.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = chat_store.chat_root;
    defer chat_store.chat_root = saved;
    chat_store.chat_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    var body: std.ArrayList(u8) = .empty;
    for (0..200) |i| {
        if (i > 0) try body.appendSlice(a, chat_store.sep);
        try body.print(a, "MSG_t_{d}\nfrom: Tester\ndate: 2026-10-10T00:00:00Z\n\nwords of message {d}, and more words", .{ i + 1, i });
    }
    try store.write(io, a, try chat_store.sessionMdPath(a, try chat_store.dmConvDir(a, "1_2"), "t"), body.items, .{});

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const prev = mem_meter.replace(failing.allocator());
    defer _ = mem_meter.replace(prev);
    defer drop();

    // A scratch too small for the transcript: no index, not one without it.
    var small: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&small);
    try testing.expectEqual(@as(?Stats, null), buildAll(io, fba.allocator()));
    try testing.expectEqual(@as(?Stats, null), stats());
    // And a search does not build again at once.
    try testing.expectEqual(@as(?*Index, null), ready(io, fba.allocator()));

    // With room: every message, none unreadable.
    const s = buildAll(io, a).?;
    try testing.expectEqual(@as(usize, 200), s.messages);
    try testing.expectEqual(@as(usize, 0), s.unreadable);

    // An append the memory refuses drops the whole index.
    failing.fail_index = failing.alloc_index;
    noteAppend(try chat_store.dmConvDir(a, "1_2"), "t", msg("t_201", "a brand new word"));
    try testing.expectEqual(@as(?Stats, null), stats());
}

test "a block read in place is what the decoder makes of it (155's review)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sep = chat_store.sep;
    const file = "MSG_t_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nhello\nthere\n\n  indented" ++ sep ++
        "MSG_t_2\nfrom: A: B\nnote: x\ndate: d\n\n" ++ sep ++ // an empty body; a colon in the name
        "MSG_t_3\nfrom: C\n" ++ sep ++ // no blank line: no body
        "\nfrom: D\n\nno id line" ++ sep ++ // the first line empty
        "MSG_t_5\nfrom: E\n\nabove\n\\-------------\nbelow" ++ sep ++ // an escaped separator line
        "not a header\n\nbody" ++ sep ++ "  \n\t" ++ sep ++ "MSG_t_8\n\nlast";
    const want = try chat_store.decodeChatFile(a, file);
    var got: std.ArrayList(chat_store.ChatMessage) = .empty;
    var blocks = std.mem.splitSequence(u8, file, sep);
    while (blocks.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t\r\n").len == 0) continue;
        try got.append(a, try inPlace(a, piece));
    }
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqualStrings(w.id, g.id);
        try testing.expectEqualStrings(w.from, g.from);
        try testing.expectEqualStrings(w.date, g.date);
        try testing.expectEqualStrings(w.markdown, g.markdown);
    }
}
