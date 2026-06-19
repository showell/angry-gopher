//! chat_store: the READ half of Go's chat storage layer (server/chat/
//! chat_store.go + chat_conv.go + channels.go), enough to render a transcript
//! off disk. The zig port shares Go's LIVE chat tree (chat_root = {data_dir}/
//! chat, wired by config.zig) — Go writes messages, this reads the SAME bytes
//! back. There is NO write path here: posting still goes through the Go server
//! (the dogfood loop — route a message through Go, read it back through zig).
//!
//! On-disk shape (mirrors Go exactly):
//!   {chat_root}/<a>_<b>/sessions/<sid>.md              — a 1:1 DM transcript
//!   {chat_root}/channels/<name>/sessions/<sid>.md      — a channel topic
//!   {chat_root}/channels/<name>.channel                — channel member uids
//!
//! Transcript file format: messages concatenated, joined by `sep`. Each block is
//!   MSG_<sid>_<n>\nfrom: <name>\ndate: <RFC3339>\n\n<markdown body>
//! decodeChatFile is the byte-exact port of Go's decodeChatFile/decodeChatBlock,
//! including the 13-hyphen separator-collision unescape. Round-trips with the
//! raw bytes (the /raw view serves them verbatim, this decoder parses them).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const timefmt = @import("timefmt.zig");
const bus_mod = @import("bus.zig");
const Bus = bus_mod.Bus;
const users = @import("users.zig");
const recent_feed = @import("recent_feed.zig");
const images_store = @import("images_store.zig");
const code_store = @import("code_store.zig");

/// chat_root mirrors Go's ChatDataRoot ({data_dir}/chat). config.zig overrides
/// this at startup; the default is repo-relative-from-zig-server like the others.
pub var chat_root: []const u8 = "../games/lynrummy/chat-data";

/// chat_mu serializes the read-count-then-append on the write path AND the
/// read-backlog-then-subscribe on the stream path — mirroring Go's chatMu. It's
/// what makes a message land in EITHER the backlog OR the live stream, never
/// both and never neither (see appendMessage / openStream). Process-local, like
/// Go's; the cross-process race with the Go server is the same one Go has.
var chat_mu: Io.Mutex = .init;

/// sep joins message blocks on disk: blank line, 13 hyphens, newline. A body
/// line that would collide with it is backslash-escaped (see unescapeBodyLine).
pub const sep = "\n\n-------------\n";
const dashes = "-------------"; // exactly 13; the collision shape

/// ChatMessage is one decoded block. id/from/date are slices into the source
/// buffer; markdown is freshly built (line-unescaped + rejoined). The `date` is
/// the raw RFC3339 header string (Go reparses it to a time.Time and reformats on
/// the wire; for a read-only view the stored string is what we display).
pub const ChatMessage = struct {
    id: []const u8,
    from: []const u8,
    date: []const u8,
    markdown: []const u8,
};

// ── decode (byte-exact port of Go's decodeChatFile/decodeChatBlock) ──────────

/// decodeChatFile parses a whole session file into messages. Splits on `sep`
/// (no trailing separator on disk, so one piece per message), skipping any
/// all-whitespace piece. Mirrors Go's decodeChatFile.
pub fn decodeChatFile(alloc: Alloc, data: []const u8) ![]ChatMessage {
    var out: std.ArrayList(ChatMessage) = .empty;
    var it = std.mem.splitSequence(u8, data, sep);
    while (it.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t\r\n").len == 0) continue;
        try out.append(alloc, try decodeChatBlock(alloc, piece));
    }
    return out.toOwnedSlice(alloc);
}

/// decodeChatBlock parses one block: a `MSG_` id line, `key: value` header lines
/// until a blank line, then the verbatim (line-unescaped) markdown body. Mirrors
/// Go's decodeChatBlock — including that a header line without ": " is ignored
/// and a missing blank line yields an empty body.
fn decodeChatBlock(alloc: Alloc, piece: []const u8) !ChatMessage {
    var lines: std.ArrayList([]const u8) = .empty;
    var lit = std.mem.splitScalar(u8, piece, '\n');
    while (lit.next()) |ln| try lines.append(alloc, ln);
    const ls = lines.items;

    var msg: ChatMessage = .{ .id = "", .from = "", .date = "", .markdown = "" };
    var i: usize = 0;
    if (i < ls.len and std.mem.startsWith(u8, ls[i], "MSG_")) {
        msg.id = ls[i]["MSG_".len..];
        i += 1;
    }
    while (i < ls.len) : (i += 1) {
        if (ls[i].len == 0) break; // blank line ends the header
        if (cutSeq(ls[i], ": ")) |kv| {
            if (std.mem.eql(u8, kv.before, "from")) {
                msg.from = kv.after;
            } else if (std.mem.eql(u8, kv.before, "date")) {
                msg.date = kv.after;
            }
        }
    }

    // body = lines[i+1..] (everything after the blank), each line unescaped.
    var body: std.ArrayList(u8) = .empty;
    var j = i + 1;
    var first = true;
    while (j < ls.len) : (j += 1) {
        if (!first) try body.append(alloc, '\n');
        first = false;
        try body.appendSlice(alloc, unescapeBodyLine(ls[j]));
    }
    msg.markdown = try body.toOwnedSlice(alloc);
    return msg;
}

