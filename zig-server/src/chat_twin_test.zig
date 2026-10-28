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
const http = @import("webbox").http;
const webbox_html = @import("webbox").html;
const webbox_http = @import("webbox").http;
const chrome = @import("chat_chrome.zig");
const chat_upload = @import("chat_upload.zig");
const ChatMessage = @import("chat_store.zig").ChatMessage;
const images_store = @import("images_store.zig");
const code_store = @import("code_store.zig");
const chat_fanout = @import("chat_fanout.zig");
const recent_feed = @import("recent_feed.zig");
const chat_state = @import("chat_state.zig");
const chat = @import("chat.zig");
const ConvMeta = @import("chat_store.zig").ConvMeta;
const chat_store = @import("chat_store.zig");
const disk = @import("webbox").store;
const users = @import("users.zig");

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
    is_valid_msg_ref_id = 11,
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
    is_valid_emoji = 29,
    chrome_page = 30,
    not_found_page = 31,
    no_topics_page = 32,
    no_conversations_page = 33,
    sidebar_json = 34,
    conversation_page = 35,
    html_escape = 36,
    script_safe = 37,
    images_feed = 38,
    code_feed = 39,
    recent_excerpt = 40,
    recent_json = 41,
    resume_topic = 42,
    pinned = 43,
    dm_other = 44,
    dm_members = 45,
    dm_title = 46,
    channel_title = 47,
    topic_title = 48,
    has_topic = 49,
    conv_bases = 50,
    member_channels = 51,
    bookmark = 52,
    bookmark_changed = 53,
    state_paths = 54,
    topics = 55,
    channel_members = 56,
    channel_names = 57,
    rosters = 58,
    conv_paths = 59,
    accounts = 60,
    reaction_line = 61,
    fanout_keys = 62,
    fanout_urls = 63,
    notify_event = 64,
    topic_added = 65,
    recent_event = 66,
    images_entry = 67,
    code_entry = 68,
    recent_where = 69,
    json_out = 70,
    chat_url_on_site = 71,
    route_kind = 72,
    limits = 73,
    saved_refs = 74,
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

/// **THE ROC'S ANSWERS, FROZEN** (metal-vmm QUEUE 263c): where the Zig a
/// twin held a Roc function to is retired (no production route reached it),
/// the Roc's own answers over the same generated inputs are pinned as one
/// SHA-256 of them all, each answer's parts length-prefixed, taken the day
/// the twin passed (so the hash is the old Zig's answers too). A change of
/// one byte of one answer fails it. To see which, run the twin at the
/// commit before 263c, which held the same inputs to the Zig.
const Frozen = struct {
    h: std.crypto.hash.sha2.Sha256 = .init(.{}),
    n: usize = 0,
    fn add(f: *Frozen, parts: []const []const u8) void {
        f.n += 1;
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, parts.len, .little);
        f.h.update(&len);
        for (parts) |p| {
            std.mem.writeInt(u64, &len, p.len, .little);
            f.h.update(&len);
            f.h.update(p);
        }
    }
    fn check(f: *Frozen, comptime what: []const u8, want: []const u8, answers: usize) !void {
        var d: [32]u8 = undefined;
        f.h.final(&d);
        const got = std.fmt.bytesToHex(d, .lower);
        if (f.n == answers and std.mem.eql(u8, &got, want)) return;
        std.debug.print(what ++ ": {d} answers hash to {s}; frozen: {d} answers, {s}\n", .{ f.n, &got, answers, want });
        return error.TestUnexpectedResult;
    }
};

fn setUp() std.heap.ArenaAllocator {
    twin.use(testing.allocator);
    return std.heap.ArenaAllocator.init(testing.allocator);
}

// ── Time (timefmt.zig) ─────────────────────────────────────────────────────

/// Seconds that try the calendar: the epoch and around it, leap days and
/// centuries (1900, 2000, 2100, 2400), the ends of years (a leap year's and
/// not), the years Hinnant's eras turn, the far past and future, and a
/// pseudorandom spread between.
fn times(a: std.mem.Allocator) ![]i64 {
    var out: std.ArrayList(i64) = .empty;
    for ([_]i64{ 0, -1, 1, 86399, 86400, -86400, -86401, 951782400, 951868800, 4107542400, 4107456000, 13574563200, -2208988800, -62135596800, -62167219200, 253402300799, 253402300800, 1761400000, 1700000000, 1735689600, 1767225600, 978307200, 946684800, 4102444800 }) |t|
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
/// The strings that are UTF-8: what a Roc that takes text is handed (its
/// door refuses the rest; `roc test` covers the refusal).
fn utf8Only(a: std.mem.Allocator, ss: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (ss) |s| if (std.unicode.utf8ValidateSlice(s)) try out.append(a, s);
    return out.items;
}

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
    var compared: usize = 0;
    for (ss) |s| {
        // json_string takes text: the strings that are not UTF-8 go, since
        // the Roc's door refuses them and `roc test` covers that refusal
        // (JsonText's str_at_door expects).
        if (std.unicode.utf8ValidateSlice(s)) {
            const z = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(s, .{})});
            const r = (try roc1(a, .json_string, &.{s})).?;
            if (!std.mem.eql(u8, z, r)) differ.add("json(\"{f}\"): zig {s}, roc {s}", .{ std.zig.fmtString(s), z, r });
            compared += 1;
        }
        const zt = std.mem.trim(u8, s, " \t\r\n");
        const rt = (try roc1(a, .trim, &.{s})).?;
        if (!std.mem.eql(u8, zt, rt)) differ.add("trim(\"{f}\"): zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(s), std.zig.fmtString(zt), std.zig.fmtString(rt) });
        compared += 1;
    }
    try differ.none(compared);
    try testing.expect(compared > ss.len + 300);
}

test "JsonOut: an object of a count, a string, an array of strings and a bool, as std.json writes the same struct, over the escaping corpus (metal-vmm QUEUE 269)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    // JsonOut takes text: the strings that are not UTF-8 go (the door's).
    const texts = try utf8Only(a, try byteStrings(a));
    for (0..texts.len) |i| {
        // One to four strings, from every part of the corpus.
        const args = texts[i..@min(texts.len, i + 1 + i % 4)];
        const z = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .n = args.len, .first = args[0], .all = args, .even = args.len % 2 == 0 }, .{})});
        const r = (try roc1(a, .json_out, args)).?;
        compared += 1;
        if (!std.mem.eql(u8, z, r)) differ.add("json_out({d} args, first \"{f}\"):\n  zig {s}\n  roc {s}", .{ args.len, std.zig.fmtString(args[0]), z, r });
    }
    try differ.none(compared);
    try testing.expect(compared > 300);
}

test "ChatUrl: a path is on this site exactly when webbox's Target.of keeps it, over hostile paths and the corpus with a slash before it (metal-vmm QUEUE 270)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    var kept: usize = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.appendSlice(a, &.{ "/", "", "//evil.example", "/\\evil.example", "/\t/evil.example", "/a\r\nSet-Cookie: x", "https://evil.example", "javascript:alert(1)", "/chat/c/1_2", "/channel/ops/Plans#msg-Plans_3", "/a\x7f", "/caf\xc3\xa9", "\\/evil" });
    // Text only: a path that is not UTF-8 is refused at the Roc's door.
    for (try utf8Only(a, try byteStrings(a))) |s| try paths.appendSlice(a, &.{ s, try std.mem.concat(a, u8, &.{ "/", s }) });
    for (paths.items) |p| {
        const z = std.mem.eql(u8, webbox_http.Target.of(p).path(), p);
        const got = try roc(a, .chat_url_on_site, &.{p});
        const r = got.len == 1 and std.mem.eql(u8, got[0], p);
        compared += 1;
        if (z) kept += 1;
        if (z != r) differ.add("on_site(\"{f}\"): zig {}, roc {}", .{ std.zig.fmtString(p), z, r });
    }
    try differ.none(compared);
    try testing.expect(kept > 100 and compared - kept > 100);
}

test "the pre-turn hooks agree with the Roc router: an upload's path gets the upload's cap and family, a stream's the streams', a doc's the docs'" {
    // router.zig's familyOf and routeBodyLimit classify a path before the
    // turn, in Zig (they must: no Roc runs outside a call, docs/ROC-CHAT.md
    // R1), beside the Roc router's parse. Every path the router parses as
    // an upload, a stream or a doc must be one they classify so, whoever
    // then answers it (the Roc decides whose a conversation is, metal-vmm
    // QUEUE 271, so the parse is asked directly).
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    const router = @import("route_family.zig");
    const caps = @import("limits.zig").body;
    var checked: usize = 0;
    var kinds: usize = 0;
    for (try @import("chat_route_paths_test.zig").corpus(a)) |sub| for ([_][]const u8{ "/chat", "/channel" }) |area| {
        const path = try std.mem.concat(a, u8, &.{ area, sub });
        if ((webbox_http.pathUnder(path, "/chat") orelse webbox_http.pathUnder(path, "/channel")) == null) continue;
        if (!std.unicode.utf8ValidateSlice(sub)) continue;
        const kind = (try roc1(a, .route_kind, &.{ sub, if (std.mem.eql(u8, area, "/channel")) "c" else "" })).?;
        const is = struct {
            fn f(k: []const u8, want: []const u8) bool {
                return std.mem.eql(u8, k, want);
            }
        }.f;
        const wrong: ?[]const u8 = if (is(kind, "upload") and router.routeBodyLimit(path) != caps.upload_any)
            "an upload without the upload's cap"
        else if ((is(kind, "upload") or is(kind, "uploads")) and router.familyOf(path) != .uploads)
            "an upload not counted as one"
        else if (is(kind, "stream") and router.familyOf(path) != .streams)
            "a stream not counted as one"
        else if (is(kind, "docs") and router.familyOf(path) != .docs)
            "a doc not counted as one"
        else if (is(kind, "docs") and router.routeBodyLimit(path) != caps.doc)
            "a doc without the doc's cap"
        else
            null;
        if (wrong) |why| {
            std.debug.print("{s}: {s} (parsed {s}; family {t}, cap {d})\n", .{ path, why, kind, router.familyOf(path), router.routeBodyLimit(path) });
            return error.TestUnexpectedResult;
        }
        if (!is(kind, "other")) kinds += 1;
        checked += 1;
    };
    try testing.expect(checked > 5000 and kinds > 250);
}

test "Limits: the Roc's constants the conversation page tells its client are the ones the Zig enforces (metal-vmm QUEUE 272)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    const got = try roc(a, .limits, &.{});
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{chat_upload.image_max}), got[0]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{chat_upload.video_max}), got[1]);
    try testing.expectEqualStrings(chat_upload.accept, got[2]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{@import("search_tokens.zig").min_len}), got[3]);
}

test "Saved: a reading list's refs as reading_list.parseRefs reads them, both prefixes, every near miss, over text and bytes that are not (metal-vmm QUEUE 273)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    const reading_list = @import("reading_list.zig");
    var differ: Differences = .{};
    var compared: usize = 0;
    var found: usize = 0;
    var rng = std.Random.DefaultPrng.init(0x5a7ed);
    const r = rng.random();
    const parts = [_][]const u8{ "/chat/c/", "/channel/", "/chat/c", "/chan", "1_2", "ops", "a.b", "-", "_", "/", "#msg-", "#msg", "#", "Plans", "Plans_3", "Plans_", "_3", "x_y_9", "bad", ")", " ", "\n", "](", "[o]", "\xff", "\xc3\xa9", "/chat/c//", "1_2/Plans#msg-Plans_1", "/chat/c/1_2/Plans#msg-Plans_1", "/channel/ops/Standup#msg-Standup_12", "/chat/c/3_7/a.b#msg-a-b_2" };
    var texts: std.ArrayList([]const u8) = .empty;
    for (0..3000) |_| {
        var t: std.ArrayList(u8) = .empty;
        for (0..r.uintAtMost(usize, 14)) |_| try t.appendSlice(a, parts[r.uintLessThan(usize, parts.len)]);
        try texts.append(a, t.items);
    }
    try texts.appendSlice(a, try byteStrings(a));
    for (texts.items) |text| {
        const z = try reading_list.parseRefs(a, text);
        const got = try roc(a, .saved_refs, &.{text});
        compared += 1;
        found += z.len;
        var same = got.len == 3 * z.len;
        if (same) for (z, 0..) |ref, k| {
            if (!std.mem.eql(u8, ref.conv, got[3 * k]) or !std.mem.eql(u8, ref.sid, got[3 * k + 1]) or !std.mem.eql(u8, ref.id, got[3 * k + 2])) same = false;
        };
        if (!same) differ.add("parseRefs(\"{f}\"): zig {d} refs, roc {d} parts", .{ std.zig.fmtString(text), z.len, got.len });
    }
    try differ.none(compared);
    try testing.expect(found > 500);
}

