//! **THE ROC CHAT'S PURE MODULES, EACH HELD TO ITS ZIG TWIN** (roc-webbox
//! docs/ROC-CHAT.md C1, C2): every Roc function that will replace a Zig one
//! is called here beside it, through the test-only seam (`roc_chat_twin`,
//! roc-webbox chat/twin.roc), on the same inputs, many of them: the
//! answers must be the same bytes. A module of the Roc chat moves to
//! production only with its twin here green.

const std = @import("std");
const testing = std.testing;
const twin = @import("roc_chat_twin");
const timefmt = @import("timefmt.zig");
const decimal = @import("decimal.zig");
const chat_paths = @import("chat_paths.zig");
const chat_codec = @import("chat_codec.zig");
const chat_count = @import("chat_count.zig");
const chat_frame = @import("chat_frame.zig");
const markdown = @import("markdown.zig");
const reactions = @import("reactions.zig");
const http = @import("webbox").http;
const webbox_html = @import("webbox").html;
const chrome = @import("chat_chrome.zig");
const chat_page = @import("chat_page.zig");
const chat_upload = @import("chat_upload.zig");
const ChatMessage = @import("chat_store.zig").ChatMessage;

/// chat/twin.roc's numbers.
const Fn = enum(u8) {
    time_rfc3339 = 1,
    time_date = 2,
    time_unix_from_rfc3339 = 3,
    parse_u64 = 4,
    json_string = 5,
    trim = 6,
    participant = 7,
    pair_key = 8,
    valid_topic_id = 9,
    valid_channel_name = 10,
    valid_msg_ref_id = 11,
    path_join = 12,
    first_of = 13,
    transcript_path = 14,
    decode_file = 15,
    stored_form = 16,
    count_blocks = 17,
    number_in = 18,
    index_of = 19,
    parse_count = 20,
    count_text = 21,
    believed_count = 22,
    recorded_author = 23,
    window_last = 24,
    message_frame = 25,
    reaction_frame = 26,
    form_field = 27,
    react_form = 28,
    valid_emoji = 29,
    chrome_page = 30,
    not_found_page = 31,
    no_topics_page = 32,
    no_conversations_page = 33,
    sidebar_json = 34,
    conversation_page = 35,
    html_escape = 36,
    script_safe = 37,
};

/// One Roc call's results, in `a`.
fn roc(a: std.mem.Allocator, f: Fn, args: []const []const u8) ![][]u8 {
    return twin.call(a, @backingInt(f), args);
}

/// The Roc's one result, or null when it gave none.
fn roc1(a: std.mem.Allocator, f: Fn, args: []const []const u8) !?[]u8 {
    const got = try roc(a, f, args);
    return switch (got.len) {
        0 => null,
        1 => got[0],
        else => error.TwinGaveMore,
    };
}

/// A difference between the twins, said once and counted.
const Differences = struct {
    count: usize = 0,
    fn add(d: *Differences, comptime fmt: []const u8, args: anytype) void {
        d.count += 1;
        if (d.count <= 10) std.debug.print(fmt ++ "\n", args);
    }
    fn none(d: Differences, compared: usize) !void {
        if (d.count > 0) {
            std.debug.print("{d} of {d} differ\n", .{ d.count, compared });
            return error.TestUnexpectedResult;
        }
    }
};

fn setUp() std.heap.ArenaAllocator {
    twin.use(testing.allocator);
    return std.heap.ArenaAllocator.init(testing.allocator);
}

// ── Time (timefmt.zig) ─────────────────────────────────────────────────────

/// Seconds that try the calendar: the epoch and around it, leap days and
/// centuries (1900, 2000, 2100, 2400), the years Hinnant's eras turn, the
/// far past and future, and a pseudorandom spread between.
fn times(a: std.mem.Allocator) ![]i64 {
    var out: std.ArrayList(i64) = .empty;
    for ([_]i64{ 0, -1, 1, 86399, 86400, -86400, -86401, 951782400, 951868800, 4107542400, 4107456000, 13574563200, -2208988800, -62135596800, -62167219200, 253402300799, 253402300800, 1761400000, 1700000000 }) |t|
        for ([_]i64{ -1, 0, 1 }) |d| try out.append(a, t + d);
    var rng = std.Random.DefaultPrng.init(0x7177e);
    for (0..5000) |_| try out.append(a, rng.random().intRangeAtMost(i64, -62135596800, 253402300799));
    return out.toOwnedSlice(a);
}

test "Time: a message's date and a dated topic's name, for every time tried" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    const ts = try times(a);
    for (ts) |t| {
        const arg = try std.fmt.allocPrint(a, "{d}", .{t});
        const zr = try timefmt.formatRFC3339UTC(a, t);
        const rr = (try roc1(a, .time_rfc3339, &.{arg})).?;
        if (!std.mem.eql(u8, zr, rr)) differ.add("rfc3339({d}): zig {s}, roc {s}", .{ t, zr, rr });
        const zd = try timefmt.formatDateUTC(a, t);
        const rd = (try roc1(a, .time_date, &.{arg})).?;
        if (!std.mem.eql(u8, zd, rd)) differ.add("date({d}): zig {s}, roc {s}", .{ t, zd, rd });
    }
    try differ.none(ts.len * 2);
}

