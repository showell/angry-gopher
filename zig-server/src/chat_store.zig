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

/// chat_root mirrors Go's ChatDataRoot ({data_dir}/chat). config.zig overrides
/// this at startup; the default is repo-relative-from-zig-server like the others.
pub var chat_root: []const u8 = "../games/lynrummy/chat-data";

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
fn chatPairKey(alloc: Alloc, a: []const u8, b: []const u8) ![]u8 {
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