// ── Paths (chat_paths.zig) ─────────────────────────────────────────────────

fn yes(b: []const u8) bool {
    return std.mem.eql(u8, b, "1");
}

/// A uid as allocateUser writes one: digits, the first not zero.
fn twinUid(s: []const u8) bool {
    if (s.len == 0 or s[0] == '0') return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
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
        // A key is the Roc's only from two uids (digits, the first not
        // zero): its PairKey is text, and no account has another id. The
        // Zig's atoiOr0 keyed any other half; the Roc keys none.
        const zk = try chat_paths.chatPairKey(a, x, y);
        const rk = try roc1(a, .pair_key, &.{ x, y });
        compared += 1;
        if (twinUid(x) and twinUid(y)) {
            if (rk == null or !std.mem.eql(u8, zk, rk.?)) differ.add("pairKey(\"{s}\", \"{s}\"): zig {s}, roc {?s}", .{ x, y, zk, rk });
        } else if (rk != null) differ.add("pairKey(\"{s}\", \"{s}\"): a half is no uid, roc {s}", .{ x, y, rk.? });
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
            .{ Fn.is_valid_msg_ref_id, chat_paths.validMsgRefID(s) },
        };
        inline for (checks) |c| {
            const r = yes((try roc1(a, c[0], &.{s})).?);
            if (r != c[1]) differ.add("{t}(\"{f}\"): zig {}, roc {}", .{ c[0], std.zig.fmtString(s), c[1], r });
        }
    }
    try differ.none(ids.items.len * 3);
}

test "Paths: a transcript's path, a conversation's first topic" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    // The Roc joins no hostile parts (std.fs.path.join's twin is gone): a
    // path's parts are a key, a uid, a topic id and literals, none empty or
    // with a `/`; the door refuses undecodable text; roc test covers it.
    // A DM's key and a topic id: the door refuses undecodable text; roc test
    // covers it.
    for ([_][]const u8{ "1_2", "1_1", "10_100" }) |dir| for ([_][]const u8{ "general", "Plans", "road-trip-2" }) |sid| {
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

/// A uid as allocateUser writes one: digits, the first not zero.
fn canonicalUid(s: []const u8) bool {
    if (s.len == 0 or s[0] == '0') return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// **A `uid:` THAT IS NOT EMPTY AND NOT CANONICAL IS DAMAGED DATA**: the
/// Roc's Transcript.Author has no such value, so its decode refuses the
/// whole file where chatDecodeFile keeps the bytes.
fn corruptAuthor(ms: []const ChatMessage) bool {
    for (ms) |m| if (m.uid.len != 0 and !canonicalUid(m.uid)) return true;
    return false;
}

/// The Roc's decode against chatDecodeFile's, field by field, the refused
/// count too; a file with a corrupt author refused, no answer.
fn decodeAgrees(a: std.mem.Allocator, data: []const u8, differ: *Differences) !void {
    const before = chat_codec.refused_blocks;
    const zm = try chat_codec.decodeChatFile(a, data);
    const zrefused = chat_codec.refused_blocks - before;
    const got = try roc(a, .decode_file, &.{data});
    if (corruptAuthor(zm)) {
        if (got.len != 0) differ.add("decode(\"{f}\"): a corrupt uid, roc answered {d} fields", .{ std.zig.fmtString(data), got.len });
        return;
    }
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
            const got = try roc1(a, .stored_form, &.{ idx, m.id, m.from, m.at, m.uid, m.markdown });
            compared += 1;
            // A uid neither empty nor canonical is no Author: no block.
            if (m.uid.len != 0 and !canonicalUid(m.uid)) {
                if (got != null) differ.add("storedForm(uid \"{f}\"): not a uid, roc made a block", .{std.zig.fmtString(m.uid)});
                try file.appendSlice(a, zs);
                continue;
            }
            const rs = got orelse {
                differ.add("storedForm(uid \"{f}\"): roc made no block", .{std.zig.fmtString(m.uid)});
                continue;
            };
            if (!std.mem.eql(u8, zs, rs)) differ.add("storedForm({d}, \"{f}\"): zig \"{f}\", roc \"{f}\"", .{ index, std.zig.fmtString(m.markdown), std.zig.fmtString(zs), std.zig.fmtString(rs) });
            try file.appendSlice(a, zs);
        }
        try decodeAgrees(a, file.items, &differ);
        compared += 1;
    }
    // **THE ROC'S BLOCK READS BACK AS THE MESSAGE IT STORED** (C8a: the
    // Roc writes the block the store appends): a message as a send makes
    // one, its markdown generated (separators bare and escaped, backslashes,
    // CR, empty lines, a trailing newline, bytes not UTF-8), first or not.
    const names = [_][]const u8{ "Steve", "Q\"uote\\back\x01ctl\ttab caf\u{e9}", "caf\xe9\xff", "a: b" };
    for (try codecStrings(a, 0x5704ee, 2000, 12), 0..) |md, n| {
        const index: usize = n % 3;
        const m: ChatMessage = .{ .id = try std.fmt.allocPrint(a, "t_{d}", .{index + 1}), .from = names[n % names.len], .at = "2025-10-25T13:46:40Z", .uid = if (n % 5 == 0) "" else "17", .markdown = md };
        const rs = (try roc1(a, .stored_form, &.{ try std.fmt.allocPrint(a, "{d}", .{index}), m.id, m.from, m.at, m.uid, m.markdown })).?;
        const back = try chat_codec.decodeChatFile(a, rs);
        compared += 1;
        if (back.len != 1 or !std.mem.eql(u8, back[0].id, m.id) or !std.mem.eql(u8, back[0].from, m.from) or !std.mem.eql(u8, back[0].at, m.at) or !std.mem.eql(u8, back[0].uid, m.uid) or !std.mem.eql(u8, back[0].markdown, m.markdown))
            differ.add("decodeChatFile(the Roc's stored form of \"{f}\") is not that message", .{std.zig.fmtString(m.markdown)});
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
    var recorded: Frozen = .{};
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
                // Frozen (metal-vmm QUEUE 277): chat_count.recordedAuthor is gone.
                recorded.add(try roc(a, .recorded_author, &.{ raw, bl, sz }));
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
    try recorded.check("recordedAuthor", "74dd43ac217aa053c4c11ffff72369073e09997b807299df422740f36ed21837", 48480);
}

test "Count: the window at the record's offset, believed or read the slow way (frozen, metal-vmm QUEUE 277: chat_count.windowLast is gone)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var frozen: Frozen = .{};
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
        const c = try std.fmt.allocPrint(a, "{d}", .{count});
        frozen.add(try roc(a, .window_last, &.{ c, w, if (full) "1" else "0", "t" }));
    };
    try frozen.check("windowLast", "e61bf497f605905f2e9a3638b6c6f4f3e86947ec154476501c4dca7c7a1e7f9e", 8000);
}

// ── Frame (chat_frame.zig) ─────────────────────────────────────────────────

test "Frame: a message's frame and a reaction's, whatever their bytes" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    // The author, id, markdown and cid are text: the Roc's frame takes them
    // decoded.
    const strings = try utf8Only(a, try byteStrings(a));
    const ts = try times(a);
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
            // The author is a canonical uid: the Roc's frame takes a Uid.
            .from_uid = ([_][]const u8{ "1", "3", "10", "12" })[i % 4],
            // The stamp as the Roc makes it (Time's twin holds it to timefmt).
            .at = try timefmt.formatRFC3339UTC(a, ts[r.uintLessThan(usize, ts.len)]),
            .id = pick(r, strings),
            .markdown = if (i % 2 == 0) pick(r, strings) else textOr((try codecMessage(a, r)).markdown, ""),
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

// ── Form, Reaction (webbox http.formField; the old reactions.zig, frozen) ──

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
        // A value that is not UTF-8 is malformed at the Roc's door, where
        // formField passed its bytes on.
        const want: []const []const u8 = if (http.formField(a, body, name)) |found|
            (if (found) |v| (if (std.unicode.utf8ValidateSlice(v)) &.{ "F", v } else &.{"M"}) else &.{})
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

test "Reaction: the react form judged as parseReactForm judged it, and one glyph as validEmoji knew one (frozen, metal-vmm QUEUE 263c)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var forms_judged: Frozen = .{};
    var glyphs_known: Frozen = .{};
    var n_forms: usize = 0;
    for (try forms(a)) |body| {
        forms_judged.add(try roc(a, .react_form, &.{body}));
        n_forms += 1;
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
    for (glyphs.items) |g| glyphs_known.add(&.{if (yes((try roc1(a, .is_valid_emoji, &.{g})).?)) "1" else "0"});
    try forms_judged.check("the react form", "694e4c1f2aecc4419ebac7230f9396cecd828db053f3a903674d7618d8dd8cef", n_forms);
    try glyphs_known.check("validEmoji", "de934d7b51d94412d43371e92321110bf70671c6e835b891263627378024e341", glyphs.items.len);
}

test "Reaction: the sidecar's line as reactionLine wrote it, field order and escapes, over generated uids, names, emoji, stamps and on or off" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var frozen: Frozen = .{};
    const strings = try byteStrings(a);
    // The reactor's name and the emoji are text: the Roc's line takes them
    // decoded (a name at list_accounts!'s door, an emoji at the form's).
    const texts = try utf8Only(a, strings);
    var rng = std.Random.DefaultPrng.init(0x4eac71);
    const r = rng.random();
    const pick = struct {
        fn f(rr: std.Random, ss: []const []const u8) []const u8 {
            return ss[rr.uintLessThan(usize, ss.len)];
        }
    }.f;
    const ts = try times(a);
    for (0..4000) |i| {
        const msg: u64 = switch (i % 4) {
            0 => 1,
            1 => r.int(u32),
            2 => std.math.maxInt(u64),
            else => r.int(u64),
        };
        // The stamp as the Roc makes it (Time's twin holds it to timefmt),
        // and the reactor a canonical uid: the Roc's line takes a Uid.
        const at = try timefmt.formatRFC3339UTC(a, ts[r.uintLessThan(usize, ts.len)]);
        const uid = pick(r, &.{ "1", "3", "10", "12", "4294967296" });
        const from = pick(r, texts);
        const emoji = pick(r, texts);
        const on = r.boolean();
        const got = (try roc1(a, .reaction_line, &.{ try std.fmt.allocPrint(a, "{d}", .{msg}), uid, from, emoji, if (on) "1" else "0", at })).?;
        frozen.add(&.{got});
    }
    try frozen.check("reactionLine", "1f17da2b5bdd2e60042ba831bc805e830671f6fd026733902a9340a6448cefef", 4000);
}

// ── Chrome, Pages, Html (chat_chrome.zig, the old chat_page.zig, webbox html.zig) ──

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
    // The title, viewer and bold link are text: the Roc's shell takes them
    // decoded.
    const texts = try utf8Only(a, try pageTexts(a));
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