test "Time: a date read back, as written, with a fraction or an offset, and every byte of it damaged" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var texts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "", "Z", "2026-05-28T10:00:00", "2026-05-28t10:00:00z", "2026-05-28T10:00:00.Z", "2026-05-28T10:00:00+0530", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-01-32T00:00:00Z", "2026-01-31T24:00:00Z", "2026-01-31T23:60:00Z", "2026-01-31T23:59:60Z", "2026-01-31T23:59:61Z", "2026-01-31T23:59:59+24:00", "2026-01-31T23:59:59-00:60", "+026-01-31T23:59:59Z", "2026-02-31T00:00:00Z" }) |t| try texts.append(a, t);
    for ((try times(a))[0..400]) |t| {
        const base = try timefmt.formatRFC3339UTC(a, t);
        try texts.append(a, base);
        const stem = base[0 .. base.len - 1];
        for ([_][]const u8{ ".5Z", ".123456789Z", "+05:30", "-08:00", "+00:00", "-23:59", "z", ".Z", "+5:30", "" }) |tail|
            try texts.append(a, try std.mem.concat(a, u8, &.{ stem, tail }));
    }
    // Every byte of one date replaced by each byte that matters to it.
    const one = "2026-06-19T14:34:07.25+05:30";
    for (0..one.len) |i| for ([_]u8{ '0', '9', '-', ':', 'T', 'Z', '+', '.', 'x', 0, 0xff }) |b| {
        const d = try a.dupe(u8, one);
        d[i] = b;
        try texts.append(a, d);
    };
    var differ: Differences = .{};
    for (texts.items) |text| {
        const z = timefmt.unixFromRFC3339(text);
        const r = try roc1(a, .time_unix_from_rfc3339, &.{text});
        const rz: ?i64 = if (r) |s| try std.fmt.parseInt(i64, s, 10) else null;
        if (z != rz) differ.add("unixFromRFC3339(\"{s}\"): zig {?d}, roc {?d}", .{ text, z, rz });
    }
    try differ.none(texts.items.len);
}

// ── ZigText: decimal.zig, std.json.fmt, std.mem.trim ───────────────────────

/// Byte strings that try a reader: every single byte, each pair of the
/// ones that matter to JSON and to digits, UTF-8 good and broken, numbers
/// at u64's edges, and a seeded spread of short ones.
fn byteStrings(a: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "", "0", "00", "007", "18446744073709551615", "18446744073709551616", "99999999999999999999", "+5", "-0", "1_0", " 1", "1 ", "0x10", "1e3", "\u{0661}", "caf\xc3\xa9", "\xc3", "\xe2\x82", "\xf0\x9f\x98\x80", "\xed\xa0\x80", "\xc0\xaf", "\xff\xfe", "a\u{2028}b", "\x7f", " \t\r\n x \n\t", "\x0b\x0cx", "   ", "\n" }) |s| try out.append(a, s);
    var b: [1]u8 = undefined;
    for (0..256) |c| {
        b[0] = @intCast(c);
        try out.append(a, try a.dupe(u8, &b));
    }
    const special = [_]u8{ '"', '\\', '/', 0, 8, 9, 10, 12, 13, 0x1f, 0x7f, 'a', '7', 0xc3, 0xa9, 0xff };
    for (special) |x| for (special) |y| try out.append(a, try a.dupe(u8, &.{ x, y }));
    var rng = std.Random.DefaultPrng.init(0x7e47);
    for (0..2000) |_| {
        const n = rng.random().uintAtMost(usize, 12);
        const s = try a.alloc(u8, n);
        for (s) |*c| c.* = if (rng.random().boolean()) '0' + rng.random().uintAtMost(u8, 9) else rng.random().int(u8);
        try out.append(a, s);
    }
    return out.toOwnedSlice(a);
}

test "ZigText: a number has one spelling, decimal.parseInt's at u64" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    const ss = try byteStrings(a);
    for (ss) |s| {
        const z = decimal.parseInt(u64, s);
        const r = try roc1(a, .parse_u64, &.{s});
        const rz: ?u64 = if (r) |t| try std.fmt.parseInt(u64, t, 10) else null;
        if (z != rz) differ.add("parseInt(\"{f}\"): zig {?d}, roc {?d}", .{ std.zig.fmtString(s), z, rz });
    }
    try differ.none(ss.len);
}

test "ZigText: a string as std.json.fmt writes it, and as the readers trim it" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    const ss = try byteStrings(a);
    for (ss) |s| {
        const z = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(s, .{})});
        const r = (try roc1(a, .json_string, &.{s})).?;
        if (!std.mem.eql(u8, z, r)) differ.add("json(\"{f}\"): zig {s}, roc {s}", .{ std.zig.fmtString(s), z, r });
        const zt = std.mem.trim(u8, s, " \t\r\n");
        const rt = (try roc1(a, .trim, &.{s})).?;
        if (!std.mem.eql(u8, zt, rt)) differ.add("trim(\"{f}\"): zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(s), std.zig.fmtString(zt), std.zig.fmtString(rt) });
    }
    try differ.none(ss.len * 2);
}

// ── Paths (chat_paths.zig) ─────────────────────────────────────────────────

fn yes(b: []const u8) bool {
    return std.mem.eql(u8, b, "1");
}