/// unescapeBodyLine reverses Go's escapeBodyLine: a line that is one-or-more
/// backslashes followed by exactly 13 hyphens (the `^\\+-------------$` shape)
/// loses one leading backslash. Everything else passes through. Mirrors Go.
fn unescapeBodyLine(line: []const u8) []const u8 {
    var k: usize = 0;
    while (k < line.len and line[k] == '\\') k += 1;
    if (k >= 1 and std.mem.eql(u8, line[k..], dashes)) return line[1..];
    return line;
}

// ── write path + live fan-out (port of chat_conv.go AppendMessage) ───────────

/// Stream is the result of openStream: the decoded backlog + a live Subscriber.
/// The caller replays backlog[since..] then drains the subscriber, and MUST pair
/// this with `bus.close(sub)` when the connection ends.
pub const Stream = struct {
    backlog: []ChatMessage,
    sub: *bus_mod.Subscriber,
};

/// openStream is Go's Conv.OpenStream: under chat_mu, decode the session backlog
/// AND register a live subscriber on `<conv_key>/<sid>` — atomically, so no
/// message slips between "what's in the backlog" and "what the subscriber sees".
/// A message appended concurrently is delivered exactly once (backlog xor live).
pub fn openStream(io: Io, alloc: Alloc, bus: *Bus, conv_dir: []const u8, conv_key: []const u8, sid: []const u8) !Stream {
    const path = try sessionMdPath(alloc, conv_dir, sid);
    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });

    chat_mu.lockUncancelable(io);
    defer chat_mu.unlock(io);

    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
    const msgs = try decodeChatFile(alloc, raw);
    const sub = try bus.open(key);
    return .{ .backlog = msgs, .sub = sub };
}

/// appendMessage stores one message (Go's Conv.AppendMessage, write half): under
/// chat_mu, read the current count → the message index, encode the on-disk block
/// (with separator + body-line escaping), append it, write the .lastauthor
/// companion, then publish a fan-out blob to the live subscribers — all under the
/// one lock so a concurrent openStream can't double- or zero-count it. Returns
/// the stored message (id + server-stamped date). NO render here: the blob
/// carries raw markdown; each stream renders per-viewer (matching Go).
pub fn appendMessage(io: Io, alloc: Alloc, bus: *Bus, meta: ConvMeta, conv_dir: []const u8, conv_key: []const u8, sid: []const u8, from_name: []const u8, from_id: []const u8, markdown: []const u8, cid: []const u8) !ChatMessage {
    const path = try sessionMdPath(alloc, conv_dir, sid);

    chat_mu.lockUncancelable(io);
    defer chat_mu.unlock(io);

    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
    const existing = try decodeChatFile(alloc, raw);
    const index = existing.len;

    const id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ sid, index + 1 });
    const at = try timefmt.formatRFC3339UTC(alloc, nowUnix(io));
    const msg = ChatMessage{ .id = id, .from = from_name, .date = at, .markdown = markdown };

    const stored = try chatStoredForm(alloc, index, msg);
    try appendRawBytes(io, path, stored);

    // Last-author companion (best-effort, like Go).
    const la = try std.fs.path.join(alloc, &.{ conv_dir, "sessions", try std.fmt.allocPrint(alloc, "{s}.lastauthor", .{sid}) });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = la, .data = from_id }) catch {};

    // Fan out to live subscribers on this conv/sid (best-effort).
    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conv_key, sid });
    const blob = try busBlob(alloc, index, from_name, at, id, cid, markdown);
    bus.publish(key, blob);

    // Cross-page fanout (Go's fanoutMessage): recent + images, per member, to
    // their per-uid bus. Best-effort; runs under chat_mu so the lock order is
    // chat_mu → imagesMu (leaf), matching Go. notify / topic-added stay stubs.
    fanoutCrossPage(io, alloc, bus, meta, conv_key, sid, msg);

    return msg;
}