test "Pages: the 404 that says why, the first-topic shell, the empty /chat and the conversation page as the Zig wrote them (frozen, metal-vmm QUEUE 263d, 271)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    // The four pages the Zig no longer writes are frozen: hashed over the
    // Roc's answers taken while the Zig's agreed (noTopicsHtml,
    // noConversationsHtml, conversationHtml; notFoundHtml since 271). They
    // name each script by a fixed hash, so editing one does not move them.
    var frozen: Frozen = .{};
    var fixed_pairs: std.ArrayList([]const u8) = .empty;
    inline for (chrome.assets) |asset| try fixed_pairs.appendSlice(a, &.{ asset.name, "/chat/" ++ asset.name ++ "?h=0" });
    // Every text a page shows is text: the Roc's pages take it decoded.
    const texts = try utf8Only(a, try pageTexts(a));
    const accept = chat_upload.accept;
    const digits = struct {
        fn f(al: std.mem.Allocator, n: anytype) ![]const u8 {
            return std.fmt.allocPrint(al, "{d}", .{n});
        }
    }.f;
    for (texts, 0..) |t, i| {
        const u = texts[(i * 5 + 1) % texts.len];
        const w = texts[(i * 11 + 2) % texts.len];
        frozen.add(&.{ "not_found_page", (try roc1(a, .not_found_page, try std.mem.concat(a, []const u8, &.{ &.{ t, u, w }, fixed_pairs.items }))).? });
        const shells = [_]struct { f: Fn, args: []const []const u8 }{
            .{ .f = .no_topics_page, .args = &.{ t, u, w } },
            .{ .f = .no_conversations_page, .args = &.{t} },
        };
        for (shells) |c| {
            // The first-topic shell's base is text: the Roc's takes it decoded.
            if (c.f == .no_topics_page and !std.unicode.utf8ValidateSlice(u)) continue;
            frozen.add(&.{ @tagName(c.f), (try roc1(a, c.f, try std.mem.concat(a, []const u8, &.{ c.args, fixed_pairs.items }))).? });
        }
        // The key, base and topic are text and the uid a canonical one: the
        // Roc's page takes them decoded.
        if (!std.unicode.utf8ValidateSlice(t) or !std.unicode.utf8ValidateSlice(u) or !std.unicode.utf8ValidateSlice(w)) continue;
        const args: []const []const u8 = &.{ t, u, w, texts[(i * 3) % texts.len], ([_][]const u8{ "1", "3", "10", "12" })[i % 4], texts[(i * 19) % texts.len], texts[(i * 23) % texts.len], try digits(a, chat_upload.image_max), try digits(a, chat_upload.video_max), accept, try digits(a, @import("search_tokens.zig").min_len) };
        frozen.add(&.{ "conversation_page", (try roc1(a, .conversation_page, try std.mem.concat(a, []const u8, &.{ args, fixed_pairs.items }))).? });
    }
    try frozen.check("pages", "d4cfea032676f61fc04aa022ba96c923e4c5bf536f1c7a3564b29dd347e1909b", 656);
}

test "Pages: the sidebar's JSON for every viewer, conversation, pin and topic list tried, script-safe (frozen, metal-vmm QUEUE 263c)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var frozen: Frozen = .{};
    const Other = struct { id: []const u8, name: []const u8, online: bool };
    var rng = std.Random.DefaultPrng.init(0x51deba7);
    const r = rng.random();
    const names = [_][]const u8{ "Steve", "Ada \"the\" </script>", "caf\xc3\xa9", "", "\x01", "Bo" };
    const ids = [_][]const u8{ "1", "2", "3", "10", "12" };
    // A topic named as a channel is, and a channel named as a DM's pair:
    // what is active is the conversation of its kind.
    const sids = [_][]const u8{ "general", "Plans", "plans", "a</b", "x\"y", "2026-10-25", "ops" };
    const chans = [_][]const u8{ "ops", "team", "a</", "b\"c", "1_2", "2_3" };
    for (0..800) |_| {
        const uid = ids[r.uintLessThan(usize, ids.len)];
        var others: std.ArrayList(Other) = .empty;
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
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ uid, if (dm) "1" else "0", key, base, sid, try std.fmt.allocPrint(a, "{d}", .{others.items.len}) });
        for (others.items) |o| try args.appendSlice(a, &.{ o.id, o.name, if (o.online) "1" else "0" });
        for ([_][]const []const u8{ channels.items, pins.items, topics.items }) |list| {
            try args.append(a, try std.fmt.allocPrint(a, "{d}", .{list.len}));
            try args.appendSlice(a, list);
        }
        frozen.add(&.{(try roc1(a, .sidebar_json, args.items)).?});
    }
    try frozen.check("the sidebar", "d4b9885b81fee8ed297eb6e3800575d86456b3c4924d9b7002b6f2197eb9093c", 800);
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

/// A member's feed file, from pieces near each rule images_store and
/// code_store read by: separators and near misses, headers well and badly
/// formed, `<img` tags in every case and spacing, fences of each character,
/// length, indent and close, quotes, CRs, JSON's escapes, `</script>` and
/// bytes that are not UTF-8.
fn feedFile(a: std.mem.Allocator, r: std.Random) ![]const u8 {
    const seps = [_][]const u8{ "\n\n-------------\n\n", "\n\n-------------\n\n", "\n\n------------\n\n", "\n-------------\n", "\n\n-------------\n\n\n\n-------------\n\n", " \t\n\n-------------\n\n\r\n" };
    const headers = [_][]const u8{
        "Sent by ann at 2026-05-29T01:56:58Z, source MSG_general1_5 in 1_2:",
        "Sent by Bo at 2026-01-01T00:00:00Z, source MSG_Plans_12 in ops:",
        "Sent by a at b at c, source MSG_x_1 in 1_2 in 3_4:",
        "Sent by x at y, source MSG_s_1 in c, source MSG_t_2 in d:",
        "Sent by  at , source MSG_ in :",
        "Sent by ann at t, source MSG__1 in 1_2:",
        "Sent by ann at t, source MSG_noid in 1_2:",
        "Sent by ann at t, source MSG_x_1 in 1_2",
        "Sent byann at t, source MSG_x_1 in 1_2:",
        "Sent by ann, source MSG_x_1 in 1_2:",
        "Sent by ann at t, source MSG_x_1 1_2:",
        "Sent by \"q\\\" </script> at caf\xc3\xa9, source MSG_a\x01b_3 in o\xe2\x98\x83ps:",
        "  Sent by ann at t, source MSG_x_1 in 1_2:",
        "Sent by ann at t, source MSG_x_1 in 1_2:\r",
    };
    const lines = [_][]const u8{
        "<img src=\"/u/a.png\" alt=\"a\">", "<IMG\tsrc=x>",      "<Img\nsrc=y\n>",     "<img>",                    "<imgx src=z>",
        "<img src=no-close",                "x<img  a>b<img b>", "<img\x0bv>",         "<img\x0cw>",               "```",
        "```zig",                           "````zig extra",     "~~~ quote",          "~~~~ quote",               "~~~",
        "~~~~",                             "   ```py",          "    ```indented",    "``` `bad",                 "~~~ `fine",
        "```x\r",                           "`````",             "```````````",        "``` ```",                  "```close",
        "const x = 1;",                     "  code \"q\" \\",   "</script>",          "caf\xc3\xa9 \xe2\x98\x83", "\t",
        "",                                 "\r",                "In MSG_a_1 I said:", "hello <b>",                "~~ two",
        "```zig\textra",                    "~~~ quote\tx",      "~~~\tquote",
    };
    var out: std.ArrayList(u8) = .empty;
    if (r.boolean()) try out.appendSlice(a, seps[r.uintLessThan(usize, seps.len)]);
    for (0..r.uintAtMost(usize, 8)) |k| {
        if (k > 0) try out.appendSlice(a, seps[r.uintLessThan(usize, seps.len)]);
        if (r.uintLessThan(u8, 8) != 0) try out.appendSlice(a, headers[r.uintLessThan(usize, headers.len)]);
        for (0..r.uintAtMost(usize, 7)) |_| {
            try out.append(a, '\n');
            try out.appendSlice(a, lines[r.uintLessThan(usize, lines.len)]);
        }
    }
    if (r.boolean()) try out.appendSlice(a, " \n\t\r");
    return out.items;
}

test "Feeds: a member's images.md and code.md read and sent to their pages as images_store and code_store do, over text with every rule's near misses (a feed file is UTF-8 at Files.read!'s door)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    // Frozen (metal-vmm QUEUE 263c): the files' readers the twin held
    // these to (parseImagesFile, parseCodeFile) are retired.
    var frozen: Frozen = .{};
    var rng = std.Random.DefaultPrng.init(0xfeed5);
    const r = rng.random();
    var entries_seen: usize = 0;
    var blocks_seen: usize = 0;
    for (0..3000) |_| {
        const text = try feedFile(a, r);
        const most = r.uintAtMost(usize, 10);
        const ri = (try roc1(a, .images_feed, &.{ text, try std.fmt.allocPrint(a, "{d}", .{most}) })).?;
        const rc = (try roc1(a, .code_feed, &.{text})).?;
        frozen.add(&.{ ri, rc });
        entries_seen += std.mem.count(u8, rc, "\"source_id\"");
        blocks_seen += std.mem.count(u8, rc, "\"lang\"");
    }
    try frozen.check("the images and code feeds", "ddf59582cfd0c91920b732e9fd911b3498b407b251edd419470d3580858d0038", 3000);
    // The corpus reached what it means to: entries, and their blocks.
    try testing.expect(entries_seen > 1000 and blocks_seen > 1000);
}

test "Feeds: a code body holding the separator and a forged header stays one entry, from its real sender, as the Roc reads code.md (metal-vmm QUEUE 266)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    const forged = "x\n\n-------------\n\nSent by Mallory at 2026-01-01T00:00:00Z, source MSG_f_1 in 1_2:\n\\-------------\ny";
    const real: code_store.CodeEntry = .{ .source_id = "t_1", .from = "ann", .conv = "1_2", .at = "2026-10-27T00:00:00Z", .blocks = &.{.{ .lang = "", .body = forged }} };
    const other: code_store.CodeEntry = .{ .source_id = "t_2", .from = "bob", .conv = "1_2", .at = "2026-10-27T00:00:01Z", .blocks = &.{.{ .lang = "zig", .body = "ok" }} };
    const file = try std.mem.concat(a, u8, &.{ try code_store.formatCodeEntry(a, real), images_store.images_sep, try code_store.formatCodeEntry(a, other) });
    const got = (try roc1(a, .code_feed, &.{file})).?;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, "\"source_id\""));
    try testing.expect(std.mem.indexOf(u8, got, "\"from\":\"ann\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"from\":\"bob\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"from\":\"Mallory\"") == null);
    // Read back as sent: the escape is taken off.
    try testing.expect(std.mem.indexOf(u8, got, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(forged, .{})})) != null);
}

test "Feeds: an image tag carrying the separator and a header plants no entry of its own, as the Roc reads images.md (metal-vmm QUEUE 185)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    const forged = "<img src=\"/x.png\" alt=\"" ++ images_store.images_sep ++ "Sent by mallory at 2026-01-01T00:00:00Z, source MSG_fake in 9_9:\n<img src=\"/evil.png\">\">";
    const real: images_store.ImagesEntry = .{ .source_id = "t_1", .from = "ann", .conv = "1_2", .at = "2026-10-13T00:00:00Z", .images = &.{forged} };
    const text = try std.mem.concat(a, u8, &.{ try images_store.formatImagesEntry(a, real), images_store.images_sep, try images_store.formatImagesEntry(a, real) });
    const got = (try roc1(a, .images_feed, &.{ text, "10" })).?;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, "\"from\":\"ann\""));
    try testing.expect(std.mem.indexOf(u8, got, "mallory") == null);
}