test "Paths: who is in a DM, and its canonical key" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    const halves = [_][]const u8{ "", "0", "1", "2", "9", "10", "01", "007", "12", "21", "99999999999999999999", "9223372036854775807", "9223372036854775808", "a", "..", "1a", "-1", "+1", "1_2", "\xff" };
    for (halves) |x| for (halves) |y| {
        const pair = try std.fmt.allocPrint(a, "{s}_{s}", .{ x, y });
        const zk = try chat_paths.chatPairKey(a, x, y);
        const rk = (try roc1(a, .pair_key, &.{ x, y })).?;
        compared += 1;
        if (!std.mem.eql(u8, zk, rk)) differ.add("pairKey(\"{s}\", \"{s}\"): zig {s}, roc {s}", .{ x, y, zk, rk });
        for ([_][]const u8{ x, y, "1", "", "3" }) |user| {
            for ([_][]const u8{ pair, x, try std.fmt.allocPrint(a, "{s}__{s}", .{ x, y }) }) |key| {
                const z = try chat_paths.chatKeyParticipant(a, key, user);
                const r = yes((try roc1(a, .participant, &.{ key, user })).?);
                compared += 1;
                if (z != r) differ.add("participant(\"{s}\", \"{s}\"): zig {}, roc {}", .{ key, user, z, r });
            }
        }
    };
    try differ.none(compared);
}

test "Paths: topic ids, channel names and message ids, every byte at every place" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    for (try byteStrings(a)) |s| try ids.append(a, s);
    for ([_][]const u8{ "general", "ChitChat", "a-b", "a--b", "-a", "a-", "2026-10-25", "general_3", "a-b_10", "_3", "a_", "a_b_3", "ops", "9ops", "Ops-9", "a b", "general_03" }) |s| try ids.append(a, s);
    for ([_]usize{ 39, 40, 41, 79, 80, 81 }) |n| {
        const s = try a.alloc(u8, n);
        @memset(s, 'x');
        try ids.append(a, s);
    }
    for ([_][]const u8{ "ab-cd_12", "ops-x" }) |base| for (0..base.len) |i| for (0..256) |c| {
        const s = try a.dupe(u8, base);
        s[i] = @intCast(c);
        try ids.append(a, s);
    };
    var differ: Differences = .{};
    for (ids.items) |s| {
        const checks = .{
            .{ Fn.valid_topic_id, chat_paths.validTopicID(s) },
            .{ Fn.valid_channel_name, chat_paths.validChannelName(s) },
            .{ Fn.valid_msg_ref_id, chat_paths.validMsgRefID(s) },
        };
        inline for (checks) |c| {
            const r = yes((try roc1(a, c[0], &.{s})).?);
            if (r != c[1]) differ.add("{t}(\"{f}\"): zig {}, roc {}", .{ c[0], std.zig.fmtString(s), c[1], r });
        }
    }
    try differ.none(ids.items.len * 3);
}

test "Paths: paths joined as std.fs.path.join, a transcript's path, a conversation's first topic" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    const parts = [_][]const u8{ "", "/", "a", "/a", "a/", "/a/", "a//", "//a", "chat", "../x", "b c" };
    for (parts) |x| for (parts) |y| for (parts) |z| {
        const zj = try std.fs.path.join(a, &.{ x, y, z });
        const rj = (try roc1(a, .path_join, &.{ x, y, z })).?;
        compared += 1;
        if (!std.mem.eql(u8, zj, rj)) differ.add("join(\"{s}\", \"{s}\", \"{s}\"): zig \"{s}\", roc \"{s}\"", .{ x, y, z, zj, rj });
    };
    for (parts) |dir| for ([_][]const u8{ "general", "", "a/b" }) |sid| {
        const zp = try chat_paths.transcriptPath(a, dir, sid);
        const rp = (try roc1(a, .transcript_path, &.{ dir, sid })).?;
        compared += 1;
        if (!std.mem.eql(u8, zp, rp)) differ.add("transcriptPath(\"{s}\", \"{s}\"): zig {s}, roc {s}", .{ dir, sid, zp, rp });
    };
    for ([_][]const []const u8{ &.{}, &.{"a"}, &.{ "a", "ChitChat" }, &.{ "ChitChat", "b" }, &.{ "chitchat", "z" }, &.{ "2026-10-25", "general" } }) |topics| {
        const zf = chat_paths.firstOf(topics);
        const rf = (try roc1(a, .first_of, topics)).?;
        compared += 1;
        if (!std.mem.eql(u8, zf, rf)) differ.add("firstOf: zig {s}, roc {s}", .{ zf, rf });
    }
    try differ.none(compared);
}

// ── Codec (chat_codec.zig) ─────────────────────────────────────────────────

/// The pieces a transcript is made of, and the ones that break it: the
/// separator and its dashes with and without backslashes, headers with and
/// without ": ", torn ids, whitespace a skip must see through, bytes that
/// are not UTF-8.
const codec_bits = [_][]const u8{ "MSG_", "MSG_t_1", "\n", "\n", "\n\n", "from: ", "date: ", "uid: ", "from:", ": ", ":", "Steve", "2026-10-25T12:00:00Z", "7", "x", "\\", "\\\\", "-------------", "\\-------------", "\\\\-------------", "------------", "--------------", "\n\n-------------\n", " ", "\t", "\r", "\xff", "caf\xc3\xa9" };