/// ConvKind discriminates the two conversation shapes for the fanout (DM "where"
/// names the other party; channel "where" names the channel).
pub const ConvKind = enum { dm, channel };

/// ConvMeta carries what the cross-page fanout needs that the storage path
/// doesn't otherwise know: the conv kind and its member uids (recipients).
pub const ConvMeta = struct { kind: ConvKind, members: []const []const u8 };

/// recentBusKey / imagesBusKey are the per-uid bus keys for the cross-page
/// streams. Namespaced so they can't collide with the per-conv "<key>/<sid>"
/// stream keys. Builder lives here (the publisher) so the stream handlers
/// subscribe with the SAME function — no string drift.
pub fn recentBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "rec:{s}", .{uid});
}
pub fn imagesBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "img:{s}", .{uid});
}
pub fn codeBusKey(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "code:{s}", .{uid});
}

/// convKeyBaseURL returns the URL root for a conv addressed by its storage key.
/// DM keys contain '_' (channel names exclude it), a sufficient discriminator.
/// Mirrors Go's convKeyBaseURL.
pub fn convKeyBaseURL(alloc: Alloc, conv_key: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, conv_key, '_') != null) {
        return std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv_key});
    }
    return std.fmt.allocPrint(alloc, "/channel/{s}", .{conv_key});
}

/// fanoutCrossPage publishes one new message to every member's recent + images
/// feeds (Go's publishRecentForConv + publishImagesForConv). Best-effort: a
/// failure for one member/surface is swallowed so it never blocks the write.
fn fanoutCrossPage(io: Io, alloc: Alloc, bus: *Bus, meta: ConvMeta, conv_key: []const u8, sid: []const u8, msg: ChatMessage) void {
    const base = convKeyBaseURL(alloc, conv_key) catch return;
    const rec_url = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid }) catch return;
    const excerpt = recent_feed.recentExcerpt(alloc, msg.markdown) catch "";
    const tags = images_store.extractImageTags(alloc, msg.markdown) catch &.{};
    const blocks = code_store.extractCodeBlocks(alloc, msg.markdown) catch &.{};
    const src_url = images_store.imagesSourceURL(alloc, base, msg.id) catch base;

    for (meta.members) |uid| {
        // recent — every member sees the row (sender included, like Go).
        const where = recentWhere(io, alloc, meta, conv_key, uid) catch "";
        var rj: std.ArrayList(u8) = .empty;
        recent_feed.encodeChatEvent(&rj, alloc, msg.date, rec_url, sid, where, msg.from, excerpt) catch continue;
        if (recentBusKey(alloc, uid)) |k| bus.publish(k, rj.items) else |_| {}

        // images — only when the message carried <img> tags.
        if (tags.len > 0) {
            const e = images_store.ImagesEntry{
                .source_id = msg.id,
                .from = msg.from,
                .conv = conv_key,
                .at = msg.date,
                .images = tags,
            };
            images_store.appendImagesEntry(io, alloc, uid, e) catch continue;
            var ij: std.ArrayList(u8) = .empty;
            images_store.encodeImagesEvent(&ij, alloc, e, src_url) catch continue;
            if (imagesBusKey(alloc, uid)) |k| bus.publish(k, ij.items) else |_| {}
        }

        // code — only when the message carried fenced code blocks.
        if (blocks.len > 0) {
            const e = code_store.CodeEntry{
                .source_id = msg.id,
                .from = msg.from,
                .conv = conv_key,
                .at = msg.date,
                .blocks = blocks,
            };
            code_store.appendCodeEntry(io, alloc, uid, e) catch continue;
            var cj: std.ArrayList(u8) = .empty;
            code_store.encodeCodeEvent(&cj, alloc, e, src_url) catch continue;
            if (codeBusKey(alloc, uid)) |k| bus.publish(k, cj.items) else |_| {}
        }
    }
}

/// recentWhere is the per-recipient muted-context label: a channel names itself
/// ("in <name>"); a DM names the OTHER party ("with <name>"). Mirrors Go's
/// Conv.recentWhereFor.
fn recentWhere(io: Io, alloc: Alloc, meta: ConvMeta, conv_key: []const u8, viewer: []const u8) ![]const u8 {
    if (meta.kind == .channel) return std.fmt.allocPrint(alloc, "in {s}", .{conv_key});
    var other: []const u8 = "";
    for (meta.members) |m| {
        if (!std.mem.eql(u8, m, viewer)) other = m;
    }
    const name = try users.getUserName(io, alloc, other);
    return std.fmt.allocPrint(alloc, "with {s}", .{name});
}