/// A message's markdown from pieces near each rule recentExcerpt reads by:
/// quote fences of every length (one in another), code fences, `<img` and
/// `![…](…)` whole and broken, every whitespace, long runs past the cap,
/// codepoints of each length. Text only: a message is UTF-8 (its form
/// refuses any other), and the Roc's excerpt takes it decoded; the parts
/// that are bytes no codepoint starts are left out.
fn excerptText(a: std.mem.Allocator, r: std.Random) ![]const u8 {
    const parts = [_][]const u8{
        "In MSG_x_1 I said:", "~~~ quote",   "~~~~ quote",   "~~~",      "~~~~",                                     "```",                                                                                                                                                                                                                                              "```zig",      "   ```",
        "    ```",            "<img src=x>", "<IMG\nsrc=y>", "<imgx a>", "<img_ b>",                                 "<img",                                                                                                                                                                                                                                             "<img>",       "<img9>",
        "![alt](u.png)",      "![a](b",      "![](x)",       "![a] (x)", "!",                                        "[",                                                                                                                                                                                                                                                "hi",          "there",
        " ",                  "\t",          "\r",           "\x0b",     "\x0c",                                     "  ",                                                                                                                                                                                                                                               "caf\xc3\xa9", "\xe2\x82\xac",
        "\xf0\x9f\x91\x8d",   "\xff",        "\x80",         "\xc3",     "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9", "</script>",   "\"q\\",
    };
    var out: std.ArrayList(u8) = .empty;
    for (0..r.uintAtMost(usize, 30)) |_| {
        const part = parts[r.uintLessThan(usize, parts.len)];
        if (std.unicode.utf8ValidateSlice(part)) try out.appendSlice(a, part);
        try out.append(a, if (r.uintLessThan(u8, 3) == 0) '\n' else if (r.boolean()) ' ' else 'x');
    }
    // Sometimes far past the cap.
    if (r.uintLessThan(u8, 6) == 0) for (0..r.uintAtMost(usize, 40)) |_| try out.appendSlice(a, if (r.boolean()) "word \xc3\xa9t\xc3\xa9 " else "\u{1F44D}x y\u{2603} ");
    return out.items;
}

test "Recent: a message's excerpt as recentExcerpt makes it, for every text tried" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var rng = std.Random.DefaultPrng.init(0x4ecee7);
    const r = rng.random();
    var compared: usize = 0;
    var cut: usize = 0;
    for (0..3000) |_| {
        const md = try excerptText(a, r);
        const z = try recent_feed.recentExcerpt(a, md);
        if (std.mem.endsWith(u8, z, "\xe2\x80\xa6")) cut += 1;
        compared += 1;
        const got = (try roc1(a, .recent_excerpt, &.{md})).?;
        if (!std.mem.eql(u8, z, got)) differ.add("excerpt(\"{f}\"):\n  zig \"{f}\"\n  roc \"{f}\"", .{ std.zig.fmtString(md), std.zig.fmtString(z), std.zig.fmtString(got) });
    }
    try differ.none(compared);
    try testing.expect(cut > 50);
}

/// One gathered row, as recent.zig's `Row` had it.
const RecentRow = struct { doc: bool, secs: i64, uid: []const u8, name: []const u8, key: []const u8, label: []const u8, topic: []const u8, markdown: []const u8, dm: bool };

test "Recent: the feed's JSON from the rows gathered, named, dated and ordered as recent.zig did, ties and all (frozen, metal-vmm QUEUE 263d)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var frozen: Frozen = .{};
    var rng = std.Random.DefaultPrng.init(0x4ece47);
    const r = rng.random();
    const secs = [_]i64{ 0, 1, 1_790_000_000, 1_790_000_000, 1_790_000_001, -86_401, 253_402_300_799 };
    const keys = [_][]const u8{ "/chat/c/1_2/Plans", "/chat/c/1_2/plans", "/chat/c/1_2/Plan", "/channel/ops/a", "/channel/ops/a", "notes", "notes-2", "", "/chat/c/1_2/caf\xc3\xa9" };
    const uids = [_][]const u8{ "", "1", "2", "3" };
    // A row's fields are text: the Roc's door fails a request on any that is not.
    const names = [_][]const u8{ "", "Debbie", "Ann \"A\" </script>", "caf\xc3\xa9" };
    const labels = [_][]const u8{ "", "to Debbie", "in ops", "My \"doc\"" };
    for (0..1500) |_| {
        var rows: std.ArrayList(RecentRow) = .empty;
        for (0..r.uintAtMost(usize, 9)) |_| try rows.append(a, .{
            .doc = r.uintLessThan(u8, 4) == 0,
            .secs = secs[r.uintLessThan(usize, secs.len)],
            .uid = uids[r.uintLessThan(usize, uids.len)],
            .name = names[r.uintLessThan(usize, names.len)],
            .key = keys[r.uintLessThan(usize, keys.len)],
            .label = labels[r.uintLessThan(usize, labels.len)],
            .topic = if (r.boolean()) "Plans" else "",
            .markdown = if (r.boolean()) try excerptText(a, r) else "",
            .dm = r.boolean(),
        });
        const me = uids[1 + r.uintLessThan(usize, 3)];
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, me);
        for (rows.items) |w| try args.appendSlice(a, &.{ if (w.doc) "1" else "0", try std.fmt.allocPrint(a, "{d}", .{w.secs}), w.uid, w.name, w.key, w.label, w.topic, w.markdown, if (w.dm) "1" else "0" });
        frozen.add(&.{(try roc1(a, .recent_json, args.items)).?});
    }
    try frozen.check("recent", "55b15c68bd5277f58549fb10b213dd2fe0636db50282ab58c8970ee6eb1d1e7e", 1500);
}

// ── ChatState (chat_state.zig) ─────────────────────────────────────────────

/// Topic names that meet: ChitChat (firstOf's pick) and a case-twin of it,
/// dates, `general<N>`, names that sort before and after each other by byte
/// (`Z` before `a`), and a name no list has.
const state_names = [_][]const u8{ "ChitChat", "chitchat", "general", "general2", "Plans", "2026-10-25", "a", "Z", "b c", "\xe2\x98\x83" };

test "ChatState: where a bare DM resumes, for every topic list, order and last view tried" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0x7e503);
    const r = rng.random();
    const nows = [_]i64{ 1761400000, 0, -1, 951782400, 253402300799, -62135596800 };
    var picks = [_]usize{ 0, 0, 0 };
    for (0..4000) |k| {
        // The edge cases first, then lists of up to six in any order (the
        // store lists them sorted; firstOf takes the first it is given).
        // A listed topic and the last view are text (Files.list!'s and
        // Files.read!'s doors).
        const text_names = state_names;
        var topics: std.ArrayList([]const u8) = .empty;
        const n: usize = if (k < 200) k % 3 else r.uintAtMost(usize, 6);
        for (0..n) |_| try topics.append(a, text_names[r.uintLessThan(usize, text_names.len)]);
        const last: []const u8 = switch (r.uintLessThan(u8, 4)) {
            0 => "",
            1 => "Gone",
            else => if (topics.items.len > 0 and r.boolean()) topics.items[r.uintLessThan(usize, topics.items.len)] else state_names[r.uintLessThan(usize, state_names.len)],
        };
        const now = if (r.boolean()) nows[r.uintLessThan(usize, nows.len)] else r.intRangeAtMost(i64, -62135596800, 253402300799);
        const z = try chat_state.chooseResumeTopic(a, topics.items, last, now);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ last, try std.fmt.allocPrint(a, "{d}", .{now}) });
        try args.appendSlice(a, topics.items);
        const got = (try roc1(a, .resume_topic, args.items)).?;
        compared += 1;
        // Which way it went, so a generator that never reaches one is seen.
        const way: usize = if (last.len != 0 and std.mem.eql(u8, z, last)) 0 else if (chat_paths.firstOf(topics.items).len > 0) 1 else 2;
        picks[way] += 1;
        if (!std.mem.eql(u8, z, got)) differ.add("resume(last \"{f}\", now {d}, {d} topics): zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(last), now, topics.items.len, std.zig.fmtString(z), std.zig.fmtString(got) });
    }
    try differ.none(compared);
    for (picks) |p| try testing.expect(p > 300);
}

test "ChatState: a pinned file with one topic pinned or unpinned, byte for byte, or removed, whatever text the file held (frozen, metal-vmm QUEUE 263c)" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var frozen: Frozen = .{};
    var removed: usize = 0;
    var rng = std.Random.DefaultPrng.init(0x919);
    const r = rng.random();
    // Lines as a file may hold them: padded, blank, CRLF, repeated, bytes
    // that sort high, and a line that is only spaces.
    const lines = [_][]const u8{ "Plans", "Plans", "Other", " Plans ", "\tb\r", "", "   ", "a", "B", "ChitChat", "\xc3\xa9", "\xe2\x98\x83", "a b", "Plans\r" };
    const sids = [_][]const u8{ "Plans", "Other", "a", "new", "a b", "\xe2\x98\x83", "B", " Plans" };
    for (0..5000) |k| {
        var file: std.ArrayList(u8) = .empty;
        // The first few: no file (""), then any lines.
        const n: usize = if (k < 50) 0 else r.uintAtMost(usize, 7);
        for (0..n) |i| {
            if (i > 0) try file.appendSlice(a, if (r.uintLessThan(u8, 4) == 0) "\r\n" else "\n");
            try file.appendSlice(a, lines[r.uintLessThan(usize, lines.len)]);
        }
        if (n > 0 and r.boolean()) try file.append(a, '\n');
        const sid = sids[r.uintLessThan(usize, sids.len)];
        const pin = r.boolean();
        const got = try roc(a, .pinned, &.{ file.items, sid, if (pin) "1" else "0" });
        if (got.len > 1) return error.TwinGaveMore;
        if (got.len == 0) removed += 1;
        frozen.add(got);
    }
    try frozen.check("the pinned file", "5cffb42e35b19e9a8513bf834682c57bb4cd24f1e25a115840a1d9dfecb74c1b", 5000);
    try testing.expect(removed > 100);
}

/// **A CHAT ROOT ON DISK, FOR THE TWINS WHOSE ZIG READS AND WRITES**: the
/// bookmarks' Zig is held as it runs, files and all; `deinit` puts the root
/// back.
const DiskRoot = struct {
    tmp: testing.TmpDir,
    saved: []const u8,
    threaded: std.Io.Threaded,

    fn init(d: *DiskRoot, a: std.mem.Allocator) !void {
        d.tmp = testing.tmpDir(.{});
        d.saved = chat_store.chat_root;
        chat_store.chat_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &d.tmp.sub_path, "chat" });
        d.threaded = std.Io.Threaded.init(testing.allocator, .{});
    }
    fn deinit(d: *DiskRoot) void {
        d.threaded.deinit();
        chat_store.chat_root = d.saved;
        d.tmp.cleanup();
    }
    fn at(_: *DiskRoot, a: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(a, &.{ chat_store.chat_root, rel });
    }
};

/// A bookmark file as it may be found: the value, padded with every byte
/// the trim takes and some it does not, CRLF, blank, a lone newline, lines
/// after it, and longer than the 256 bytes the Zig's bounded read takes.
fn bookmarkFile(a: std.mem.Allocator, r: std.Random, value: []const u8) ![]const u8 {
    const pads = [_][]const u8{ "", " ", "\t", "\r", "\n", "\r\n", "  \t", "\x0b", "\x00", "\n\n" };
    switch (r.uintLessThan(u8, 10)) {
        0 => return "",
        1 => return "\n",
        2 => return try std.mem.concat(a, u8, &.{ value, "\n", "other\n" }),
        3 => {
            // Around 256 bytes: the value, padded to 250-262.
            const n = 250 + r.uintAtMost(usize, 12);
            const out = try a.alloc(u8, @max(n, value.len + 1));
            @memset(out, ' ');
            @memcpy(out[0..value.len], value);
            out[out.len - 1] = '\n';
            return out;
        },
        else => return try std.mem.concat(a, u8, &.{ pads[r.uintLessThan(usize, pads.len)], if (r.uintLessThan(u8, 6) == 0) "Other" else value, pads[r.uintLessThan(usize, pads.len)], pads[r.uintLessThan(usize, pads.len)] }),
    }
}

const bookmark_values = [_][]const u8{ "1_2", "Plans", "a", "2026-10-25", "general2", "\xe2\x98\x83", "a b", x256[0..255], &x256 };
const x256: [256]u8 = @splat('x');