/// A seeded spread of byte strings made of `codec_bits`, up to `most` bits.
fn codecStrings(a: std.mem.Allocator, seed: u64, n: usize, most: usize) ![][]const u8 {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const out = try a.alloc([]const u8, n);
    for (out) |*s| {
        var b: std.ArrayList(u8) = .empty;
        for (0..r.uintAtMost(usize, most)) |_| try b.appendSlice(a, codec_bits[r.uintLessThan(usize, codec_bits.len)]);
        s.* = b.items;
    }
    return out;
}

/// A message whose every field is drawn from `codec_bits`, the id, author
/// and date never empty (a message as the store writes one).
fn codecMessage(a: std.mem.Allocator, r: std.Random) !ChatMessage {
    const pick = struct {
        fn f(al: std.mem.Allocator, rr: std.Random, most: usize, nonempty: bool) ![]const u8 {
            var b: std.ArrayList(u8) = .empty;
            for (0..rr.uintAtMost(usize, most)) |_| try b.appendSlice(al, codec_bits[rr.uintLessThan(usize, codec_bits.len)]);
            if (nonempty and b.items.len == 0) try b.append(al, 'm');
            return b.items;
        }
    }.f;
    return .{ .id = try pick(a, r, 2, true), .from = try pick(a, r, 2, true), .at = try pick(a, r, 2, true), .uid = try pick(a, r, 1, false), .markdown = try pick(a, r, 12, false) };
}

/// The Roc's decode against chatDecodeFile's, field by field, the refused
/// count too.
fn decodeAgrees(a: std.mem.Allocator, data: []const u8, differ: *Differences) !void {
    const before = chat_codec.refused_blocks;
    const zm = try chat_codec.decodeChatFile(a, data);
    const zrefused = chat_codec.refused_blocks - before;
    const got = try roc(a, .decode_file, &.{data});
    const rrefused = try std.fmt.parseInt(usize, got[0], 10);
    const rest = got[1..];
    if (zrefused != rrefused or rest.len != zm.len * 5) {
        differ.add("decode(\"{f}\"): zig {d} messages {d} refused, roc {d} fields {d} refused", .{ std.zig.fmtString(data), zm.len, zrefused, rest.len, rrefused });
        return;
    }
    for (zm, 0..) |m, i| {
        const want = [_][]const u8{ m.id, m.from, m.at, m.uid, m.markdown };
        for (want, rest[i * 5 ..][0..5], 0..) |w, g, f| if (!std.mem.eql(u8, w, g)) {
            differ.add("decode(\"{f}\") message {d} field {d}: zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(data), i, f, std.zig.fmtString(w), std.zig.fmtString(g) });
            return;
        };
    }
}

test "Codec: a transcript decoded, whatever its bytes" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    const files = try codecStrings(a, 0xc0dec, 3000, 24);
    for (files) |f| try decodeAgrees(a, f, &differ);
    try differ.none(files.len);
}

test "Codec: a message's stored form, and what reads back from a file of them" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var rng = std.Random.DefaultPrng.init(0x5704ed);
    const r = rng.random();
    var compared: usize = 0;
    for (0..300) |_| {
        var file: std.ArrayList(u8) = .empty;
        for (0..r.uintAtMost(usize, 4)) |index| {
            const m = try codecMessage(a, r);
            const zs = try chat_codec.chatStoredForm(a, index, m);
            const idx = try std.fmt.allocPrint(a, "{d}", .{index});
            const rs = (try roc1(a, .stored_form, &.{ idx, m.id, m.from, m.at, m.uid, m.markdown })).?;
            compared += 1;
            if (!std.mem.eql(u8, zs, rs)) differ.add("storedForm({d}, \"{f}\"): zig \"{f}\", roc \"{f}\"", .{ index, std.zig.fmtString(m.markdown), std.zig.fmtString(zs), std.zig.fmtString(rs) });
            try file.appendSlice(a, zs);
        }
        try decodeAgrees(a, file.items, &differ);
        compared += 1;
    }
    try differ.none(compared);
}

// ── Count (chat_count.zig) ─────────────────────────────────────────────────

/// Zig's optional number as the twin's results: none, or its digits.
fn digitsOf(a: std.mem.Allocator, n: ?u64) ![]const []const u8 {
    const v = n orelse return &.{};
    return a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "{d}", .{v})});
}

fn sameResults(want: []const []const u8, got: []const []const u8) bool {
    if (want.len != got.len) return false;
    for (want, got) |w, g| if (!std.mem.eql(u8, w, g)) return false;
    return true;
}

/// Sidecars as they are written and as a crash or a hand leaves them:
/// numbers at u64's edges, signs, `_`, doubled and trailing spaces, a
/// missing newline, a third token, a torn second line.
fn sidecars(a: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "", "\n", "3 120\n", "3 120", "3 120\n40 7\n", "3 120\n40 -\n", "3 120\n40 7", "3  120\n", " 3 120 \n", "3 120 9\n", "3\n", "3 120\n40\n", "3 120\n40 7 8\n", "3 120\n\n", "+3 120\n", "3 1_20\n", "18446744073709551615 18446744073709551615\n18446744073709551615 x\n", "18446744073709551616 1\n", "0 0\n0 -\n", "3\t120\n" }) |t| try out.append(a, t);
    const bits = [_][]const u8{ "0", "1", "3", "40", "120", "007", "18446744073709551615", "18446744073709551616", " ", "  ", "\n", "-", "7", "x", "\t", "+1", "_" };
    var rng = std.Random.DefaultPrng.init(0xc0047);
    const r = rng.random();
    for (0..2000) |_| {
        var b: std.ArrayList(u8) = .empty;
        for (0..r.uintAtMost(usize, 9)) |_| try b.appendSlice(a, bits[r.uintLessThan(usize, bits.len)]);
        if (r.boolean()) try b.append(a, '\n');
        try out.append(a, b.items);
    }
    return out.toOwnedSlice(a);
}

