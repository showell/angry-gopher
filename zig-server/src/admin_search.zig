//! admin_search: /admin/search?key=lay — every chat message the admin can see
//! that contains `key`. Admin-only.
//!
//! **THE BASELINE, DUMB ON PURPOSE** (Steve, 2026-10-10): no index, no cache,
//! no slices. It reads every transcript the admin can see whole, one at a
//! time, and holds the turn while it does, so every other request waits. It
//! is run at the admin's discretion and while search is developed, as the
//! answer a smarter search must agree with.
//!
//! **ONLY WHAT THE VIEWER CAN SEE** (Steve): the admin's own DMs and channels
//! (`chat_store.visibleConvs`), as anyone's search will be, not every
//! conversation on the disk.
//!
//! A match is the key as a substring of a message's markdown, ASCII letters
//! folded (English on this site; any other byte must match exactly).

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const html = @import("html.zig");
const ui = @import("admin_ui.zig");
const chat = @import("chat.zig");
const store = @import("chat_store.zig");

const Request = std.http.Server.Request;

/// The shortest key searched: one letter matches nearly everything.
pub const min_key = 2;
/// The most matches listed; every one is counted.
pub const max_listed = 500;
/// Transcripts read by every search since start, for the tests: a HEAD or a
/// link from another site must read none.
pub var transcripts_read: usize = 0;

/// One message that matched, its text copied out of the transcript's arena.
pub const Hit = struct {
    /// The URL root of its conversation: `/chat/c/<a>_<b>` or `/channel/<name>`.
    base: []const u8,
    sid: []const u8,
    id: []const u8,
    from: []const u8,
    date: []const u8,
    snippet: []const u8,
};

pub const Result = struct {
    hits: []const Hit,
    /// Every match, listed or not.
    matched: usize,
    transcripts: usize,
    messages: usize,
    bytes: u64,
    /// Transcripts that could not be read or decoded, each skipped and counted.
    unreadable: usize,
    /// Transcripts too large for the request's memory, each skipped and counted.
    too_big: usize,
};

/// Every message `uid` can see whose markdown contains `key`: DMs first,
/// then channels, each transcript in session order.
pub fn search(io: Io, alloc: Alloc, uid: []const u8, key: []const u8) !Result {
    var hits: std.ArrayList(Hit) = .empty;
    var r: Result = .{ .hits = &.{}, .matched = 0, .transcripts = 0, .messages = 0, .bytes = 0, .unreadable = 0, .too_big = 0 };
    // **ONE TRANSCRIPT AT A TIME**, as the startup backfill reads them: a
    // match is copied out to `alloc`, and the rest goes with the arena. The
    // request's own allocator is an arena too (on both hosts), so a reset
    // here gives back what the parent can take again only in part: what the
    // search holds at its peak is a few transcripts' worth, not one, and
    // never the whole of chat.
    var per = std.heap.ArenaAllocator.init(alloc);
    defer per.deinit();
    for (try store.visibleConvs(io, alloc, uid)) |conv| {
        const dir = conv.dir;
        const base = conv.base;
        for (try store.listSessions(io, alloc, dir)) |sid| {
            _ = per.reset(.retain_capacity);
            const a = per.allocator();
            r.transcripts += 1;
            transcripts_read += 1;
            // absent-ok: a transcript gone since the listing, or one that cannot be read, is counted and said on the page, never taken as no match.
            const raw = (store.rawSession(io, a, dir, sid) catch |e| {
                if (e == error.OutOfMemory) r.too_big += 1 else r.unreadable += 1;
                continue;
            }) orelse {
                r.unreadable += 1;
                continue;
            };
            r.bytes += raw.len;
            const msgs = store.decodeChatFile(a, raw) catch |e| {
                if (e == error.OutOfMemory) r.too_big += 1 else r.unreadable += 1;
                continue;
            };
            for (msgs) |m| {
                r.messages += 1;
                const at = std.ascii.indexOfIgnoreCase(m.markdown, key) orelse continue;
                r.matched += 1;
                if (hits.items.len == max_listed) continue;
                try hits.append(alloc, .{
                    .base = base,
                    .sid = sid,
                    .id = try alloc.dupe(u8, m.id),
                    .from = try alloc.dupe(u8, m.from),
                    .date = try alloc.dupe(u8, m.date),
                    .snippet = try alloc.dupe(u8, snippetAround(m.markdown, at, key.len)),
                });
            }
        }
    }
    r.hits = try hits.toOwnedSlice(alloc);
    return r;
}