test "ChatState: the last-conv and last-sessions files read back as lastUserConv and lastViewedTopic read them, whatever text they hold, and none when there is none" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var d: DiskRoot = undefined;
    try d.init(a);
    defer d.deinit();
    const io = d.threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0xb00c);
    const r = rng.random();
    const lc = try d.at(a, "users/1/last-conv");
    const ls = try d.at(a, "users/1/last-sessions/1_2");
    for (0..3000) |k| {
        const missing = k % 20 == 0;
        const file = try bookmarkFile(a, r, bookmark_values[r.uintLessThan(usize, bookmark_values.len)]);
        for ([_][]const u8{ lc, ls }) |p| {
            if (missing) try disk.remove(io, a, p) else try disk.write(io, a, p, file, .{});
        }
        // lastUserConv, which read the last-conv file the same way, is
        // retired (metal-vmm QUEUE 263c); lastViewedTopic still reads.
        const zv = try chat_state.lastViewedTopic(io, a, "1", "1_2");
        const got = (try roc1(a, .bookmark, if (missing) &.{ "M", "" } else &.{ "F", file })).?;
        compared += 1;
        if (!std.mem.eql(u8, zv, got)) differ.add("last-sessions \"{f}\": zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(file), std.zig.fmtString(zv), std.zig.fmtString(got) });
    }
    try differ.none(compared);
}

test "ChatState: whether a bookmark is written, and as what, as setLastViewedTopic decides on disk: unchanged, changed, missing, past 256 bytes, or unreadable" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var d: DiskRoot = undefined;
    try d.init(a);
    defer d.deinit();
    const io = d.threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var ways = [_]usize{ 0, 0 };
    var rng = std.Random.DefaultPrng.init(0xc4a9);
    const r = rng.random();
    const lc = try d.at(a, "users/1/last-conv");
    const ls = try d.at(a, "users/1/last-sessions/1_2");
    for (0..3000) |k| {
        const value = bookmark_values[r.uintLessThan(usize, bookmark_values.len)];
        // The DM last in already says so: only the topic's file can change.
        try disk.write(io, a, lc, "1_2\n", .{});
        const How = enum { found, missing, unreadable };
        const how: How = if (k % 25 == 0) .missing else if (k % 25 == 1) .unreadable else .found;
        const file = try bookmarkFile(a, r, value);
        try std.Io.Dir.cwd().deleteTree(io, ls);
        switch (how) {
            .found => try disk.write(io, a, ls, file, .{}),
            .missing => {},
            // A folder: it will not read, and will not be written either.
            .unreadable => try std.Io.Dir.cwd().createDirPath(io, ls),
        }
        const before = disk.changes.load(.acquire);
        // The Zig tried to write when it changed the disk, or when its
        // write failed (only a write fails on a folder it read past).
        const z_wrote = if (chat_state.setLastViewedTopic(io, a, "1", "1_2", value)) |_| disk.changes.load(.acquire) > before else |_| true;
        const args: []const []const u8 = switch (how) {
            .found => &.{ "F", file, value },
            .missing => &.{ "M", "", value },
            .unreadable => &.{ "X", "", value },
        };
        const got = try roc(a, .bookmark_changed, args);
        compared += 1;
        const r_wrote = std.mem.eql(u8, got[0], "1");
        ways[@intFromBool(z_wrote)] += 1;
        if (z_wrote != r_wrote) differ.add("changed({t}, {d} bytes \"{f}\", \"{f}\"): zig {}, roc {}", .{ how, file.len, std.zig.fmtString(file[0..@min(file.len, 40)]), std.zig.fmtString(value[0..@min(value.len, 40)]), z_wrote, r_wrote });
        // What the Roc writes is what the Zig wrote.
        if (z_wrote and how != .unreadable) {
            const now = try disk.read(io, a, ls, .unlimited);
            if (!std.mem.eql(u8, now, got[1])) differ.add("written for \"{f}\": zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(value), std.zig.fmtString(now), std.zig.fmtString(got[1]) });
        }
    }
    try differ.none(compared);
    for (ways) |w| try testing.expect(w > 300);
}

test "ChatState: the member's files are where the Zig writes them: the DM last in, the topic last viewed, the pins" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var d: DiskRoot = undefined;
    try d.init(a);
    defer d.deinit();
    const io = d.threaded.io();
    for ([_][2][]const u8{ .{ "1", "1_2" }, .{ "7", "7_12" }, .{ "12", "12_12" }, .{ "3", "ops" } }) |uc| {
        const uid = uc[0];
        const conv = uc[1];
        try chat_state.setLastViewedTopic(io, a, uid, conv, "Plans");
        const got = try roc(a, .state_paths, &.{ uid, conv });
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\n", .{conv}), try disk.read(io, a, try d.at(a, got[0]), .unlimited));
        try testing.expectEqualStrings("Plans\n", try disk.read(io, a, try d.at(a, got[1]), .unlimited));
        // The pins the Roc writes (its pin route) are where the Zig reads
        // them (pinnedTopics); setTopicPinned, the Zig's writer, is retired.
        try disk.write(io, a, try d.at(a, got[2]), "Plans\n", .{});
        try testing.expectEqualStrings("Plans", (try chat_state.pinnedTopics(io, a, uid, conv))[0]);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "users/{s}/images.md", .{uid}), got[3]);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "users/{s}/code.md", .{uid}), got[4]);
    }
}

// ── Conversation (chat.zig's lookup: findConv, convTitle, findTopic) ──────

/// Halves of a DM key as a path may write them: uids, a zero, leading
/// zeros, numbers past i64, signs, letters, `..`, an underscore, a byte
/// that is not UTF-8, nothing.
const key_halves = [_][]const u8{ "", "0", "1", "2", "3", "9", "10", "01", "007", "12", "21", "99999999999999999999", "9223372036854775807", "9223372036854775808", "a", "..", "1a", "-1", "+1", "1_2", "\xff", " 1" };

test "Conversation: who a DM's other half is, for the member or not, over every key tried, malformed ones too, and its members" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    var found: usize = 0;
    var rng = std.Random.DefaultPrng.init(0xd0_07e5);
    const r = rng.random();
    var keys: std.ArrayList([]const u8) = .empty;
    for (key_halves) |x| for (key_halves) |y| {
        try keys.appendSlice(a, &.{ try std.fmt.allocPrint(a, "{s}_{s}", .{ x, y }), try std.fmt.allocPrint(a, "{s}__{s}", .{ x, y }), try std.fmt.allocPrint(a, "{s}{s}", .{ x, y }) });
    };
    // And pairs of small uids as a path may write them: either order, a
    // leading zero now and then, the separator doubled or missing.
    for (0..3000) |_| {
        const x = r.uintAtMost(u8, 12);
        const y = r.uintAtMost(u8, 12);
        const zx: []const u8 = if (r.uintLessThan(u8, 8) == 0) "0" else "";
        const zy: []const u8 = if (r.uintLessThan(u8, 8) == 0) "0" else "";
        const sep: []const u8 = switch (r.uintLessThan(u8, 10)) {
            0 => "__",
            1 => "",
            else => "_",
        };
        try keys.append(a, try std.fmt.allocPrint(a, "{s}{d}{s}{s}{d}", .{ zx, x, sep, zy, y }));
    }
    for (keys.items) |key| {
        for ([_][]const u8{ "1", "2", "3", "", "01", "9223372036854775808" }) |me| {
            const z = try chat.dmOther(a, key, me);
            const got = try roc(a, .dm_other, &.{ key, me });
            compared += 1;
            const rz: ?[]const u8 = switch (got.len) {
                0 => null,
                1 => got[0],
                else => return error.TwinGaveMore,
            };
            if (z != null) found += 1;
            const same = if (z) |zb| (rz != null and std.mem.eql(u8, zb, rz.?)) else rz == null;
            if (!same) differ.add("dmOther(\"{f}\", \"{f}\"): zig \"{f}\" ({}), roc \"{f}\" ({})", .{ std.zig.fmtString(key), std.zig.fmtString(me), std.zig.fmtString(z orelse ""), z != null, std.zig.fmtString(rz orelse ""), rz != null });
            // The members the fan-out writes for, once each (ConvMeta.dm),
            // for every key the member is in.
            if (z != null) {
                const us = std.mem.indexOfScalar(u8, key, '_').?;
                const meta = try ConvMeta.dm(a, key[0..us], key[us + 1 ..]);
                const rm = try roc(a, .dm_members, &.{key});
                compared += 1;
                var same_members = rm.len == meta.members.len;
                if (same_members) for (meta.members, rm) |zm, m| {
                    if (!std.mem.eql(u8, zm, m)) same_members = false;
                };
                if (!same_members) differ.add("dm members of \"{f}\": zig {d}, roc {d}", .{ std.zig.fmtString(key), meta.members.len, rm.len });
            }
        }
    }
    try differ.none(compared);
    // The generator reaches the member's DMs, the self-DM among them.
    try testing.expect(found > 300);
}

test "Conversation: a DM's, a channel's and a topic's titles and URL bases, over hostile names, and a topic found without case" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    // Names as an account may hold them, and as it must not: markup, quotes,
    // a script's end, a newline, nothing. Text only: a name is decoded at
    // list_accounts!'s door.
    const names = [_][]const u8{ "", "Debbie", "<b>x</b>", "</script><script>alert(1)</script>", "a\"b'c&d", "line\nbreak", "  ", "Chat w/", ": ", "\u{1F44D}", "#" };
    // The partner is a canonical uid: the door refuses undecodable text;
    // roc test covers it.
    const ids = [_][]const u8{ "2", "10", "9223372036854775808" };
    for (names) |n| for (ids) |id| {
        const z = try chat.dmTitle(a, n, id);
        const got = (try roc1(a, .dm_title, &.{ n, id })).?;
        compared += 1;
        if (!std.mem.eql(u8, z, got)) differ.add("dmTitle(\"{f}\", \"{f}\"): zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(n), std.zig.fmtString(id), std.zig.fmtString(z), std.zig.fmtString(got) });
        for (names) |sid| {
            // A topic is text in the Roc (a TopicAt's Str): one that is not
            // UTF-8 never reaches topicTitle, so it is no case.
            if (!std.unicode.utf8ValidateSlice(sid)) continue;
            const zt = try chat.topicTitle(a, z, sid);
            const rt = (try roc1(a, .topic_title, &.{ z, sid })).?;
            compared += 1;
            if (!std.mem.eql(u8, zt, rt)) differ.add("topicTitle(\"{f}\", \"{f}\"): zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(z), std.zig.fmtString(sid), std.zig.fmtString(zt), std.zig.fmtString(rt) });
        }
    };
    for (names ++ ids) |key| {
        // A channel's title is made for a channel's name alone (a ChannelName).
        if (chat_paths.validChannelName(key)) {
            const zc = try chat.channelTitle(a, key);
            const rc = (try roc1(a, .channel_title, &.{key})).?;
            compared += 1;
            if (!std.mem.eql(u8, zc, rc)) differ.add("channelTitle(\"{f}\"): zig \"{f}\", roc \"{f}\"", .{ std.zig.fmtString(key), std.zig.fmtString(zc), std.zig.fmtString(rc) });
        }
        const bases = try roc(a, .conv_bases, &.{key});
        compared += 2;
        if (!std.mem.eql(u8, try chat.dmBase(a, key), bases[0])) differ.add("dmBase(\"{f}\"): roc \"{f}\"", .{ std.zig.fmtString(key), std.zig.fmtString(bases[0]) });
        if (!std.mem.eql(u8, try chat.channelBase(a, key), bases[1])) differ.add("channelBase(\"{f}\"): roc \"{f}\"", .{ std.zig.fmtString(key), std.zig.fmtString(bases[1]) });
    }
    // A topic among topics, without case: ASCII letters in both cases, the
    // characters beside them, and a character past ASCII (which has no case
    // here). Whole characters only: the Roc's topics are text, its door
    // refuses bytes that are not UTF-8, and `roc test` covers that refusal.
    var rng = std.Random.DefaultPrng.init(0x70_91c);
    const r = rng.random();
    const topic_chars = [_][]const u8{ "a", "A", "b", "B", "z", "Z", "@", "[", "`", "{", "-", "0", "9", "\u{e9}", "\u{c9}" };
    var hits: usize = 0;
    for (0..4000) |_| {
        var topics: std.ArrayList([]const u8) = .empty;
        for (0..r.uintAtMost(usize, 4)) |_| try topics.append(a, try randomText(a, r, &topic_chars, 3));
        const sid = try randomText(a, r, &topic_chars, 3);
        const z = chat.hasTopic(topics.items, sid);
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, sid);
        try args.appendSlice(a, topics.items);
        const got = yes((try roc1(a, .has_topic, args.items)).?);
        compared += 1;
        if (z) hits += 1;
        if (z != got) differ.add("hasTopic(\"{f}\", {d} topics): zig {}, roc {}", .{ std.zig.fmtString(sid), topics.items.len, z, got });
    }
    try differ.none(compared);
    try testing.expect(hits > 300);
}