const sizes = [_]u64{ 0, 1, 3, 40, 120, std.math.maxInt(u64) };

test "Count: blocks counted, and a message's number and index in its topic" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    for (try codecStrings(a, 0xb10c5, 2000, 24)) |raw| {
        const z = chat_count.countBlocks(raw);
        const r = try std.fmt.parseInt(usize, (try roc1(a, .count_blocks, &.{raw})).?, 10);
        compared += 1;
        if (z != r) differ.add("countBlocks(\"{f}\"): zig {d}, roc {d}", .{ std.zig.fmtString(raw), z, r });
    }
    const sids = [_][]const u8{ "general", "", "a", "a_1", "t_", "2026-10-25" };
    const tails = [_][]const u8{ "", "_", "_0", "_1", "_01", "_7", "_18446744073709551615", "_18446744073709551616", "_1_0", "_+1", "1", "_ 1", "_1 ", "__1", "_x" };
    for (sids) |sid| for (sids) |other| for (tails) |tail| {
        const id = try std.mem.concat(a, u8, &.{ other, tail });
        for ([_]Fn{ .number_in, .index_of }) |f| {
            const z = if (f == .number_in) chat_count.numberIn(id, sid) else chat_count.indexOf(id, sid);
            const r = try roc(a, f, &.{ id, sid });
            compared += 1;
            if (!sameResults(try digitsOf(a, z), r)) differ.add("{t}(\"{s}\", \"{s}\"): zig {?d}, roc {d} results", .{ f, id, sid, z, r.len });
        }
    };
    try differ.none(compared);
}

test "Count: a sidecar read, written, and believed or not" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    for (try sidecars(a)) |raw| {
        const z = chat_count.parseCount(raw);
        var want: std.ArrayList([]const u8) = .empty;
        if (z) |c| {
            try want.appendSlice(a, &.{ try std.fmt.allocPrint(a, "{d}", .{c.count}), try std.fmt.allocPrint(a, "{d}", .{c.size}) });
            if (c.last) |l| try want.appendSlice(a, &.{ try std.fmt.allocPrint(a, "{d}", .{l.offset}), l.uid });
        }
        const r = try roc(a, .parse_count, &.{raw});
        compared += 1;
        if (!sameResults(want.items, r)) differ.add("parseCount(\"{f}\"): zig {d} fields, roc {d}", .{ std.zig.fmtString(raw), want.items.len, r.len });
        for (sizes) |size| {
            const sz = try std.fmt.allocPrint(a, "{d}", .{size});
            const zb = chat_count.believedCount(z, size);
            compared += 1;
            if (!sameResults(try digitsOf(a, zb), try roc(a, .believed_count, &.{ raw, sz }))) differ.add("believedCount(\"{f}\", {d})", .{ std.zig.fmtString(raw), size });
            for ([_]usize{ 0, 1, 3, 40 }) |blocks| {
                const bl = try std.fmt.allocPrint(a, "{d}", .{blocks});
                const zr = chat_count.recordedAuthor(z, blocks, size);
                const zw: []const []const u8 = if (zr) |u| try a.dupe([]const u8, &.{u}) else &.{};
                compared += 1;
                if (!sameResults(zw, try roc(a, .recorded_author, &.{ raw, bl, sz }))) differ.add("recordedAuthor(\"{f}\", {d}, {d})", .{ std.zig.fmtString(raw), blocks, size });
            }
        }
    }
    for ([_]usize{ 0, 3, std.math.maxInt(usize) }) |count| for (sizes) |size| for ([_]?chat_count.Last{ null, .{ .offset = 0, .uid = "" }, .{ .offset = 40, .uid = "7" }, .{ .offset = std.math.maxInt(u64), .uid = "-" } }) |last| {
        const zt = try chat_count.countText(a, count, size, last);
        const c = try std.fmt.allocPrint(a, "{d}", .{count});
        const sz = try std.fmt.allocPrint(a, "{d}", .{size});
        const rt = (try roc1(a, .count_text, if (last) |l| &.{ c, sz, try std.fmt.allocPrint(a, "{d}", .{l.offset}), l.uid } else &.{ c, sz })).?;
        compared += 1;
        if (!std.mem.eql(u8, zt, rt)) differ.add("countText: zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(zt), std.zig.fmtString(rt) });
    };
    try differ.none(compared);
}

