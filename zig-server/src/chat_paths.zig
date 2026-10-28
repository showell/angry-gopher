//! chat_paths: where conversations live and who may reach them: DM and
//! channel directories, topics, channel members, the viewer's walk, and the
//! validators every path is checked by (split from chat_store.zig by
//! metal-vmm QUEUE 174).

const std = @import("std");
const decimal = @import("decimal.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const bus_mod = @import("webbox").bus;
const Bus = bus_mod.Bus;
const users = @import("users.zig");
const testing = std.testing;
const chat_store = @import("chat_store.zig");
const CountFixture = chat_store.CountFixture;
const cutSeq = chat_store.cutSeq;
const ConvKind = chat_store.ConvKind;

/// A conversation one viewer may read: its directory, its URL root, and what
/// kind it is.
pub const Reach = struct { dir: []const u8, base: []const u8, kind: ConvKind };

/// **WHAT ONE VIEWER CAN SEE**, as the sidebar lists it: a DM with every
/// other authorized member, and every channel they are a member of. A reader
/// across conversations walks this list and nothing else, so nothing outside
/// it can reach the viewer: the boundary is the walk.
///
/// **NARROWER THAN THE ROUTES, ON PURPOSE**: the DM route also opens a DM with
/// an account that has no password yet, and the viewer's own (`1_1`); neither
/// is listed here, as the sidebar lists neither. A name the routes would
/// refuse (a uid not canonical, a channel name not valid) is skipped too, so
/// the walk is never wider than what the routes open.
pub fn listVisibleConvs(io: Io, alloc: Alloc, uid: []const u8) ![]Reach {
    var out: std.ArrayList(Reach) = .empty;
    for (try users.listAuthorized(io, alloc)) |partner| {
        if (std.mem.eql(u8, partner.id, uid)) continue;
        if (!canonicalUid(partner.id)) continue;
        const conv = try chatPairKey(alloc, uid, partner.id);
        try out.append(alloc, .{ .dir = try dmConvDir(alloc, conv), .base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv}), .kind = .dm });
    }
    for (try listUserChannels(io, alloc, uid)) |name| {
        if (!validChannelName(name)) continue;
        try out.append(alloc, .{ .dir = try channelConvDir(alloc, name), .base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name}), .kind = .channel });
    }
    return out.toOwnedSlice(alloc);
}

/// listConvDirs is every conversation on disk: each DM directory directly under
/// chat_store.chat_root, and each channel under `channels/`. For a pass over all of them,
/// where the per-viewer listings are not the question.
pub fn listConvDirs(io: Io, alloc: Alloc) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const entries = try store.list(io, alloc, chat_store.chat_root);
    for (entries) |entry| {
        if (entry.kind != .directory) continue;
        // Not a conversation: per-uid state (last-conv, last-sessions) lives here.
        if (std.mem.eql(u8, entry.name, "users")) continue;
        if (std.mem.eql(u8, entry.name, "channels")) {
            const channels = try std.fs.path.join(alloc, &.{ chat_store.chat_root, "channels" });
            const chans = try store.list(io, alloc, channels);
            for (chans) |ch| {
                if (ch.kind != .directory) continue;
                try out.append(alloc, try std.fs.path.join(alloc, &.{ channels, ch.name }));
            }
            continue;
        }
        try out.append(alloc, try std.fs.path.join(alloc, &.{ chat_store.chat_root, entry.name }));
    }
    return out.toOwnedSlice(alloc);
}

/// dmConvDir is {chat_store.chat_root}/<conv>. `conv` is the already-canonical pair key
/// (e.g. "1_2"); callers gate it through chatKeyParticipant first.
pub fn dmConvDir(alloc: Alloc, conv: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ chat_store.chat_root, conv });
}

/// channelConvDir is {chat_store.chat_root}/channels/<name>.
pub fn channelConvDir(alloc: Alloc, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ chat_store.chat_root, "channels", name });
}

/// transcriptPath is {conv_dir}/sessions/<sid>.md.
pub fn transcriptPath(alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.md", .{sid});
    return std.fs.path.join(alloc, &.{ conv_dir, "sessions", file });
}

