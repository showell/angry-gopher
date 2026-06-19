//! recent: /chat/recent — a flat reverse-chronological feed of activity across
//! the signed-in user's chat sessions (DMs + channels) and personal docs. Go's
//! server/chat/recent.go. The initial-load source is file mtime: on every GET
//! the server walks the convs the viewer participates in plus their docs dir,
//! stats each session/doc file, and ships the rows newest-first as inline JSON
//! (the same recentEvent shape the live stream would push, so recent.js uses one
//! row builder for both paint and upsert).
//!
//! Live stream parity gap (honest, documented): Go's /chat/recent/stream pushes
//! one event per write via a per-uid recentBus that Conv.AppendMessage →
//! fanoutMessage feeds (alongside notify/images/code). That cross-page fanout
//! isn't wired into the zig appendMessage yet — it's the shared extension the
//! Images/Code surfaces also need, to be built with them. So here the stream is
//! a keepalive-only stub: the page paints correctly and re-humanizes the "When"
//! column on its own 20s timer, but a new message/doc shows up on RELOAD, not
//! live. recent.js reacts only to real onmessage events, so an idle stream is
//! the correct "nothing happening" (same pattern as the notify/sidebar stubs).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const docs_store = @import("docs_store.zig");
const chat = @import("chat.zig");
const timefmt = @import("timefmt.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// recentExcerptCap bounds an excerpt's length on the wire (in codepoints). The
/// client visually clamps the cell to three lines; this just keeps a long
/// message from bloating the feed JSON. Mirrors Go's recentExcerptCap.
const recent_excerpt_cap = 280;

const Kind = enum { chat, doc };

/// RecentItem is one row before JSON encoding. `at_ns` (file mtime) is the sort
/// key; `at` is its RFC3339 rendering for the wire. Chat-only fields are
/// pre-resolved per viewer exactly like Go's publishRecentForConv, so DM and
/// channel rows are shaped identically.
const RecentItem = struct {
    kind: Kind,
    at_ns: i96,
    at: []const u8,
    // chat-only
    url: []const u8 = "",
    where: []const u8 = "",
    topic: []const u8 = "",
    last_author: []const u8 = "",
    excerpt: []const u8 = "",
    // doc-only
    slug: []const u8 = "",
    title: []const u8 = "",
};

/// handle dispatches /chat/recent* — `rest` is the path after "/recent" (keeps
/// its leading '/', empty for "/chat/recent"). Go: the page is the exact path,
/// plus /chat/recent/stream; anything else 404s.
pub fn handle(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const tail = restTail(req);
    if (tail.len == 0) return renderRecentPage(req, io, alloc, uid);
    if (std.mem.eql(u8, tail, "/stream")) return chat.keepaliveStream(req, io);
    return http.notFound(req);
}

/// restTail returns the path after "/chat/recent" (so "" or "/stream"), stripping
/// the query. The router only reaches here for /chat/recent[/...].
fn restTail(req: *Request) []const u8 {
    var p = req.head.target;
    if (std.mem.indexOfScalar(u8, p, '?')) |q| p = p[0..q];
    const prefix = "/chat/recent";
    if (!std.mem.startsWith(u8, p, prefix)) return p;
    return p[prefix.len..];
}

fn renderRecentPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    const items = try gatherRecentItems(io, alloc, uid);

    var b: std.ArrayList(u8) = .empty;
    try chat.writeChrome(&b, alloc, "Recent", "Recent", viewer, "recent");
    // Cross-page attention strip + favicon alert on incoming pings (notify.js
    // no-ops when #chat-notify is absent). Recent users camp here, so the tab
    // needs to alert too.
    try b.appendSlice(alloc, "<div class=\"chat-notify\" id=\"chat-notify\"></div>");
    try b.appendSlice(alloc, "<div id=\"recent-mount\"></div>");
    try emitRecentData(&b, alloc, items);
    try b.print(alloc, "<script src=\"/chat/recent.js?v={s}\"></script>" ++
        "<script src=\"/chat/notify.js?v={s}\"></script>", .{ chat.asset_v, chat.asset_v });
    try b.appendSlice(alloc, "</div></body></html>"); // close .app-body-wrap (PageFooter)

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// emitRecentData ships the initial feed as inline JSON next to the mount slot.
/// The `</`→`<\/` pass prevents the JSON from closing the surrounding <script>.
/// Mirrors Go's emitRecentData (one shape for first-paint + live upserts).
fn emitRecentData(b: *std.ArrayList(u8), alloc: Alloc, items: []RecentItem) !void {
    var j: std.ArrayList(u8) = .empty;
    try j.append(alloc, '[');
    for (items, 0..) |it, i| {
        if (i != 0) try j.append(alloc, ',');
        try encodeEvent(&j, alloc, it);
    }
    try j.append(alloc, ']');
    const safe = try replaceSeq(alloc, j.items, "</", "<\\/");
    try b.appendSlice(alloc, "<script id=\"recent-data\" type=\"application/json\">");
    try b.appendSlice(alloc, safe);
    try b.appendSlice(alloc, "</script>");
}

/// encodeEvent writes one recentEvent JSON object. Empty string fields are
/// omitted (Go's `omitempty`), so the client's `if(evt.last_author)` /
/// `if(evt.where)` / `if(evt.excerpt)` branches stay correct.
fn encodeEvent(j: *std.ArrayList(u8), alloc: Alloc, it: RecentItem) !void {
    try j.append(alloc, '{');
    switch (it.kind) {
        .chat => {
            try j.print(alloc, "\"kind\":\"chat\",\"at\":{f}", .{std.json.fmt(it.at, .{})});
            try appendField(j, alloc, "url", it.url);
            try appendField(j, alloc, "topic", it.topic);
            try appendField(j, alloc, "where", it.where);
            try appendField(j, alloc, "last_author", it.last_author);
            try appendField(j, alloc, "excerpt", it.excerpt);
        },
        .doc => {
            try j.print(alloc, "\"kind\":\"doc\",\"at\":{f}", .{std.json.fmt(it.at, .{})});
            try appendField(j, alloc, "slug", it.slug);
            try appendField(j, alloc, "title", it.title);
        },
    }
    try j.append(alloc, '}');
}

fn appendField(j: *std.ArrayList(u8), alloc: Alloc, name: []const u8, val: []const u8) !void {
    if (val.len == 0) return; // omitempty
    try j.print(alloc, ",\"{s}\":{f}", .{ name, std.json.fmt(val, .{}) });
}

// ── gather (Go's gatherRecentItems) ───────────────────────────────────────────

/// gatherRecentItems walks every conv that includes the viewer — DMs (every
/// other authorized principal) AND the channels they're a member of — plus their
/// docs dir, statting each file for its mtime. Returned newest-first.
fn gatherRecentItems(io: Io, alloc: Alloc, uid: []const u8) ![]RecentItem {
    var items: std.ArrayList(RecentItem) = .empty;

    // DMs: one conv per other authorized principal.
    for (try users.listAuthorized(io, alloc)) |u| {
        if (std.mem.eql(u8, u.id, uid)) continue;
        const conv = try store.chatPairKey(alloc, uid, u.id);
        const dir = try store.dmConvDir(alloc, conv);
        const base = try std.fmt.allocPrint(alloc, "/chat/c/{s}", .{conv});
        const where = try std.fmt.allocPrint(alloc, "with {s}", .{u.name});
        try gatherConvSessions(io, alloc, &items, dir, base, where);
    }

    // Channels the viewer is a member of.
    for (try store.listUserChannels(io, alloc, uid)) |name| {
        const dir = try store.channelConvDir(alloc, name);
        const base = try std.fmt.allocPrint(alloc, "/channel/{s}", .{name});
        const where = try std.fmt.allocPrint(alloc, "in {s}", .{name});
        try gatherConvSessions(io, alloc, &items, dir, base, where);
    }

    // The viewer's own docs.
    for (try docs_store.listUserDocs(io, alloc, uid)) |d| {
        const path = docs_store.docPath(alloc, uid, d.slug) catch continue;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try items.append(alloc, .{
            .kind = .doc,
            .at_ns = st.mtime.nanoseconds,
            .at = try timefmt.formatRFC3339UTC(alloc, secsOf(st.mtime.nanoseconds)),
            .slug = d.slug,
            .title = d.title,
        });
    }

    const slice = try items.toOwnedSlice(alloc);
    std.mem.sort(RecentItem, slice, {}, newestFirst);
    return slice;
}

/// gatherConvSessions appends a chat row for each session in one conv: stat its
/// mtime, resolve the last author's name from the .lastauthor companion, and
/// build a one-line excerpt of the latest message. `base`/`where` are the conv's
/// pre-resolved URL base and per-viewer context label.
fn gatherConvSessions(io: Io, alloc: Alloc, items: *std.ArrayList(RecentItem), dir: []const u8, base: []const u8, where: []const u8) !void {
    for (try store.listSessions(io, alloc, dir)) |sid| {
        const path = try store.sessionMdPath(alloc, dir, sid);
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try items.append(alloc, .{
            .kind = .chat,
            .at_ns = st.mtime.nanoseconds,
            .at = try timefmt.formatRFC3339UTC(alloc, secsOf(st.mtime.nanoseconds)),
            .url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, sid }),
            .where = where,
            .topic = sid,
            .last_author = try lastAuthorName(io, alloc, dir, sid),
            .excerpt = try recentExcerpt(alloc, try lastMessageMarkdown(io, alloc, dir, sid)),
        });
    }
}