test "Count: the window at the record's offset, believed or read the slow way" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    var windows: std.ArrayList([]const u8) = .empty;
    try windows.appendSlice(a, try codecStrings(a, 0x3140, 500, 24));
    // Files of this topic's messages, numbered in and out of order, some
    // with another topic's id, some ending in a torn block.
    var rng = std.Random.DefaultPrng.init(0x3141);
    const r = rng.random();
    for (0..500) |_| {
        var file: std.ArrayList(u8) = .empty;
        for (0..r.uintAtMost(usize, 3)) |index| {
            var m = try codecMessage(a, r);
            m.id = try std.fmt.allocPrint(a, "{s}_{d}", .{ if (r.uintLessThan(u8, 5) == 0) "u" else "t", r.uintAtMost(u8, 6) });
            try file.appendSlice(a, try chat_codec.chatStoredForm(a, index, m));
        }
        if (r.uintLessThan(u8, 4) == 0) try file.appendSlice(a, "\n\n-------------\nMSG_t_9\nfrom: x");
        try windows.append(a, file.items);
    }
    for (windows.items) |w| for ([_]usize{ 0, 1, 3, 6 }) |count| for ([_]bool{ false, true }) |full| {
        const z = try chat_count.windowLast(a, count, w, full, "t");
        const want: []const []const u8 = if (z) |got| &.{ try std.fmt.allocPrint(a, "{d}", .{got.number}), if (got.current) "1" else "0", got.msg.id, got.msg.from, got.msg.at, got.msg.uid, got.msg.markdown } else &.{};
        const c = try std.fmt.allocPrint(a, "{d}", .{count});
        const got = try roc(a, .window_last, &.{ c, w, if (full) "1" else "0", "t" });
        compared += 1;
        if (!sameResults(want, got)) differ.add("windowLast({d}, \"{f}\", {}): zig {d} fields, roc {d}", .{ count, std.zig.fmtString(w), full, want.len, got.len });
    };
    try differ.none(compared);
}

// ── Frame (chat_frame.zig) ─────────────────────────────────────────────────

test "Frame: a message's frame and a reaction's, whatever their bytes" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    const strings = try byteStrings(a);
    var rng = std.Random.DefaultPrng.init(0xf4a3e);
    const r = rng.random();
    const pick = struct {
        fn f(rr: std.Random, ss: []const []const u8) []const u8 {
            return if (rr.uintLessThan(u8, 4) == 0) "" else ss[rr.uintLessThan(usize, ss.len)];
        }
    }.f;
    for (0..2000) |i| {
        const m: chat_frame.Message = .{
            .index = switch (i % 3) {
                0 => i,
                1 => 0,
                else => std.math.maxInt(usize),
            },
            .from = pick(r, strings),
            .from_uid = pick(r, strings),
            .at = pick(r, strings),
            .id = pick(r, strings),
            .markdown = if (i % 2 == 0) pick(r, strings) else (try codecMessage(a, r)).markdown,
            .cid = pick(r, strings),
        };
        const zf = try chat_frame.messageFrame(a, m);
        const idx = try std.fmt.allocPrint(a, "{d}", .{m.index});
        const html = try markdown.render(a, m.markdown);
        const rf = (try roc1(a, .message_frame, &.{ idx, m.from, m.from_uid, m.at, html, m.markdown, m.id, m.cid })).?;
        compared += 1;
        if (!std.mem.eql(u8, zf, rf)) differ.add("messageFrame: zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(zf), std.zig.fmtString(rf) });
    }
    for (strings) |line| {
        const zr = try chat_frame.reactionFrame(a, line);
        const rr = (try roc1(a, .reaction_frame, &.{line})).?;
        compared += 1;
        if (!std.mem.eql(u8, zr, rr)) differ.add("reactionFrame(\"{f}\")", .{std.zig.fmtString(line)});
    }
    try differ.none(compared);
}

// ── Form, Reaction (webbox http.formField; reactions.zig) ──────────────────

/// Forms built of the pieces that try a decoder and a reader: separators,
/// `+`, escapes good and bad (a `%` at the end, one hex digit, upper and
/// lower case), repeated and empty names, the react form's own fields, and
/// emoji at their edges (one glyph, a variation selector, ZWJ, too long,
/// torn, ASCII mixed in).
fn forms(a: std.mem.Allocator) ![][]const u8 {
    const bits = [_][]const u8{ "&", "=", "msg", "emoji", "on", "1", "0", "007", "x", "+", "%", "%2", "%2B", "%2b", "%41", "%zz", "%4G", "%G1", "%af", "%AF", "%4g", "%F0%9F%91%8D", "%EF%B8%8F", "%E2%80%8D", "%E2%9D%A4", "%F0%9F", "%C3%A9", "%FF", "%00", "%20", "a%2", "18446744073709551616", "msg=", "emoji=", "on=" };
    var rng = std.Random.DefaultPrng.init(0xf0a3);
    const r = rng.random();
    const out = try a.alloc([]const u8, 4000);
    for (out) |*f| {
        var b: std.ArrayList(u8) = .empty;
        for (0..r.uintAtMost(usize, 10)) |_| try b.appendSlice(a, bits[r.uintLessThan(usize, bits.len)]);
        f.* = b.items;
    }
    return out;
}

test "Form: a field as webbox's formField reads it, for every form tried" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    for (try forms(a)) |body| for ([_][]const u8{ "msg", "emoji", "on", "x", "" }) |name| {
        const want: []const []const u8 = if (http.formField(a, body, name)) |found|
            (if (found) |v| &.{ "F", v } else &.{})
        else |e| switch (e) {
            error.MalformedForm => &.{"M"},
            else => return e,
        };
        const got = try roc(a, .form_field, &.{ body, name });
        compared += 1;
        if (!sameResults(want, got)) differ.add("formField(\"{s}\", \"{s}\"): zig {d} results, roc {d}", .{ body, name, want.len, got.len });
    };
    try differ.none(compared);
}