/// readTranscript reads a topic's literal on-disk transcript bytes, or null when
/// the file is missing/unreadable.
/// The /raw view serves
/// these bytes verbatim.
pub fn readTranscript(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !?[]u8 {
    const path = try transcriptPath(alloc, conv_dir, sid);
    return store.readOrNull(io, alloc, path, .unlimited);
}

/// listTopics returns the topic ids (the `.md` basenames) under
/// {conv_dir}/sessions, sorted ascending. Missing dir → empty.
pub fn listTopics(io: Io, alloc: Alloc, conv_dir: []const u8) ![][]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions" });
    const entries = try store.list(io, alloc, dir_path);

    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const sid = entry.name[0 .. entry.name.len - ".md".len];
        try out.append(alloc, try alloc.dupe(u8, sid));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

/// findFirstTopic finds the topic a conversation opens on when nobody's last view
/// says otherwise: `firstOf` its topics, or "" for a conversation with none.
/// resumeTopic (chat_state) is the one that knows the viewer.
pub fn findFirstTopic(io: Io, alloc: Alloc, conv_dir: []const u8) ![]const u8 {
    return firstOf(try listTopics(io, alloc, conv_dir));
}

/// firstOf picks from a conversation's topics (listTopics, sorted): "ChitChat"
/// when present, else the alphabetically first, else "".
pub fn firstOf(topics: []const []const u8) []const u8 {
    for (topics) |s| {
        if (std.mem.eql(u8, s, "ChitChat")) return s;
    }
    if (topics.len > 0) return topics[0];
    return "";
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── channels ───────────────────────────────────────────

/// readChannelMembers reads {chat_store.chat_root}/channels/<name>.channel: one uid per line,
/// blank/`#`-comment lines skipped. Missing file → null (the channel does not
/// exist).
///
/// **A LINE IS A CANONICAL UID, ONCE, OR THE CHANNEL IS MALFORMED**
/// (metal-vmm QUEUE 156(d)): each member is a path the fan-out writes under
/// (`../../x` was one), a line with a comment after it (`3 # Claude`) dropped
/// that member, and a duplicate notified twice. `error.MalformedChannel`,
/// never a guess at what the line meant: whoever wrote the file fixes it.
/// Its own route refuses it; a listing skips and counts it.
pub fn readChannelMembers(io: Io, alloc: Alloc, name: []const u8) !?[][]const u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.channel", .{name});
    const path = try std.fs.path.join(alloc, &.{ chat_store.chat_root, "channels", file });
    const body = (try store.readOrNull(io, alloc, path, .unlimited)) orelse return null;

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!canonicalUid(line) or hasMember(out.items, line)) return error.MalformedChannel;
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

/// Channel files a listing skipped as malformed, since boot (Steve,
/// 2026-10-10, on 156(d)): a listing reads every channel for every member,
/// so one bad file made chat a 500 for everyone; now each listing that meets
/// it skips it, counts it, and names it on /admin/host (`malformedText`). The
/// channel's own route still refuses it. Counted per listing, not per file.
pub var malformed_channels: usize = 0;

var malformed_last_buf: [64]u8 = undefined;

pub var malformed_last: []const u8 = "";

/// The malformed channels as /admin/host shows them.
pub fn malformedText(alloc: Alloc) ![]const u8 {
    if (malformed_channels == 0) return "none";
    return std.fmt.allocPrint(alloc, "{d}; the last: #{s}", .{ malformed_channels, malformed_last });
}

/// listUserChannels returns the names of channels `uid` is a member of, sorted.
/// Scans {chat_store.chat_root}/channels/*.channel. Missing dir → empty.
pub fn listUserChannels(io: Io, alloc: Alloc, uid: []const u8) ![][]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ chat_store.chat_root, "channels" });
    const entries = try store.list(io, alloc, dir_path);

    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".channel")) continue;
        const name = entry.name[0 .. entry.name.len - ".channel".len];
        const members = (readChannelMembers(io, alloc, name) catch |e| switch (e) {
            error.MalformedChannel => {
                malformed_channels += 1;
                const n = @min(name.len, malformed_last_buf.len);
                @memcpy(malformed_last_buf[0..n], name[0..n]);
                malformed_last = malformed_last_buf[0..n];
                continue;
            },
            else => return e,
        }) orelse continue;
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
///
/// **BOTH HALVES ARE UIDS.** Each is a path component (the conversation's
/// folder) and the other is a member the fan-out writes for
/// ({chat_store.chat_root}/users/<member>/images.md), so each must be what allocateUser
/// makes: digits, with no leading zero. A half like `..` would otherwise
/// write one level up on Linux, and `05_5` and `5_05` would split one DM in
/// two. Whether the other
/// half is an account that exists is the route's to ask: this has no Io.
pub fn chatKeyParticipant(alloc: Alloc, key: []const u8, user: []const u8) !bool {
    const cut = cutSeq(key, "_") orelse return false;
    const x = cut.before;
    const y = cut.after;
    if (!canonicalUid(x) or !canonicalUid(y)) return false;
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

/// A uid as allocateUser writes one: digits, the first not zero.
fn canonicalUid(s: []const u8) bool {
    if (s.len == 0 or s[0] == '0') return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn atoiOr0(s: []const u8) i64 {
    return decimal.parseInt(i64, s) orelse 0;
}

/// validTopicID matches `^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$`
/// in 1..80 chars — alphanumerics joined by single hyphens, no leading/trailing/
/// double hyphen, no underscore/dot/slash. Doubles as the path-traversal guard
/// for any sid that flows into a sessions/<sid> filesystem path.
pub fn validTopicID(sid: []const u8) bool {
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

/// validMsgRefID matches `^[A-Za-z0-9-]+_[0-9]+$` — a topic slug, an
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

test "chatKeyParticipant: both halves are canonical uids, in order, and the user is one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try chatKeyParticipant(a, "1_2", "1"));
    try testing.expect(try chatKeyParticipant(a, "1_2", "2"));
    try testing.expect(try chatKeyParticipant(a, "2_10", "10"));
    try testing.expect(!try chatKeyParticipant(a, "1_2", "3"));
    try testing.expect(!try chatKeyParticipant(a, "2_1", "1")); // not canonical
    // The other half is checked too, not taken as any text.
    for ([_][]const u8{ ".._5", "._5", "abc_5", "05_5", "5_05", "0_5", "_5", "5_", "5_5_6", "5_6/x", "-1_5" }) |key| {
        try testing.expect(!try chatKeyParticipant(a, key, "5"));
    }
}

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

test "a channel's member lines are canonical uids, each once, or the channel is malformed (metal-vmm QUEUE 156(d))" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var f: CountFixture = undefined;
    try f.init(threaded.io());
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "team.channel" });
    try Io.Dir.cwd().createDirPath(f.io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(f.io, .{ .sub_path = path, .data = "# the team\n1\n\n 2 \r\n" });
    const ok = (try readChannelMembers(f.io, a, "team")).?;
    try testing.expectEqual(@as(usize, 2), ok.len);
    for ([_][]const u8{ "1\n../../x\n", "1\n3 # Claude\n", "1\n2\n1\n", "007\n", "+7\n" }) |bad| {
        try Io.Dir.cwd().writeFile(f.io, .{ .sub_path = path, .data = bad });
        try testing.expectError(error.MalformedChannel, readChannelMembers(f.io, a, "team"));
        // A listing skips it and counts it (Steve, 2026-10-10): one bad file
        // is not every member's chat down.
        const before = malformed_channels;
        try testing.expectEqual(@as(usize, 0), (try listUserChannels(f.io, a, "1")).len);
        try testing.expectEqual(before + 1, malformed_channels);
        try testing.expectEqualStrings("team", malformed_last);
    }
}

test "firstOf: ChitChat wins wherever it sorts, else the first, else none" {
    try std.testing.expectEqualStrings("ChitChat", firstOf(&.{ "2026-01-01", "ChitChat", "zebra" }));
    try std.testing.expectEqualStrings("2026-01-01", firstOf(&.{ "2026-01-01", "zebra" }));
    try std.testing.expectEqualStrings("", firstOf(&.{}));
}