/// Up to `pad` bytes either side of the match.
fn snippetAround(text: []const u8, at: usize, len: usize) []const u8 {
    const pad = 80;
    const start = at -| pad;
    const end = @min(text.len, at + len + pad);
    return text[start..end];
}

/// render writes the page. The caller has already checked the admin gate.
pub fn render(req: *Request, io: Io, alloc: Alloc) !void {
    const raw_key = http.queryValue(try http.target(req, alloc), "key") orelse "";
    const key = std.mem.trim(u8, try chat.urlDecode(alloc, raw_key), " \t\r\n");
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "🐹 Search your messages", "/admin/search");
    try b.print(alloc, "<form method=\"get\" action=\"/admin/search\"><input name=\"key\" value=\"{s}\" autofocus> <button>Search</button></form>\n", .{try html.htmlEscape(alloc, key)});
    try b.appendSlice(alloc, "<p class=\"muted\">Reads every transcript you can see, and every other request waits while it does. A baseline, not the search people use.</p>\n");
    // **ONLY A GET FROM THIS SITE SEARCHES**: a HEAD reads nothing (as
    // /admin/backup's), and a link from another site, which the admin's
    // cookie follows, gets the form, not a walk that stalls every request.
    // A typed URL or a bookmark says `none`; a client that sends no
    // Sec-Fetch-Site (curl) is taken as typed.
    const site = try http.header(req, alloc, "sec-fetch-site");
    const from_here = if (site) |s| std.mem.eql(u8, s, "same-origin") or std.mem.eql(u8, s, "none") else true;
    if (key.len == 0 or req.head.method != .GET or !from_here) {
        if (key.len != 0 and !from_here) try b.appendSlice(alloc, "<p>A search from another site's link does not run; press Search.</p>\n");
        try ui.end(&b, alloc);
        return req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
    }
    if (key.len < min_key) {
        try b.print(alloc, "<p>A key of at least {d} characters.</p>\n", .{min_key});
        try ui.end(&b, alloc);
        return req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
    }
    const r = try search(io, alloc, ui.admin_uid, key);
    try b.print(alloc, "<p>{d} messages match, of {d} in {d} transcripts ({s}){s}{s}.</p>\n", .{
        r.matched,
        r.messages,
        r.transcripts,
        try ui.humanBytes(alloc, @intCast(r.bytes)),
        if (r.unreadable > 0) try std.fmt.allocPrint(alloc, "; {d} could not be read", .{r.unreadable}) else "",
        if (r.too_big > 0) try std.fmt.allocPrint(alloc, "; {d} too large to read here", .{r.too_big}) else "",
    });
    if (r.matched > r.hits.len) try b.print(alloc, "<p class=\"muted\">The first {d} are listed.</p>\n", .{r.hits.len});
    try b.appendSlice(alloc, "<table>");
    for (r.hits) |h| {
        try b.print(alloc, "<tr><td><a href=\"{s}/{s}#msg-{s}\">{s}</a></td><td>{s}</td><td>{s}</td><td>{s}</td></tr>", .{
            try html.htmlEscape(alloc, h.base),
            try html.htmlEscape(alloc, h.sid),
            try html.htmlEscape(alloc, h.id),
            try html.htmlEscape(alloc, h.id),
            try html.htmlEscape(alloc, h.from),
            try html.htmlEscape(alloc, h.date),
            try html.htmlEscape(alloc, h.snippet),
        });
    }
    try b.appendSlice(alloc, "</table>\n");
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}