test "Reaction: the react form judged as parseReactForm judges it, and one glyph as validEmoji knows one" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    for (try forms(a)) |body| {
        const want: []const []const u8 = if (reactions.parseReactForm(a, body)) |f| switch (f) {
            .reacted => |r| &.{ "R", try std.fmt.allocPrint(a, "{d}", .{r.msg}), r.emoji, if (r.on) "1" else "0" },
            .bad => |why| &.{ "B", why },
        } else |e| switch (e) {
            error.MalformedForm => &.{"M"},
            else => return e,
        };
        const got = try roc(a, .react_form, &.{body});
        compared += 1;
        if (!sameResults(want, got)) differ.add("parseReactForm(\"{s}\"): zig {d} results, roc {d}", .{ body, want.len, got.len });
    }
    // Glyphs at the length edge, every byte string, and each with one byte
    // changed to an ASCII one or a torn lead.
    var glyphs: std.ArrayList([]const u8) = .empty;
    try glyphs.appendSlice(a, try byteStrings(a));
    for ([_][]const u8{ "\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F468}\u{200D}\u{1F469}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1FA}\u{1F1F8}\u{1F1FA}\u{1F1F8}", "\u{1F1FA}\u{1F1F8}\u{1F1FA}\u{1F1F8}\u{1F44D}", "\u{1F44D}\u{1F44D}\u{1F44D}\u{2764}\u{00E9}", "\u{2000}", "\u{FFFF}", "\u{10FFFF}", "\xf4\x90\x80\x80", "\xe0\x80\x80" }) |g| {
        try glyphs.append(a, g);
        for (0..g.len) |i| for ([_]u8{ 'a', 0xc3, 0x80 }) |b| {
            const d = try a.dupe(u8, g);
            d[i] = b;
            try glyphs.append(a, d);
        };
    }
    for (glyphs.items) |g| {
        const want = reactions.validEmoji(g);
        const got = yes((try roc1(a, .valid_emoji, &.{g})).?);
        compared += 1;
        if (want != got) differ.add("validEmoji(\"{f}\"): zig {}, roc {}", .{ std.zig.fmtString(g), want, got });
    }
    try differ.none(compared);
}

// ── Chrome, Pages, Html (chat_chrome.zig, chat_page.zig, webbox html.zig) ──

/// Every script's src as the chrome names it, as `name, src` pairs: what
/// the host hands the Roc.
fn srcPairs(a: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    inline for (chrome.assets) |asset| try out.appendSlice(a, &.{ asset.name, try chrome.src(a, asset.name) });
    return out.items;
}

/// Text a page shows, hostile to HTML and to an inline script: every
/// escaped byte, `</script>`, quotes, and the byte strings' corpus.
fn pageTexts(a: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "", "Chat", "Steve", "a&b", "<b>x</b>", "\"q\" 'a'", "</script><script>alert(1)</script>", "</", "<\\/", "Ada Lovelace", "general", "#ops: plans", "caf\xc3\xa9", "\xff" }) |t| try out.append(a, t);
    for ((try byteStrings(a))[0..200]) |t| try out.append(a, t);
    return out.items;
}

test "Chrome: a chat page's shell, byte for byte, for every title, viewer and bold link tried" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    const pairs = try srcPairs(a);
    const texts = try pageTexts(a);
    for (texts, 0..) |t, i| for ([_][]const u8{ "", "chat", "docs", "recent", "images", "code", "links", "settings", "Chat" }) |active| {
        const tab = texts[(i * 7) % texts.len];
        const body = texts[(i * 13) % texts.len];
        var page = try chrome.page(a, tab, t, texts[(i * 3) % texts.len], active);
        try page.body.appendSlice(a, body);
        const z = try page.bytes();
        const r = (try roc1(a, .chrome_page, try std.mem.concat(a, []const u8, &.{ &.{ tab, t, texts[(i * 3) % texts.len], active, body }, pairs }))).?;
        compared += 1;
        if (!std.mem.eql(u8, z, r)) differ.add("chrome page \"{f}\" active \"{s}\": zig {d} bytes, roc {d}", .{ std.zig.fmtString(t), active, z.len, r.len });
    };
    try differ.none(compared);
}