/// busBlob is the internal fan-out payload — every field a stream needs to build
/// its per-viewer wire event EXCEPT `mine` (viewer-relative) and `html` (rendered
/// per-stream from `markdown`). JSON for robustness over arbitrary markdown bytes.
fn busBlob(alloc: Alloc, index: usize, from: []const u8, at: []const u8, id: []const u8, cid: []const u8, markdown: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"index\":{d},\"from\":{f},\"at\":{f},\"id\":{f},\"cid\":{f},\"markdown\":{f}}}", .{
        index,
        std.json.fmt(from, .{}),
        std.json.fmt(at, .{}),
        std.json.fmt(id, .{}),
        std.json.fmt(cid, .{}),
        std.json.fmt(markdown, .{}),
    });
}

/// chatStoredForm is exactly what message `index` contributes to the file: its
/// block, preceded by `sep` for every message after the first. Mirrors Go's.
fn chatStoredForm(alloc: Alloc, index: usize, msg: ChatMessage) ![]u8 {
    const block = try encodeChatBlock(alloc, msg);
    if (index == 0) return block;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ sep, block });
}

/// encodeChatBlock renders one message to its on-disk block: the MSG_ id line,
/// the from/date header, a blank line, then the body with each line escaped
/// against a separator collision. Mirrors Go's encodeChatBlock.
fn encodeChatBlock(alloc: Alloc, msg: ChatMessage) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, msg.markdown, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try body.append(alloc, '\n');
        first = false;
        try body.appendSlice(alloc, try escapeBodyLine(alloc, line));
    }
    return std.fmt.allocPrint(alloc, "MSG_{s}\nfrom: {s}\ndate: {s}\n\n{s}", .{ msg.id, msg.from, msg.date, body.items });
}

/// escapeBodyLine protects a body line that would collide with `sep` by
/// prepending a backslash — Go's escapeBodyLine, matching `^\\*-------------$`
/// (ZERO or more backslashes then exactly 13 hyphens). Symmetric with
/// unescapeBodyLine.
fn escapeBodyLine(alloc: Alloc, line: []const u8) ![]const u8 {
    var k: usize = 0;
    while (k < line.len and line[k] == '\\') k += 1;
    if (std.mem.eql(u8, line[k..], dashes)) return std.fmt.allocPrint(alloc, "\\{s}", .{line});
    return line;
}

/// appendRawBytes appends `bytes` verbatim at the current end of `path` (creating
/// parents). Unlike appendTextLine it adds no newline — chatStoredForm is already
/// the exact bytes. Single positional write at EOF; see the top-of-file atomicity
/// note (chat_mu serializes this process; the file is only ever appended).
fn appendRawBytes(io: Io, path: []const u8, bytes: []const u8) !void {
    try mkParentDirs(io, path);
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
}

/// mkParentDirs creates the directory containing `path` (mkdir -p). No-op when
/// `path` has no directory component.
fn mkParentDirs(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| {
        try Io.Dir.cwd().createDirPath(io, d);
    }
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

const Cut = struct { before: []const u8, after: []const u8 };

/// cutSeq splits `s` at the first `needle`, returning the parts, or null when
/// absent. Mirrors the `found` arm of Go's strings.Cut.
fn cutSeq(s: []const u8, needle: []const u8) ?Cut {
    const idx = std.mem.indexOf(u8, s, needle) orelse return null;
    return .{ .before = s[0..idx], .after = s[idx + needle.len ..] };
}

// ── conversation paths + access (port of chat_conv.go / channels.go) ─────────

/// dmConvDir is {chat_root}/<conv>. `conv` is the already-canonical pair key
/// (e.g. "1_2"); callers gate it through chatKeyParticipant first.
pub fn dmConvDir(alloc: Alloc, conv: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ chat_root, conv });
}

/// channelConvDir is {chat_root}/channels/<name>.
pub fn channelConvDir(alloc: Alloc, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ chat_root, "channels", name });
}

/// sessionMdPath is {conv_dir}/sessions/<sid>.md. Mirrors Conv.SessionPath.
pub fn sessionMdPath(alloc: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.md", .{sid});
    return std.fs.path.join(alloc, &.{ conv_dir, "sessions", file });
}

