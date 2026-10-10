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

    /// One message, at the end of its conversation.
    pub fn add(self: *Index, conv_dir: []const u8, sid: []const u8, m: chat_store.ChatMessage) !void {
        const s = self.strings.allocator();
        const gop = try self.convs.getOrPut(self.gpa, conv_dir);
        if (!gop.found_existing) {
            gop.key_ptr.* = s.dupe(u8, conv_dir) catch |e| {
                self.convs.removeByPtr(gop.key_ptr);
                return e;
            };
            gop.value_ptr.* = .{};
        }
        const c = gop.value_ptr;
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
    pub fn build(self: *Index, io: Io, scratch: Alloc, conv_dirs: []const []const u8) !void {
        var per = std.heap.ArenaAllocator.init(scratch);
        defer per.deinit();
        for (conv_dirs) |dir| {
            // absent-ok: a conversation that will not list is counted unreadable and skipped; nothing is written from it.
            const sids = chat_store.listSessions(io, scratch, dir) catch {
                self.stats.unreadable += 1;
                continue;
            };
            for (sids) |sid| {
                _ = per.reset(.retain_capacity);
                const a = per.allocator();
                self.stats.transcripts += 1;
                // absent-ok: a transcript that cannot be read is counted unreadable, never taken as empty.
                const raw = (chat_store.rawSession(io, a, dir, sid) catch null) orelse {
                    self.stats.unreadable += 1;
                    continue;
                };
                self.stats.bytes += raw.len;
                const msgs = chat_store.decodeChatFile(a, raw) catch {
                    self.stats.unreadable += 1;
                    continue;
                };
                for (msgs) |m| try self.add(dir, sid, m);
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
        return null;
    };
    idx.build(io, scratch, dirs) catch {
        idx.deinit();
        return null;
    };
    the = idx;
    return idx.stats;
}

/// The index, built now if no host built it, or a failure dropped it.
pub fn ready(io: Io, scratch: Alloc) ?*Index {
    if (the == null) _ = buildAll(io, scratch);
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