test "Pages: the 404 that says why, the first-topic shell, the empty /chat and the conversation page, byte for byte" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    const pairs = try srcPairs(a);
    const texts = try pageTexts(a);
    const accept = chat_upload.accept;
    const digits = struct {
        fn f(al: std.mem.Allocator, n: anytype) ![]const u8 {
            return std.fmt.allocPrint(al, "{d}", .{n});
        }
    }.f;
    for (texts, 0..) |t, i| {
        const u = texts[(i * 5 + 1) % texts.len];
        const w = texts[(i * 11 + 2) % texts.len];
        const checks = [_]struct { f: Fn, zig: []const u8, args: []const []const u8 }{
            .{ .f = .not_found_page, .zig = try chat_page.notFoundHtml(a, t, u, w), .args = &.{ t, u, w } },
            .{ .f = .no_topics_page, .zig = try chat_page.noTopicsHtml(a, t, u, w), .args = &.{ t, u, w } },
            .{ .f = .no_conversations_page, .zig = try chat_page.noConversationsHtml(a, t), .args = &.{t} },
        };
        for (checks) |c| {
            const r = (try roc1(a, c.f, try std.mem.concat(a, []const u8, &.{ c.args, pairs }))).?;
            compared += 1;
            if (!std.mem.eql(u8, c.zig, r)) differ.add("{t}(\"{f}\"): zig {d} bytes, roc {d}", .{ c.f, std.zig.fmtString(t), c.zig.len, r.len });
        }
        const v: chat_page.View = .{ .key = t, .base = u, .sid = w, .title = texts[(i * 3) % texts.len], .uid = texts[(i * 17) % texts.len], .viewer = texts[(i * 19) % texts.len], .sidebar_json = texts[(i * 23) % texts.len] };
        const z = try chat_page.conversationHtml(a, v);
        const r = (try roc1(a, .conversation_page, try std.mem.concat(a, []const u8, &.{ &.{ v.key, v.base, v.sid, v.title, v.uid, v.viewer, v.sidebar_json, try digits(a, chat_upload.image_max), try digits(a, chat_upload.video_max), accept, try digits(a, @import("search_tokens.zig").min_len) }, pairs }))).?;
        compared += 1;
        if (!std.mem.eql(u8, z, r)) differ.add("conversation page \"{f}\": zig {d} bytes, roc {d}", .{ std.zig.fmtString(t), z.len, r.len });
    }
    try differ.none(compared);
}

test "Pages: the sidebar's JSON for every viewer, conversation, pin and topic list tried, script-safe" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var rng = std.Random.DefaultPrng.init(0x51deba7);
    const r = rng.random();
    const names = [_][]const u8{ "Steve", "Ada \"the\" </script>", "caf\xc3\xa9", "", "\x01", "Bo" };
    const ids = [_][]const u8{ "1", "2", "3", "10", "12" };
    // A topic named as a channel is, and a channel named as a DM's pair:
    // what is active is the conversation of its kind.
    const sids = [_][]const u8{ "general", "Plans", "plans", "a</b", "x\"y", "2026-10-25", "ops" };
    const chans = [_][]const u8{ "ops", "team", "a</", "b\"c", "1_2", "2_3" };
    var compared: usize = 0;
    for (0..800) |_| {
        const uid = ids[r.uintLessThan(usize, ids.len)];
        var others: std.ArrayList(chat_page.Other) = .empty;
        for (ids) |id| if (!std.mem.eql(u8, id, uid) and r.boolean()) try others.append(a, .{ .id = id, .name = names[r.uintLessThan(usize, names.len)], .online = r.boolean() });
        var channels: std.ArrayList([]const u8) = .empty;
        for (chans) |c| if (r.boolean()) try channels.append(a, c);
        var topics: std.ArrayList([]const u8) = .empty;
        for (sids) |t| if (r.boolean()) try topics.append(a, t);
        // Pins in no order, some twice, some no longer topics.
        var pins: std.ArrayList([]const u8) = .empty;
        for (0..r.uintAtMost(usize, 5)) |_| try pins.append(a, sids[r.uintLessThan(usize, sids.len)]);
        const dm = r.boolean();
        const other = ids[r.uintLessThan(usize, ids.len)];
        const key = if (dm) try chat_paths.chatPairKey(a, uid, other) else chans[r.uintLessThan(usize, chans.len)];
        const base = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (dm) "/chat/c" else "/channel", key });
        const sid = sids[r.uintLessThan(usize, sids.len)];
        const sb: chat_page.Sidebar = .{ .uid = uid, .dm = dm, .key = key, .base = base, .sid = sid, .others = others.items, .channels = channels.items, .pins = pins.items, .topics = topics.items };
        const z = try chat_page.sidebarJSON(a, sb);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ uid, if (dm) "1" else "0", key, base, sid, try std.fmt.allocPrint(a, "{d}", .{others.items.len}) });
        for (others.items) |o| try args.appendSlice(a, &.{ o.id, o.name, if (o.online) "1" else "0" });
        for ([_][]const []const u8{ channels.items, pins.items, topics.items }) |list| {
            try args.append(a, try std.fmt.allocPrint(a, "{d}", .{list.len}));
            try args.appendSlice(a, list);
        }
        const got = (try roc1(a, .sidebar_json, args.items)).?;
        compared += 1;
        if (!std.mem.eql(u8, z, got)) differ.add("sidebar: zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(z), std.zig.fmtString(got) });
    }
    try differ.none(compared);
}

test "Html: text escaped and a blob made script-safe, as webbox's html.zig does" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    for (try pageTexts(a)) |t| {
        const ze = try webbox_html.htmlEscape(a, t);
        const zs = try webbox_html.scriptSafe(a, t);
        compared += 2;
        if (!std.mem.eql(u8, ze, (try roc1(a, .html_escape, &.{t})).?)) differ.add("htmlEscape(\"{f}\")", .{std.zig.fmtString(t)});
        if (!std.mem.eql(u8, zs, (try roc1(a, .script_safe, &.{t})).?)) differ.add("scriptSafe(\"{f}\")", .{std.zig.fmtString(t)});
    }
    try differ.none(compared);
}