fn secsOf(ns: i96) i64 {
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

fn newestFirst(_: void, a: RecentItem, b: RecentItem) bool {
    return a.at_ns > b.at_ns;
}

/// lastAuthorName resolves the most-recent author's display name for a session:
/// read the `<sid>.lastauthor` companion uid, map to a name. "" when the
/// companion is missing (pre-companion sessions → recent.js's "New message").
fn lastAuthorName(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.lastauthor", .{sid});
    const path = try std.fs.path.join(alloc, &.{ dir, "sessions", file });
    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return "";
    const auid = std.mem.trim(u8, raw, " \t\r\n");
    if (auid.len == 0) return "";
    return users.getUserName(io, alloc, auid);
}

/// lastMessageMarkdown returns the raw markdown of a session's most recent
/// message, or "" if empty/unreadable. Reads the whole transcript — fine at our
/// scale (the page already stats every session file). Mirrors Go.
fn lastMessageMarkdown(io: Io, alloc: Alloc, dir: []const u8, sid: []const u8) ![]const u8 {
    const raw = (try store.rawSession(io, alloc, dir, sid)) orelse return "";
    const msgs = try store.decodeChatFile(alloc, raw);
    if (msgs.len == 0) return "";
    return msgs[msgs.len - 1].markdown;
}

// ── recentExcerpt (Go's recentExcerpt, regex ports done by hand) ──────────────

/// recentExcerpt renders a one-line plain-text preview of a message's raw
/// markdown: image tags (HTML `<img …>` or markdown `![…](…)`) collapse to
/// "[image]", whitespace runs become a single space, trimmed, capped at
/// recent_excerpt_cap codepoints (+ "…"). Mirrors Go's recentExcerpt; the client
/// CSS-clamps the visible height to three lines.
fn recentExcerpt(alloc: Alloc, markdown: []const u8) ![]const u8 {
    const no_html = try replaceImgHtml(alloc, markdown);
    const no_md = try replaceImgMarkdown(alloc, no_html);
    const collapsed = try collapseWhitespace(alloc, no_md);
    return capCodepoints(alloc, collapsed, recent_excerpt_cap);
}

/// replaceImgHtml collapses each `<img\b[^>]*>` span to "[image]" (case-
/// insensitive, spans newlines). The `\b` after "img" rejects "<imgx…".
fn replaceImgHtml(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 4 <= s.len and std.ascii.eqlIgnoreCase(s[i .. i + 4], "<img") and
            (i + 4 == s.len or !isWordByte(s[i + 4])))
        {
            if (std.mem.indexOfScalarPos(u8, s, i + 4, '>')) |gt| {
                try out.appendSlice(alloc, "[image]");
                i = gt + 1;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// replaceImgMarkdown collapses each `!\[[^\]]*\]\([^)]*\)` to "[image]".
fn replaceImgMarkdown(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (matchMdImage(s, i)) |end| {
                try out.appendSlice(alloc, "[image]");
                i = end;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// matchMdImage returns the index just past a `![alt](url)` starting at `start`
/// (which points at '!'), or null. `alt` is `[^\]]*`, `url` is `[^)]*`.
fn matchMdImage(s: []const u8, start: usize) ?usize {
    var i = start + 2; // past "!["
    const alt_end = std.mem.indexOfScalarPos(u8, s, i, ']') orelse return null;
    i = alt_end + 1;
    if (i >= s.len or s[i] != '(') return null;
    i += 1;
    const url_end = std.mem.indexOfScalarPos(u8, s, i, ')') orelse return null;
    return url_end + 1;
}

/// collapseWhitespace replaces every run of `\s` (space, tab, CR, LF, FF, VT)
/// with a single space, then trims leading/trailing space. Mirrors Go's
/// wsRunRe.ReplaceAllString(...) + TrimSpace.
fn collapseWhitespace(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (s) |c| {
        if (isSpace(c)) {
            in_ws = true;
        } else {
            if (in_ws and out.items.len > 0) try out.append(alloc, ' ');
            in_ws = false;
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// capCodepoints truncates to `cap` Unicode codepoints, appending "…" (and
/// trimming a trailing space) when it had to cut. Mirrors Go's rune cap.
fn capCodepoints(alloc: Alloc, s: []const u8, cap: usize) ![]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (count == cap) {
            const head = std.mem.trimEnd(u8, s[0..i], " ");
            return std.fmt.allocPrint(alloc, "{s}…", .{head});
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += len;
        count += 1;
    }
    return s;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

fn isWordByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// replaceSeq returns `input` with every `needle` replaced by `repl` (alloc-owned).
fn replaceSeq(alloc: Alloc, input: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, input, needle, repl);
    const out = try alloc.alloc(u8, n);
    _ = std.mem.replace(u8, input, needle, repl, out);
    return out;
}