/// Up to `most` characters picked from `chars`, so the text is UTF-8
/// whenever every one of `chars` is.
fn randomText(a: std.mem.Allocator, r: std.Random, chars: []const []const u8, most: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..r.uintAtMost(usize, most)) |_| try out.appendSlice(a, chars[r.uintLessThan(usize, chars.len)]);
    return out.items;
}

// ── a member's channels (chat_paths.zig) ───────────────────────────────────

test "Paths: the channels a member is in, sorted by bytes, from every roster in any order" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0xc4a7);
    const r = rng.random();
    // Names that sort apart by byte (`Z` before `a`, a prefix first, bytes
    // past ASCII last), a name that is only ".channel" with its suffix cut
    // (""), names that are numbers as a count or a uid is (a roster read
    // out of step shows), and, picked with replacement, duplicates. No name
    // that is not UTF-8: a roster's name is text, from Files.list!'s door,
    // which skips such a name.
    const names = [_][]const u8{ "2", "10", "0", "ops", "op", "ops2", "Zed", "zed", "a", "a b", "general", "\xc3\xa9t\xc3\xa9", "", "quiet", "Ops" };
    // Uids that are prefixes of each other, so a match must be whole.
    const uids = [_][]const u8{ "1", "2", "3", "10", "11", "100" };
    var none: usize = 0;
    var several: usize = 0;
    for (0..4000) |k| {
        var rosters: std.ArrayList(chat_paths.Roster) = .empty;
        var flat: std.ArrayList([]const u8) = .empty;
        // The first few: no channels at all; then up to eight, members up
        // to five each (none too), a member now and then listed twice.
        const n: usize = if (k < 20) 0 else r.uintAtMost(usize, 8);
        for (0..n) |_| {
            const name = names[r.uintLessThan(usize, names.len)];
            var members: std.ArrayList([]const u8) = .empty;
            for (0..r.uintAtMost(usize, 5)) |_| try members.append(a, uids[r.uintLessThan(usize, uids.len)]);
            try rosters.append(a, .{ .name = name, .members = members.items });
            try flat.appendSlice(a, &.{ name, try std.fmt.allocPrint(a, "{d}", .{members.items.len}) });
            try flat.appendSlice(a, members.items);
        }
        const uid = uids[r.uintLessThan(usize, uids.len)];
        const z = try chat_paths.memberChannels(a, rosters.items, uid);
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, uid);
        try args.appendSlice(a, flat.items);
        const got = try roc(a, .member_channels, args.items);
        compared += 1;
        if (z.len == 0) none += 1;
        if (z.len > 1) several += 1;
        var same = z.len == got.len;
        if (same) for (z, got) |x, y| {
            if (!std.mem.eql(u8, x, y)) same = false;
        };
        if (!same) {
            var zs: std.ArrayList(u8) = .empty;
            for (z) |x| try zs.print(a, "\"{f}\" ", .{std.zig.fmtString(x)});
            var rs: std.ArrayList(u8) = .empty;
            for (got) |x| try rs.print(a, "\"{f}\" ", .{std.zig.fmtString(x)});
            differ.add("member_channels(uid {s}, {d} rosters): zig {s}, roc {s}", .{ uid, rosters.items.len, zs.items, rs.items });
        }
    }
    try differ.none(compared);
    // The generator reaches both: a member in none, a member in several.
    try testing.expect(none > 500);
    try testing.expect(several > 500);
}

// ── a conversation's topics, a channel's members, every roster: the Roc's
// files (Host.list!, Host.read!) against the Zig that reads them ──────────

/// A folder's entries as the host hands them to the Roc (chat_router
/// `list`: webbox.store.list's, in the disk's order), `kind, name` pairs.
fn listed(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try disk.list(io, a, path)) |e| try out.appendSlice(a, &.{ switch (e.kind) {
        .directory => "d",
        .file => "f",
        .other => "o",
    }, e.name });
    return out.items;
}

/// A file as the host reads it for the Roc (chat_router `read`:
/// webbox.store.readOrNull), `how, bytes`: `F` found, `M` missing, `X`
/// failed.
fn readFor(a: std.mem.Allocator, io: std.Io, path: []const u8) ![2][]const u8 {
    const got = disk.readOrNull(io, a, path, .unlimited) catch return .{ "X", "" };
    return if (got) |b| .{ "F", b } else .{ "M", "" };
}

fn sameLists(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

fn said(a: std.mem.Allocator, l: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (l) |x| try out.print(a, "\"{f}\" ", .{std.zig.fmtString(x)});
    return out.items;
}

test "Paths: a conversation's topics, as listTopics lists them, from generated folders: .md files and not, a folder named x.md, .md alone, links, bytes that sort high, and case" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var d: DiskRoot = undefined;
    try d.init(a);
    defer d.deinit();
    const io = d.threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0x70b1c);
    const r = rng.random();
    // Names are UTF-8 only: one that is not (`\xff.md`) is left out at the
    // Roc's door, Files.list!, and is no twin case (roc-webbox's
    // chat_hosted.zig and Files.roc's expects cover it).
    const names = [_][]const u8{ "Plans.md", "plans.md", "PLANS.md", "a.md", "B.md", "b.md", ".md", "x.md", "notes.txt", "md", "a.MD", "a.md.bak", "\xc3\xa9t\xc3\xa9.md", "ete.md", "Zed.md", "zed.md", "2026-10-25.md", "ChitChat.md", "general2.md", "Plans.reactions.jsonl", "Plans.count" };
    const conv_dir = try chat_paths.dmConvDir(a, "1_2");
    const sessions = try std.fs.path.join(a, &.{ conv_dir, "sessions" });
    var folders: usize = 0;
    var links: usize = 0;
    var several: usize = 0;
    for (0..1500) |k| {
        try std.Io.Dir.cwd().deleteTree(io, conv_dir);
        // One in thirty: no folder at all.
        if (k % 30 != 0) {
            try std.Io.Dir.cwd().createDirPath(io, sessions);
            var made: std.ArrayList([]const u8) = .empty;
            for (0..r.uintAtMost(usize, 9)) |_| {
                const name = names[r.uintLessThan(usize, names.len)];
                if (hasName(made.items, name)) continue;
                try made.append(a, name);
                const p = try std.fs.path.join(a, &.{ sessions, name });
                switch (r.uintLessThan(u8, 8)) {
                    0 => {
                        try std.Io.Dir.cwd().createDirPath(io, p);
                        if (std.mem.endsWith(u8, name, ".md")) folders += 1;
                    },
                    1 => {
                        try std.Io.Dir.cwd().symLink(io, "elsewhere", p, .{});
                        links += 1;
                    },
                    // Written as named: webbox's write would refuse a name
                    // FAT cannot hold, or write over one differing in case.
                    else => try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "" }),
                }
            }
        }
        const z = try chat_paths.listTopics(io, a, conv_dir);
        const got = try roc(a, .topics, try listed(a, io, sessions));
        compared += 1;
        if (z.len > 1) several += 1;
        if (!sameLists(z, got)) differ.add("topics: zig {s}, roc {s}", .{ try said(a, z), try said(a, got) });
    }
    try differ.none(compared);
    try testing.expect(folders > 100 and links > 100 and several > 500);
}

fn hasName(l: []const []const u8, x: []const u8) bool {
    for (l) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

test "Paths: a channel's members, as channelMembers reads its file, over generated files: comments, blank lines, CRLF, spaces and tabs around, a # after a uid, 007, +7, ../x, duplicates, empty" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var d: DiskRoot = undefined;
    try d.init(a);
    defer d.deinit();
    const io = d.threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0xc4a2e1);
    const r = rng.random();
    // Lines a member file may hold as meant, padded with what the trim
    // takes (spaces, tabs, CRs), and comments; and lines that make it
    // malformed: not canonical, a comment after a uid, a path, bytes the
    // trim does not take.
    const good = [_][]const u8{ "1", "2", "3", "10", "100", "# the team", "#", "#1 x", "", " ", "\t", "\r", "  1  ", "\t2\t", " 3\r", "\t\r 10 \t", "\t\t100" };
    const bad = [_][]const u8{ "007", "0", "+7", "-1", "../x", "../../x", "3 # Claude", "1 2", "abc", "\xe2\x98\x83", "1\x0b", "\x0b1", "1\x00", "2#", "1\n\x0c" };
    const file = try d.at(a, "channels/team.channel");
    var ok: usize = 0;
    var malformed: usize = 0;
    for (0..4000) |k| {
        var body: std.ArrayList(u8) = .empty;
        const n: usize = if (k % 50 == 0) 0 else r.uintAtMost(usize, 6);
        for (0..n) |i| {
            if (i > 0) try body.appendSlice(a, if (r.boolean()) "\n" else "\r\n");
            try body.appendSlice(a, if (r.uintLessThan(u8, 10) == 0) bad[r.uintLessThan(usize, bad.len)] else good[r.uintLessThan(usize, good.len)]);
        }
        if (r.boolean()) try body.append(a, '\n');
        try disk.write(io, a, file, body.items, .{});
        const z = chat_paths.channelMembers(io, a, "team");
        const got = try roc(a, .channel_members, &.{body.items});
        compared += 1;
        const r_bad = std.mem.eql(u8, got[0], "M");
        if (z) |members| {
            ok += 1;
            if (r_bad or !sameLists(members.?, got[1..])) differ.add("members of \"{f}\": zig {s}, roc {s}", .{ std.zig.fmtString(body.items), try said(a, members.?), try said(a, got) });
        } else |e| {
            try testing.expectEqual(error.MalformedChannel, e);
            malformed += 1;
            if (!r_bad) differ.add("members of \"{f}\": zig malformed, roc {s}", .{ std.zig.fmtString(body.items), try said(a, got) });
        }
    }
    try differ.none(compared);
    try testing.expect(ok > 1000 and malformed > 1000);
}