/// rawSession reads a session's literal on-disk transcript bytes, or null when
/// the file is missing/unreadable. Mirrors Conv.RawSession (callers 404 on
/// null without distinguishing absent from unreadable). The /raw view serves
/// these bytes verbatim.
pub fn rawSession(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) !?[]u8 {
    const path = try sessionMdPath(alloc, conv_dir, sid);
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
}

/// listSessions returns the session ids (the `.md` basenames) under
/// {conv_dir}/sessions, sorted ascending. Missing dir → empty. Mirrors
/// Conv.ListSessions (dirs like `<sid>.uploads` are skipped).
pub fn listSessions(io: Io, alloc: Alloc, conv_dir: []const u8) ![][]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ conv_dir, "sessions" });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const sid = entry.name[0 .. entry.name.len - ".md".len];
        try out.append(alloc, try alloc.dupe(u8, sid));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

/// defaultSession prefers "ChitChat" when present, else the alphabetically-first
/// session, else "" (empty conv). Mirrors Conv.PreferredDefaultSession.
pub fn defaultSession(io: Io, alloc: Alloc, conv_dir: []const u8) ![]const u8 {
    const sessions = try listSessions(io, alloc, conv_dir);
    for (sessions) |s| {
        if (std.mem.eql(u8, s, "ChitChat")) return s;
    }
    if (sessions.len > 0) return sessions[0];
    return "";
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── channels (port of channels.go) ───────────────────────────────────────────

/// channelMembers reads {chat_root}/channels/<name>.channel: one uid per line,
/// blank/`#`-comment lines skipped. Missing file → null (the channel does not
/// exist). Mirrors readChannelMembers; existence of the file IS the channel.
pub fn channelMembers(io: Io, alloc: Alloc, name: []const u8) !?[][]const u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.channel", .{name});
    const path = try std.fs.path.join(alloc, &.{ chat_root, "channels", file });
    const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
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

/// listUserChannels returns the names of channels `uid` is a member of, sorted.
/// Scans {chat_root}/channels/*.channel. Missing dir → empty. Mirrors Go's
/// ListUserChannels (used by the sidebar's conversations rail).
pub fn listUserChannels(io: Io, alloc: Alloc, uid: []const u8) ![][]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ chat_root, "channels" });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".channel")) continue;
        const name = entry.name[0 .. entry.name.len - ".channel".len];
        const members = (try channelMembers(io, alloc, name)) orelse continue;
        if (!hasMember(members, uid)) continue;
        try out.append(alloc, try alloc.dupe(u8, name));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

// ── validators / access (port of chat_store.go) ──────────────────────────────

/// chatKeyParticipant reports whether `user` participates in DM key `key`
/// ("<a>_<b>"). The key must be canonical (smaller numeric id first) — a
/// non-canonical or malformed key is rejected. Mirrors ChatKeyParticipant.
pub fn chatKeyParticipant(alloc: Alloc, key: []const u8, user: []const u8) !bool {
    const cut = cutSeq(key, "_") orelse return false;
    const x = cut.before;
    const y = cut.after;
    if (x.len == 0 or y.len == 0) return false;
    if (std.mem.indexOfScalar(u8, y, '_') != null) return false; // exactly one '_'
    const canon = try chatPairKey(alloc, x, y);
    if (!std.mem.eql(u8, canon, key)) return false;
    return std.mem.eql(u8, user, x) or std.mem.eql(u8, user, y);
}

/// chatPairKey is the canonical DM key: the smaller numeric id first, joined by
/// '_'. Mirrors chatPairKey (atoiOr0 on each side).
pub fn chatPairKey(alloc: Alloc, a: []const u8, b: []const u8) ![]u8 {
    return if (atoiOr0(a) <= atoiOr0(b))
        std.fmt.allocPrint(alloc, "{s}_{s}", .{ a, b })
    else
        std.fmt.allocPrint(alloc, "{s}_{s}", .{ b, a });
}

fn atoiOr0(s: []const u8) i64 {
    return std.fmt.parseInt(i64, s, 10) catch 0;
}

/// validSessionID matches Go's chatSessionIDRe: `^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$`
/// in 1..80 chars — alphanumerics joined by single hyphens, no leading/trailing/
/// double hyphen, no underscore/dot/slash. Doubles as the path-traversal guard
/// for any sid that flows into a sessions/<sid> filesystem path.
pub fn validSessionID(sid: []const u8) bool {
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

/// validChannelName matches Go's channel-name rule: `^[A-Za-z][A-Za-z0-9-]{0,39}$`
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