test "Paths: every channel's roster, as channelRosters reads them from generated channel folders: which entries count, the names, the order, a malformed one skipped and counted, one that will not read" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var d: DiskRoot = undefined;
    try d.init(a);
    defer d.deinit();
    const io = d.threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0x5057e5);
    const r = rng.random();
    // Entries that count and not: the suffix exact, `.channel` alone (""),
    // numeric names, bytes that sort high, a doubled suffix, near misses.
    // UTF-8 only: a name that is not (`\xff.channel`) is skipped and counted
    // at the Roc's door, Files.list!, and is no twin case (roc-webbox's
    // chat_hosted.zig covers it).
    const names = [_][]const u8{ "ops.channel", "Zed.channel", "zed.channel", ".channel", "7.channel", "10.channel", "\xc3\xa9t\xc3\xa9.channel", "a.channel.channel", "ops.channel.bak", "channel", "readme", "ops", "x.CHANNEL", "quiet.channel" };
    const files = [_][]const u8{ "1\n", "1\n2\n", "# team\n3\r\n", "", "2\n 1\t\n", "1\nnot a uid\n", "1\n1\n", "007\n", "3 # Claude\n" };
    const channels = try d.at(a, "channels");
    var failed: usize = 0;
    var counted: usize = 0;
    var listed_some: usize = 0;
    for (0..1500) |k| {
        try std.Io.Dir.cwd().deleteTree(io, channels);
        if (k % 30 != 0) {
            try std.Io.Dir.cwd().createDirPath(io, channels);
            var made: std.ArrayList([]const u8) = .empty;
            for (0..r.uintAtMost(usize, 7)) |_| {
                const name = names[r.uintLessThan(usize, names.len)];
                if (hasName(made.items, name)) continue;
                try made.append(a, name);
                const p = try std.fs.path.join(a, &.{ channels, name });
                // A folder now and then: it will not read.
                // A folder now and then: it will not read. A file written as
                // named (webbox's write refuses a name FAT cannot hold).
                if (r.uintLessThan(u8, 40) == 0) try std.Io.Dir.cwd().createDirPath(io, p) else try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = files[r.uintLessThan(usize, files.len)] });
            }
        }
        const before = chat_paths.malformed_channels;
        const z = chat_paths.channelRosters(io, a);
        const z_counted = chat_paths.malformed_channels - before;
        const z_last = try a.dupe(u8, chat_paths.malformed_last);
        // The Roc's way: the folder listed, the names it chose read as the
        // host reads them, its rosters and malformed ones; each malformed
        // one counted by the host's primitive.
        const chosen = try roc(a, .channel_names, try listed(a, io, channels));
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, try std.fmt.allocPrint(a, "{d}", .{chosen.len}));
        for (chosen) |n| try args.append(a, n);
        var r_failed = false;
        for (chosen) |n| {
            const read = try readFor(a, io, try d.at(a, try std.fmt.allocPrint(a, "channels/{s}.channel", .{n})));
            if (std.mem.eql(u8, read[0], "X")) r_failed = true;
            try args.appendSlice(a, &read);
        }
        const got = try roc(a, .rosters, args.items);
        const m = try std.fmt.parseInt(usize, got[0], 10);
        const before_r = chat_paths.malformed_channels;
        for (got[1 .. 1 + m]) |n| chat_paths.countMalformed(n);
        const r_counted = chat_paths.malformed_channels - before_r;
        compared += 1;
        counted += z_counted;
        if (z_counted != r_counted or (z_counted > 0 and !std.mem.eql(u8, z_last, chat_paths.malformed_last)))
            differ.add("malformed: zig {d} (last \"{f}\"), roc {d} (last \"{f}\")", .{ z_counted, std.zig.fmtString(z_last), r_counted, std.zig.fmtString(chat_paths.malformed_last) });
        if (z) |rosters| {
            if (rosters.len > 0) listed_some += 1;
            var flat: std.ArrayList([]const u8) = .empty;
            for (rosters) |ro| {
                try flat.appendSlice(a, &.{ ro.name, try std.fmt.allocPrint(a, "{d}", .{ro.members.len}) });
                try flat.appendSlice(a, ro.members);
            }
            if (r_failed or !sameLists(flat.items, got[1 + m ..])) differ.add("rosters: zig {s}, roc {s}", .{ try said(a, flat.items), try said(a, got) });
        } else |_| {
            failed += 1;
            if (!r_failed) differ.add("rosters: zig failed, roc {s}", .{try said(a, got)});
        }
    }
    try differ.none(compared);
    try testing.expect(failed > 30 and counted > 500 and listed_some > 500);
}

test "Paths: a conversation's topics folder, a channel's member file and a topic's sidecar are where the Zig has them" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    for ([_][3][]const u8{ .{ "1_2", "ops", "Plans" }, .{ "10_100", "Zed", "2026-10-25" }, .{ "1_1", "a-b", "general2" } }) |kns| {
        const got = try roc(a, .conv_paths, &kns);
        const at = struct {
            fn at(al: std.mem.Allocator, rel: []const u8) ![]u8 {
                return std.fs.path.join(al, &.{ chat_store.chat_root, rel });
            }
        }.at;
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, kns[0]), "sessions" }), try at(a, got[0]));
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ try chat_paths.channelConvDir(a, kns[1]), "sessions" }), try at(a, got[1]));
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", try std.fmt.allocPrint(a, "{s}.channel", .{kns[1]}) }), try at(a, got[2]));
        try testing.expectEqualStrings(try chat_store.reactionsPath(a, try chat_paths.dmConvDir(a, kns[0]), kns[2]), try at(a, got[3]));
    }
}

// ── who has an account: the Roc's lookups (chat/Accounts.roc) over what
// Host.list_accounts! hands it, against users.zig ────────────────────────────────

/// The accounts as the host hands them to the Roc (chat_router `accounts`:
/// users.listAccounts), `id, kind, name_read, name` each: the kind `a`,
/// `g`, `m` or `u` (its password's stat failed), the name read `f` or `u`
/// (it failed; the name then "").
fn accountArgs(a: std.mem.Allocator, all: []const users.Account) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |u| try out.appendSlice(a, &.{ u.id, switch (u.kind) {
        .agent => "a",
        .guest => "g",
        .member => "m",
        .unreadable => "u",
    }, switch (u.name) {
        .found => "f",
        .unreadable => "u",
    }, switch (u.name) {
        .found => |n| n,
        .unreadable => "",
    } });
    return out.items;
}

/// The error account `id`'s `which` read (`kind` or `name`) failed with,
/// as listAccounts kept it (what chat_router `failAccount` fails the
/// request with); null when it did not fail or there is no such account.
fn keptError(all: []const users.Account, which: []const u8, id: []const u8) ?anyerror {
    for (all) |u| {
        if (!std.mem.eql(u8, u.id, id)) continue;
        if (std.mem.eql(u8, which, "kind")) return if (u.kind == .unreadable) u.kind.unreadable else null;
        if (std.mem.eql(u8, which, "name")) return if (u.name == .unreadable) u.name.unreadable else null;
    }
    return null;
}

test "Accounts: whether an account exists, its name and the authorized roster, as principalExists, getUserName and listAuthorized read them from generated account trees: canonical and not, files where folders belong, passwords or none, the agent, names with CR LF, ids that sort by number, not bytes, and passwords and names that will not read, each failing exactly the lookups whose Zig failed, with its error" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = try users.tmpRoots(&tmp, a);
    defer saved.restore();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var rng = std.Random.DefaultPrng.init(0xacc075);
    const r = rng.random();
    // Folder names: canonical ids (the agent's 3 among them; 9 and 10, 99
    // and 100, sorting one way by number and the other by bytes; ids past
    // an i64, which count as 0, and the largest that is not), and names
    // that are no account (007, +7, 0, a word, the counter's file).
    const ids = [_][]const u8{ "1", "2", "3", "9", "10", "99", "100", "12", "9223372036854775807", "9223372036854775808", "99999999999999999999", "007", "+7", "0", "x", "next-id.txt" };
    const names = [_]?[]const u8{ null, "Ann", "Ann\r\n", "Bo\r", "  Cy  d \t", "", "Dee\n\n", "\r\nEve", "Fay\r\r\n", "\n", "H\x00i" };
    // Asked of both, besides every name above: an id with no folder, empty
    // ones, and the agent's.
    const asked_too = [_][]const u8{ "5", "", " ", "\t\r\n", "3" };
    var huge_ties: usize = 0;
    var guests: usize = 0;
    var agents_bare: usize = 0;
    var skipped: usize = 0;
    // How often each side of a failure was met: a name lookup and a roster
    // that failed, a roster that read past a guest's unreadable name, a
    // roster that failed on a kind.
    var name_failed: usize = 0;
    var roster_failed: usize = 0;
    var roster_on_kind: usize = 0;
    var roster_past_guest: usize = 0;
    for (0..1500) |k| {
        try std.Io.Dir.cwd().deleteTree(io, users.auth_root);
        // One in thirty: no account store at all.
        if (k % 30 != 0) {
            try std.Io.Dir.cwd().createDirPath(io, users.auth_root);
            var made: std.ArrayList([]const u8) = .empty;
            for (0..r.uintAtMost(usize, 9)) |_| {
                const id = ids[r.uintLessThan(usize, ids.len)];
                if (hasName(made.items, id)) continue;
                try made.append(a, id);
                const dir = try std.fs.path.join(a, &.{ users.auth_root, id });
                // A file where a folder belongs, now and then.
                if (r.uintLessThan(u8, 8) == 0) {
                    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir, .data = "1" });
                    continue;
                }
                try std.Io.Dir.cwd().createDirPath(io, dir);
                const password = try std.fs.path.join(a, &.{ dir, "password" });
                // A password whose stat fails (a link to itself), now and then.
                if (r.uintLessThan(u8, 12) == 0) try std.Io.Dir.cwd().symLink(io, "password", password, .{}) else if (r.boolean()) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = password, .data = "$2b$12$hash" }) else {
                    guests += 1;
                    if (std.mem.eql(u8, id, "3")) agents_bare += 1;
                }
                const name = try std.fs.path.join(a, &.{ dir, "name" });
                // A name that will not read (a folder), now and then.
                if (r.uintLessThan(u8, 10) == 0) try std.Io.Dir.cwd().createDirPath(io, name) else if (names[r.uintLessThan(usize, names.len)]) |n| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = n });
            }
            if (hasName(made.items, "9223372036854775808") and hasName(made.items, "99999999999999999999")) huge_ties += 1;
        }
        // The ids that can reach a lookup: canonical ones (a DM's halves pass
        // Paths.participant; the member's own is a session's, signed only for
        // a counter's id). A non-canonical one, blank included, never asks:
        // the door refuses undecodable text; roc test covers it.
        var queries: std.ArrayList([]const u8) = .empty;
        for (ids ++ asked_too) |id| {
            if (users.validUid(id)) try queries.append(a, id) else skipped += 1;
        }
        const held = try users.listAccounts(io, a);
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, try std.fmt.allocPrint(a, "{d}", .{queries.items.len}));
        try args.appendSlice(a, queries.items);
        try args.appendSlice(a, try accountArgs(a, held));
        const got = try roc(a, .accounts, args.items);
        compared += 1;
        // Each id: `exists, ok, name`, or `exists, name, <whose>` when the
        // Roc asks for the failure.
        for (queries.items, 0..) |id, i| {
            const r_exists = std.mem.eql(u8, got[3 * i], "1");
            const r_how = got[3 * i + 1];
            const r_what = got[3 * i + 2];
            // **PRINCIPALEXISTS LOOKED AT THE FOLDER ALONE**: it never fails
            // on what the listing found, and the Roc's never asks to.
            const z_exists = users.principalExists(io, a, id) catch |e| {
                differ.add("account \"{f}\": principalExists failed {t}, which the Roc's has_account cannot", .{ std.zig.fmtString(id), e });
                continue;
            };
            if (z_exists != r_exists) differ.add("account \"{f}\": zig exists {}, roc {}", .{ std.zig.fmtString(id), z_exists, r_exists });
            if (users.getUserName(io, a, id)) |z_name| {
                if (!std.mem.eql(u8, r_how, "ok") or !std.mem.eql(u8, z_name, r_what))
                    differ.add("account \"{f}\": zig name \"{f}\", roc {s} \"{f}\"", .{ std.zig.fmtString(id), std.zig.fmtString(z_name), r_how, std.zig.fmtString(r_what) });
            } else |e| {
                name_failed += 1;
                // The Roc asks for the request to fail on this account's
                // name, and the error the host kept for it is the Zig's.
                if (!std.mem.eql(u8, r_how, "name") or !std.mem.eql(u8, r_what, id) or !std.meta.eql(keptError(held, "name", id), @as(?anyerror, e)))
                    differ.add("account \"{f}\": zig name failed {t}, roc {s} \"{f}\" (kept {?t})", .{ std.zig.fmtString(id), e, r_how, std.zig.fmtString(r_what), keptError(held, r_how, r_what) });
            }
        }
        const r_roster = got[3 * queries.items.len ..];
        if (users.listAuthorized(io, a)) |authorized| {
            var flat: std.ArrayList([]const u8) = .empty;
            try flat.append(a, "ok");
            for (authorized) |u| try flat.appendSlice(a, &.{ u.id, u.name });
            if (!sameLists(flat.items, r_roster)) differ.add("authorized: zig {s}, roc {s}", .{ try said(a, flat.items), try said(a, r_roster) });
            for (held) |u| {
                if (u.kind == .guest and u.name == .unreadable) {
                    roster_past_guest += 1;
                    break;
                }
            }
        } else |e| {
            roster_failed += 1;
            // The Roc's roster fails on the account, and the read, whose
            // kept error is the one listAuthorized stopped at.
            if (r_roster.len != 2 or !std.meta.eql(keptError(held, r_roster[0], r_roster[1]), @as(?anyerror, e)))
                differ.add("authorized: zig failed {t}, roc {s}", .{ e, try said(a, r_roster) });
            if (r_roster.len == 2 and std.mem.eql(u8, r_roster[0], "kind")) roster_on_kind += 1;
        }
    }
    try differ.none(compared);
    try testing.expect(huge_ties > 30 and guests > 1000 and agents_bare > 30 and skipped > 0);
    try testing.expect(name_failed > 100 and roster_failed > 100 and roster_on_kind > 30 and roster_past_guest > 30);
    // **WHY ONLY CANONICAL IDS ARE COMPARED**: no other reaches a lookup.
    // A DM's other half and its partner come from a pair Paths.participant
    // passed (dm_other), which takes canonical halves only, so a 007 folder,
    // an account to principalExists, is never asked after.
    for (ids) |id| {
        if (users.validUid(id)) continue;
        for ([_][]const u8{ try std.mem.concat(a, u8, &.{ id, "_1" }), try std.mem.concat(a, u8, &.{ "1_", id }) }) |key| {
            for ([_][]const u8{ "1", id }) |me| try testing.expectEqual(@as(?[]u8, null), try roc1(a, .dm_other, &.{ key, me }));
        }
    }
}

// ── Fanout (chat_fanout.zig, recent_feed.zig, images_store.zig, code_store.zig)

/// The Roc's answers against the Zig's, in order, said once each.
fn sameEach(a: std.mem.Allocator, what: []const u8, args: []const []const u8, zig: []const []const u8, got: []const []u8, differ: *Differences) !void {
    _ = a;
    if (zig.len != got.len) return differ.add("{s}: zig {d} answers, roc {d}", .{ what, zig.len, got.len });
    for (zig, got, 0..) |z, r, i| if (!std.mem.eql(u8, z, r)) {
        differ.add("{s} [{d}] of {d} args (first \"{f}\"):\n  zig {f}\n  roc {f}", .{ what, i, args.len, std.zig.fmtString(if (args.len > 0) args[0] else ""), std.zig.fmtString(z), std.zig.fmtString(r) });
        return;
    };
}

test "Fanout: every bus key, the URLs, the notify and topic-added events, the Recent row, and the images and code entries and events, as the Zig's fan-out writes them, over generated keys, names, ids, stamps, tags and blocks that need escaping" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var differ: Differences = .{};
    var compared: usize = 0;
    const strings = try byteStrings(a);
    // Every field the fan-out takes is text (keys, ids, the author, stamp,
    // topic, tags, blocks and a Recent row's fields): the Roc takes them decoded.
    const texts = try utf8Only(a, strings);
    var rng = std.Random.DefaultPrng.init(0xfa2007);
    const r = rng.random();
    const pick = struct {
        fn f(rr: std.Random, ss: []const []const u8) []const u8 {
            return ss[rr.uintLessThan(usize, ss.len)];
        }
    }.f;
    // Keys and ids near each rule: a DM's `_`, a channel's none, ids with
    // no `_`, one at the start, several.
    const keys = [_][]const u8{ "1_2", "1_1", "ops", "general", "a_b_c", "_x", "", "caf\xc3\xa9", "\xe2\x98\x83", "q\"\\/" };
    const ids = [_][]const u8{ "Plans_1", "Plans_12", "_1", "x", "", "a_b_3", "general2_7", "q\"_\\1", "\xe2\x98\x83_2" };
    const convs = [_][]const u8{ "1_2", "1_1", "10_100", "ops", "general", "a-1-" };
    const topics = [_][]const u8{ "Plans", "ChitChat", "road-trip-2", "9", "2026-10-25" };
    var tags_seen: usize = 0;
    var blocks_seen: usize = 0;
    for (0..3000) |i| {
        const key = if (i % 3 == 0) pick(r, texts) else pick(r, &keys);
        const sid = pick(r, texts);
        const id = if (i % 3 == 0) pick(r, texts) else pick(r, &ids);
        const from = pick(r, texts);
        // A member is a canonical uid: the door refuses undecodable text;
        // roc test covers it.
        const uid = try std.fmt.allocPrint(a, "{d}", .{r.intRangeAtMost(u64, 1, std.math.maxInt(u64))});
        const at = pick(r, texts);
        compared += 1;

        // The five keys, and the URLs: convKeyBaseURL, the topic's page,
        // imagesSourceURL of the message.
        try sameEach(a, "keys", &.{uid}, &.{ try chat_fanout.notifyBusKey(a, uid), try chat_fanout.sidebarBusKey(a, uid), try chat_fanout.recentBusKey(a, uid), try chat_fanout.imagesBusKey(a, uid), try chat_fanout.codeBusKey(a, uid) }, try roc(a, .fanout_keys, &.{uid}), &differ);
        // The URLs, notify (a DM's text and a channel's) and topic-added take
        // a conversation's key and a topic id: the door refuses undecodable
        // text; roc test covers it.
        const conv = pick(r, &convs);
        const topic = pick(r, &topics);
        const conv_base = try chat_fanout.convKeyBaseURL(a, conv);
        const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ conv_base, topic });
        try sameEach(a, "urls", &.{ conv, topic, id }, &.{ conv_base, url, try images_store.imagesSourceURL(a, conv_base, id) }, try roc(a, .fanout_urls, &.{ conv, topic, id }), &differ);
        const base = try chat_fanout.convKeyBaseURL(a, key);
        const kind: chat_store.ConvKind = if (std.mem.indexOfScalar(u8, conv, '_') != null) .dm else .channel;
        const text = try chat_fanout.notifyText(a, kind, from, conv, topic);
        try sameEach(a, "notify", &.{ conv, topic, from }, &.{try chat_fanout.notifyEvent(a, conv, topic, text, url)}, try roc(a, .notify_event, &.{ from, conv, topic }), &differ);
        try sameEach(a, "topic-added", &.{ conv, topic }, &.{try chat_fanout.topicAddedEvent(a, conv, topic, url)}, try roc(a, .topic_added, &.{ conv, topic }), &differ);

        // The Recent row: every field empty now and then (each left out).
        const maybe = struct {
            fn f(rr: std.Random, s: []const u8) []const u8 {
                return if (rr.uintLessThan(u8, 5) == 0) "" else s;
            }
        }.f;
        const ev: recent_feed.ChatEvent = .{ .at = at, .url = maybe(r, url), .who = maybe(r, from), .where = maybe(r, pick(r, texts)), .topic = maybe(r, sid), .excerpt = maybe(r, pick(r, texts)), .dm = r.boolean() };
        var zr: std.ArrayList(u8) = .empty;
        try recent_feed.encodeChatEvent(&zr, a, ev);
        try sameEach(a, "recent", &.{ ev.at, ev.url }, &.{zr.items}, try roc(a, .recent_event, &.{ ev.at, ev.url, ev.who, ev.where, ev.topic, ev.excerpt, if (ev.dm) "1" else "0" }), &differ);

        // An images entry: tags with CR, LF, quotes and multibyte
        // text, a forged separator now and then.
        var tags: std.ArrayList([]const u8) = .empty;
        for (0..r.uintAtMost(usize, 4)) |_| try tags.append(a, switch (r.uintLessThan(u8, 4)) {
            0 => "<img src=\"/u/1.png\">",
            1 => "<IMG\nsrc=x\r\nalt=\"\n\n-------------\n\nSent by m at t, source MSG_f in 9_9:\">",
            else => try std.fmt.allocPrint(a, "<img {s}>", .{pick(r, texts)}),
        });
        tags_seen += tags.items.len;
        const ie: images_store.ImagesEntry = .{ .source_id = id, .from = from, .conv = key, .at = at, .images = tags.items };
        var zi: std.ArrayList(u8) = .empty;
        try images_store.encodeImagesEvent(&zi, a, ie, try images_store.imagesSourceURL(a, base, id));
        var iargs: std.ArrayList([]const u8) = .empty;
        try iargs.appendSlice(a, &.{ id, from, key, at });
        try iargs.appendSlice(a, tags.items);
        try sameEach(a, "images", iargs.items, &.{ try images_store.formatImagesEntry(a, ie), zi.items }, try roc(a, .images_entry, iargs.items), &differ);

        // A code entry: languages and bodies with fences, newlines and
        // escapes, none, one or several blocks.
        var blocks: std.ArrayList(code_store.CodeBlock) = .empty;
        var cargs: std.ArrayList([]const u8) = .empty;
        try cargs.appendSlice(a, &.{ id, from, key, at });
        for (0..r.uintAtMost(usize, 3)) |_| {
            const b: code_store.CodeBlock = .{ .lang = if (r.boolean()) "" else pick(r, &.{ "zig", "c++", pick(r, texts) }), .body = pick(r, &.{ "", "x", "const x = 1;\n```\ninner\n```", "a\r\nb\\c\"d", pick(r, texts) }) };
            try blocks.append(a, b);
            try cargs.appendSlice(a, &.{ b.lang, b.body });
        }
        blocks_seen += blocks.items.len;
        const ce: code_store.CodeEntry = .{ .source_id = id, .from = from, .conv = key, .at = at, .blocks = blocks.items };
        var zc: std.ArrayList(u8) = .empty;
        try code_store.encodeCodeEvent(&zc, a, ce, try images_store.imagesSourceURL(a, base, id));
        try sameEach(a, "code", cargs.items, &.{ try code_store.formatCodeEntry(a, ce), zc.items }, try roc(a, .code_entry, cargs.items), &differ);
    }
    try differ.none(compared);
    try testing.expect(tags_seen > 3000 and blocks_seen > 2000);
}

test "Fanout: recentWhere for every viewer, as the Zig reads the other member's name from generated account trees: a DM's (the DM with yourself too), a channel's, a name with CR LF, none, and one that will not read (\"\")" {
    var arena = setUp();
    defer arena.deinit();
    defer twin.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = try users.tmpRoots(&tmp, a);
    defer saved.restore();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var differ: Differences = .{};
    var compared: usize = 0;
    var unreadable: usize = 0;
    var rng = std.Random.DefaultPrng.init(0x4e7e);
    const r = rng.random();
    const names = [_]?[]const u8{ null, "Ann", "Bo\r\n", "", "q\"\\" };
    for (0..400) |_| {
        try std.Io.Dir.cwd().deleteTree(io, users.auth_root);
        try std.Io.Dir.cwd().createDirPath(io, users.auth_root);
        for ([_][]const u8{ "1", "2", "3" }) |id| {
            const dir = try std.fs.path.join(a, &.{ users.auth_root, id });
            try std.Io.Dir.cwd().createDirPath(io, dir);
            if (r.boolean()) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "password" }), .data = "$2b$12$hash" });
            const name = try std.fs.path.join(a, &.{ dir, "name" });
            // A name that will not read (a folder), now and then.
            if (r.uintLessThan(u8, 4) == 0) try std.Io.Dir.cwd().createDirPath(io, name) else if (names[r.uintLessThan(usize, names.len)]) |n| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = n });
        }
        const held = try users.listAccounts(io, a);
        for ([_]struct { []const u8, ConvMeta }{
            .{ "1_2", .{ .kind = .dm, .members = &.{ "1", "2" } } },
            .{ "2_3", .{ .kind = .dm, .members = &.{ "2", "3" } } },
            .{ "1_1", .{ .kind = .dm, .members = &.{"1"} } },
            .{ "ops", .{ .kind = .channel, .members = &.{ "1", "2", "3" } } },
        }) |c| for (c[1].members) |viewer| {
            const z = chat_fanout.recentWhere(io, a, c[1], c[0], viewer) catch blk: {
                unreadable += 1;
                break :blk "";
            };
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, &.{ if (c[1].kind == .dm) "d" else "c", viewer, c[0], try std.fmt.allocPrint(a, "{d}", .{c[1].members.len}) });
            try args.appendSlice(a, c[1].members);
            try args.appendSlice(a, try accountArgs(a, held));
            compared += 1;
            try sameEach(a, "recentWhere", &.{ c[0], viewer }, &.{z}, try roc(a, .recent_where, args.items), &differ);
        };
    }
    try differ.none(compared);
    try testing.expect(unreadable > 50);
}

/// `s` when it is UTF-8, else `other`: a generator's bytes made text, for a
/// Roc that takes them decoded.
fn textOr(s: []const u8, other: []const u8) []const u8 {
    return if (std.unicode.utf8ValidateSlice(s)) s else other;
}
