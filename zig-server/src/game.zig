//! game: serves /game — the full Lyn Rummy Elm client + its deliberately-dumb
//! session HTTP surface.
//!
//! Routes (the switch in handle() is the route table):
//!   GET  /game                         the play page (new game)
//!   GET  /game/<id>                     the play page, resuming session <id>
//!   GET  /game/elm.js | engine.js | engine_glue.js   the embedded JS bundles
//!   POST /game/new-session             allocate id, write meta, return {session_id}
//!   GET  /game/sessions                HTML browser of a player's sessions
//!   GET  /game/api/sessions            the same list as JSON
//!   GET  /game/sessions/<id>           per-session debug view (HTML)
//!   POST /game/sessions/<id>/actions   append one wire-DSL line to actions.dsl
//!   GET  /game/sessions/<id>/actions   bootstrap: meta + "---" + actions
//!   POST /game/sessions/<id>/annotations  append one JSONL line
//!
//! Like puzzles, the whole surface is gated JUST_NEEDS_NAME: resolve identity
//! first and, with none, redirect to /login. The resolved id is the storage key.
//! The big difference from puzzles is READ-BACK — resume + the list/detail pages
//! read sessions off disk; the puzzle surface was write-only.

const std = @import("std");
const http = @import("http.zig");
const storage = @import("storage.zig");
const users = @import("users.zig");
const session_meta = @import("session_meta.zig");
const timefmt = @import("timefmt.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;
const SessionMeta = session_meta.SessionMeta;

// The compiled bundles, baked into the binary (wired in build.zig).
const elm_js = @embedFile("game_elm_js");
const engine_js = @embedFile("game_engine_js");
const engine_glue_js = @embedFile("game_engine_glue_js");

// Body-size caps. Mirror Go's limits.go.
const max_new_session_bytes = 256 * 1024;
const max_append_bytes = 64 * 1024;

/// handle dispatches /game/* — `sub` keeps its leading '/' (e.g. "/elm.js",
/// "/sessions/3/actions"), empty for exactly "/game".
pub fn handle(req: *Request, io: std.Io, alloc: Alloc, sub: []const u8) !void {
    const user_id = try users.currentUserID(io, alloc, req);
    if (user_id.len == 0) {
        try http.redirect(req, "/login");
        return;
    }

    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try playPage(req, io, alloc, user_id, 0);
    } else if (std.mem.eql(u8, sub, "/elm.js")) {
        try req.respond(elm_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.eql(u8, sub, "/engine.js")) {
        try req.respond(engine_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.eql(u8, sub, "/engine_glue.js")) {
        try req.respond(engine_glue_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.eql(u8, sub, "/new-session")) {
        try newSession(req, io, alloc, user_id);
    } else if (std.mem.eql(u8, sub, "/sessions")) {
        try sessionsList(req, io, alloc, user_id);
    } else if (std.mem.eql(u8, sub, "/api/sessions")) {
        try sessionsJSON(req, io, alloc, user_id);
    } else if (std.mem.startsWith(u8, sub, "/sessions/")) {
        try sessionRoute(req, io, alloc, user_id, sub["/sessions/".len..]);
    } else {
        // /game/<id> — resume a session by numeric id.
        const trimmed = std.mem.trim(u8, sub, "/");
        const id = std.fmt.parseInt(i64, trimmed, 10) catch return http.notFound(req);
        if (id <= 0) return http.notFound(req);
        try playPage(req, io, alloc, user_id, id);
    }
}

/// sessionRoute fans out the per-session URL space (`rest` is the path after
/// "/sessions/").
fn sessionRoute(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8, rest: []const u8) !void {
    var it = std.mem.splitScalar(u8, rest, '/');
    const id_str = it.next() orelse return http.notFound(req);
    const session_id = std.fmt.parseInt(i64, id_str, 10) catch return http.notFound(req);
    if (session_id <= 0) return http.notFound(req);

    const seg1 = it.next();
    if (seg1 == null) {
        // /sessions/<id> — detail view.
        try sessionDetail(req, io, alloc, user_id, session_id);
        return;
    }
    if (it.next() != null) return http.notFound(req); // more than two segments

    if (std.mem.eql(u8, seg1.?, "actions")) {
        if (req.head.method == .POST) {
            try appendSessionLine(req, io, alloc, user_id, session_id, .actions);
        } else {
            try sessionBootstrap(req, io, alloc, user_id, session_id);
        }
    } else if (std.mem.eql(u8, seg1.?, "annotations")) {
        try appendSessionLine(req, io, alloc, user_id, session_id, .annotations);
    } else {
        try http.notFound(req);
    }
}

// ── session creation ─────────────────────────────────────────────────────────

/// newSession creates a fresh full-game session: the POST body is Elm's
/// DSL-encoded GameState; the server prepends a server-owned created_at, writes
/// the merged DSL to <session>/meta, and returns the id as JSON. The game-state
/// DSL is stored verbatim.
fn newSession(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);

    const game_state_dsl = (try http.readLimitedBody(req, alloc, max_new_session_bytes)) orelse return;

    const id = try storage.allocateSessionID(io, alloc, user_id);

    const meta = SessionMeta{
        .created_at = nowUnix(io),
        .label = "",
        .game_state_dsl = game_state_dsl,
    };
    const meta_bytes = try session_meta.formatSessionMeta(alloc, meta);
    try storage.writeSessionFile(io, alloc, user_id, id, "meta", meta_bytes);

    // {"session_id":N}\n — matches Go's json.Encoder (no spaces, trailing newline).
    const body = try std.fmt.allocPrint(alloc, "{{\"session_id\":{d}}}\n", .{id});
    try req.respond(body, .{ .extra_headers = &.{http.json_ct} });
}

// ── action / annotation writes (the dumb path) ───────────────────────────────

const LineKind = enum { actions, annotations };

/// appendSessionLine is the universal write handler: POST body → one appended
/// line in <session>/<rel>. Actions are wire-DSL text (actions.dsl); annotations
/// are JSONL (compacted). A Lyn Rummy move bumps last-seen.
fn appendSessionLine(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8, session_id: i64, kind: LineKind) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req);
    if (!try storage.sessionExists(io, alloc, user_id, session_id)) return http.notFound(req);

    const body = (try http.readLimitedBody(req, alloc, max_append_bytes)) orelse return;

    switch (kind) {
        .actions => {
            try storage.appendSessionDslLine(io, alloc, user_id, session_id, "actions.dsl", body);
            users.touchUser(io, alloc, user_id); // a move counts as activity
        },
        .annotations => {
            try storage.appendSessionJSONLLine(io, alloc, user_id, session_id, "annotations.jsonl", body);
        },
    }
    try req.respond("", .{ .status = .no_content });
}

// ── session reads ────────────────────────────────────────────────────────────

/// sessionBootstrap returns the resume bundle as one text/plain document: the
/// meta DSL, a `---` separator line, then the action log DSL. Elm splits on the
/// separator.
fn sessionBootstrap(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8, session_id: i64) !void {
    if (!try storage.sessionExists(io, alloc, user_id, session_id)) return http.notFound(req);

    const meta_bytes = (try storage.readSessionFile(io, alloc, user_id, session_id, "meta")) orelse "";
    const actions_bytes = (try storage.readSessionFile(io, alloc, user_id, session_id, "actions.dsl")) orelse "";

    // meta (already ends in \n) + "---\n" + actions (may be empty or end in \n).
    const body = try std.fmt.allocPrint(alloc, "{s}---\n{s}", .{ meta_bytes, actions_bytes });
    try req.respond(body, .{ .extra_headers = &.{http.plain_ct} });
}

/// sessionsList renders the HTML browser of a player's full-game sessions,
/// newest first.
fn sessionsList(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8) !void {
    const ids = try storage.listSessionIDs(io, alloc, user_id);
    std.mem.sort(i64, ids, {}, std.sort.desc(i64)); // newest first

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, sessions_list_head);
    if (ids.len == 0) {
        try b.appendSlice(alloc, "<tr><td colspan=\"4\" class=\"muted\">No sessions yet.</td></tr>");
    }
    for (ids) |id| {
        const meta = try readMeta(io, alloc, user_id, id);
        const count = try storage.countSessionActions(io, alloc, user_id, id);
        const ts = if (meta.created_at > 0) try formatEastern(alloc, meta.created_at) else "";
        try b.print(alloc, "<tr><td><a href=\"/game/sessions/{d}\">#{d}</a></td><td>{s}</td><td class=\"n\">{d}</td><td>{s}</td></tr>", .{
            id, id, try htmlEscape(alloc, ts), count, try htmlEscape(alloc, meta.label),
        });
    }
    try b.appendSlice(alloc, "</table></body></html>");
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

/// sessionsJSON is the api/sessions equivalent of sessionsList.
fn sessionsJSON(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8) !void {
    const ids = try storage.listSessionIDs(io, alloc, user_id);
    std.mem.sort(i64, ids, {}, std.sort.desc(i64));

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, "{\"sessions\":[");
    for (ids, 0..) |id, i| {
        if (i > 0) try b.append(alloc, ',');
        const meta = try readMeta(io, alloc, user_id, id);
        const count = try storage.countSessionActions(io, alloc, user_id, id);
        // Field order matches Go's entry struct: id, created_at, label, action_count.
        try b.print(alloc, "{{\"id\":{d},\"created_at\":{d},\"label\":{f},\"action_count\":{d}}}", .{
            id, meta.created_at, std.json.fmt(meta.label, .{}), count,
        });
    }
    try b.appendSlice(alloc, "]}\n");
    try req.respond(b.items, .{ .extra_headers = &.{http.json_ct} });
}

/// sessionDetail renders a debug view for a session dir — no replay, just what's
/// on disk.
fn sessionDetail(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8, session_id: i64) !void {
    if (!try storage.sessionExists(io, alloc, user_id, session_id)) return http.notFound(req);

    const meta = try readMeta(io, alloc, user_id, session_id);
    const action_count = try storage.countSessionActions(io, alloc, user_id, session_id);
    const ann_path = try std.fs.path.join(alloc, &.{ try storage.sessionDir(alloc, user_id, session_id), "annotations.jsonl" });
    const annotation_count = try storage.countTextLines(io, alloc, ann_path);

    const ts = if (meta.created_at > 0) try formatEastern(alloc, meta.created_at) else "";

    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, detail_head, .{ session_id, try htmlEscape(alloc, ts), try labelSuffix(alloc, meta.label) });
    if (try storage.readSessionFile(io, alloc, user_id, session_id, "meta")) |raw_meta| {
        try b.print(alloc, "<pre>{s}</pre>", .{try htmlEscape(alloc, raw_meta)});
    } else {
        try b.appendSlice(alloc, "<p class=\"muted\">no meta file</p>");
    }
    try b.print(alloc, "<p>actions.dsl: <strong>{d}</strong> lines</p>", .{action_count});
    try b.print(alloc, "<p>annotations.jsonl: <strong>{d}</strong> lines</p>", .{annotation_count});
    try b.appendSlice(alloc, "</body></html>");
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// ── play page ────────────────────────────────────────────────────────────────

/// playPage renders the Elm host. `session_id` 0 = new game (initialSessionId
/// null); >0 resumes.
fn playPage(req: *Request, io: std.Io, alloc: Alloc, user_id: []const u8, session_id: i64) !void {
    const initial = if (session_id > 0)
        try std.fmt.allocPrint(alloc, "{d}", .{session_id})
    else
        "null";
    const name = try users.getUserName(io, alloc, user_id);
    const name_json = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(name, .{})});

    // The two spaces in the format are the literal spaces Go has after `=` and
    // after `playerName:`; keeping them here avoids fragile trailing spaces in
    // the play_a / play_b multiline literals.
    const body = try std.fmt.allocPrint(alloc, "{s} {s}{s} {s}{s}", .{ play_a, initial, play_b, name_json, play_c });
    try req.respond(body, .{ .extra_headers = &.{http.html_ct} });
}

// ── small helpers ────────────────────────────────────────────────────────────

fn nowUnix(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// readMeta loads + parses <session>/meta, or a zero SessionMeta when absent
///.
fn readMeta(io: std.Io, alloc: Alloc, user_id: []const u8, session_id: i64) !SessionMeta {
    const b = (try storage.readSessionFile(io, alloc, user_id, session_id, "meta")) orelse return .{};
    return session_meta.parseSessionMeta(b);
}

/// labelSuffix mirrors Go's labelSuffix: "" for an empty label, else " · " +
/// escaped label.
fn labelSuffix(alloc: Alloc, label: []const u8) ![]const u8 {
    if (label.len == 0) return "";
    return std.fmt.allocPrint(alloc, " · {s}", .{try htmlEscape(alloc, label)});
}

/// htmlEscape mirrors Go's html.EscapeString: & ' < > " → &amp; &#39; &lt; &gt;
/// &#34;. Returns `s` unchanged (no allocation) when it has nothing to escape.
fn htmlEscape(alloc: Alloc, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "&'<>\"") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '\'' => try out.appendSlice(alloc, "&#39;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&#34;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

// ── Eastern-time formatting (the one tzdata gap) ─────────────────────────────
//
// Go formats list/detail timestamps as `time.Unix(t).In("America/New_York")`
// with layout "Jan 2, 2006 · 3:04 PM MST". zig std has no timezone database, so
// US Eastern DST rules are hardcoded here (EST = UTC-5, EDT = UTC-4; spring
// forward 2nd Sunday of March 02:00, fall back 1st Sunday of November 02:00 —
// the post-2007 US rule). Byte-exact with Go for every real session timestamp
// (all 2026); the only divergence is pre-2007 historical dates, which never
// appear in this data. Documented, non-gating — same spirit as the markdown
// soft-break divergence.

const month_abbr = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn formatEastern(alloc: Alloc, unix_secs: i64) ![]u8 {
    const edt = inEasternDST(unix_secs);
    const offset: i64 = if (edt) -4 * 3600 else -5 * 3600;
    const abbr = if (edt) "EDT" else "EST";

    const local = unix_secs + offset;
    const days = @divFloor(local, 86400);
    const tod = local - days * 86400; // [0, 86399]
    const civil = timefmt.civilFromDays(days);

    const hour24: u32 = @intCast(@divFloor(tod, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(tod, 3600), 60));
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    const ampm = if (hour24 < 12) "AM" else "PM";

    return std.fmt.allocPrint(alloc, "{s} {d}, {d} · {d}:{d:0>2} {s} {s}", .{
        month_abbr[civil.month - 1], civil.day, civil.year, hour12, minute, ampm, abbr,
    });
}

/// inEasternDST reports whether a UTC instant falls in US Eastern Daylight Time
/// under the post-2007 rule.
fn inEasternDST(unix_secs: i64) bool {
    const civil = timefmt.civilFromDays(@divFloor(unix_secs, 86400));
    const year = civil.year;
    // DST starts 2nd Sunday of March at 02:00 EST = 07:00 UTC.
    const dst_start = daysFromCivil(year, 3, nthSunday(year, 3, 2)) * 86400 + 7 * 3600;
    // DST ends 1st Sunday of November at 02:00 EDT = 06:00 UTC.
    const dst_end = daysFromCivil(year, 11, nthSunday(year, 11, 1)) * 86400 + 6 * 3600;
    return unix_secs >= dst_start and unix_secs < dst_end;
}

/// nthSunday returns the day-of-month of the `n`th Sunday of (year, month).
fn nthSunday(year: i64, month: u32, n: u32) u32 {
    const first = daysFromCivil(year, month, 1);
    const wd = weekday(first); // 0=Sunday … 6=Saturday
    const first_sunday_dom: u32 = 1 + ((7 - wd) % 7);
    return first_sunday_dom + (n - 1) * 7;
}

/// weekday returns 0=Sunday … 6=Saturday for a days-since-epoch count
/// (Hinnant; valid for z >= 0, which covers every real timestamp here).
fn weekday(z: i64) u32 {
    return @intCast(@mod(z + 4, 7));
}

/// daysFromCivil converts a civil date to days-since-1970-01-01 (Hinnant).
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0,399]
    const m: i64 = month;
    const doy = @divFloor(153 * (m + (if (month > 2) @as(i64, -3) else 9)) + 2, 5) + @as(i64, day) - 1; // [0,365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0,146096]
    return era * 146097 + doe - 719468;
}

// ── HTML templates (copied verbatim from Go's lynrummy_elm.go) ───────────────

const sessions_list_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 60px auto; max-width: 820px; padding: 0 24px; }
    \\h1 { color: #000080; }
    \\nav { margin-bottom: 16px; font-size: 13px; }
    \\nav a { color: #000080; }
    \\table { border-collapse: collapse; width: 100%; }
    \\th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #eee; }
    \\th { background: #f4f4ec; }
    \\tr:hover { background: #fafaf6; }
    \\a { color: #000080; }
    \\.muted { color: #888; }
    \\.n { text-align: right; font-variant-numeric: tabular-nums; }
    \\</style>
    \\</head><body>
    \\<nav><a href="/">← Home</a> &nbsp;·&nbsp; <a href="/game">Play</a></nav>
    \\<h1>Your sessions</h1>
    \\<p class="muted">Newest first.</p>
    \\<table><tr><th>id</th><th>created</th><th class="n">actions</th><th>label</th></tr>
;

// detail_head: format slots are {d} session id, {s} escaped timestamp, {s}
// already-escaped label suffix. The literal `{` in the inline <style> is escaped
// as `{{` for the format pass.
const detail_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body {{ font-family: sans-serif; margin: 60px auto; max-width: 860px; padding: 0 24px; }}
    \\h1 {{ color: #000080; margin-bottom: 4px; }}
    \\.sub {{ color: #666; margin-bottom: 24px; font-size: 14px; }}
    \\nav {{ margin-bottom: 16px; font-size: 13px; }}
    \\nav a {{ color: #000080; }}
    \\.muted {{ color: #888; }}
    \\ul {{ font-family: monospace; font-size: 13px; }}
    \\li {{ padding: 2px 0; }}
    \\pre {{ background: #f4f4ec; padding: 12px; border: 1px solid #ddd; overflow-x: auto; }}
    \\</style>
    \\</head><body>
    \\<nav><a href="/game/sessions">← All sessions</a> &nbsp;·&nbsp; <a href="/game">Play</a></nav>
    \\<h1>Session #{d}</h1>
    \\<p class="sub">Started {s}{s}</p>
    \\<h3>meta</h3>
;

// The play page, split around its two format slots: `var initialSessionId = `
// <initial> `;` … `playerName: ` <name_json> `,`. Copied verbatim from Go's
// lynrummyElmPlayWithSession (parity, not redesign).
const play_a =
    \\<!doctype html>
    \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\  body { margin: 0; font-family: sans-serif; background: #f4f4ec;
    \\         touch-action: none; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
    \\  .app-nav { padding: 8px 16px; background: #000080; color: white; font-size: 13px; }
    \\  .app-nav a { color: white; text-decoration: none; margin-right: 14px; }
    \\  .app-nav a:hover { text-decoration: underline; }
    \\  .app-main { padding: 0; }
    \\</style>
    \\</head><body>
    \\<div class="app-nav">
    \\  <a href="/">← Home</a>
    \\  <a href="/game/sessions">Sessions</a>
    \\</div>
    \\<div class="app-main">
    \\<div id="root"></div>
    \\<script src="/game/engine.js"></script>
    \\<script src="/game/elm.js"></script>
    \\<script src="/game/engine_glue.js"></script>
    \\<script>
    \\  var initialSessionId =
;

const play_b =
    \\;
    \\  var app = Elm.Game.init({
    \\    node: document.getElementById("root"),
    \\    flags: {
    \\      initialSessionId: initialSessionId,
    \\      seedSource: Date.now(),
    \\      playerName:
;

const play_c =
    \\,
    \\    },
    \\  });
    \\  app.ports.setSessionPath.subscribe(function(sid) {
    \\    var url = sid === "" ? "/game" : "/game/" + sid;
    \\    history.replaceState(null, "", url);
    \\  });
    \\  EngineGlue.attach(app);
    \\  // Pointer transport: a pointerdown inside the board captures the
    \\  // pointer (so a mouse/finger drag survives leaving the card) and its
    \\  // move/up are forwarded to Elm — Browser.Events has no pointer subs.
    \\  // Capture is set synchronously here on pointerdown (no Elm round-trip)
    \\  // so fast taps aren't missed; only the active pointer is forwarded.
    \\  (function () {
    \\    var captureEl = document.documentElement;
    \\    var tracked = null;
    \\    function sample(e) {
    \\      return { x: Math.round(e.clientX), y: Math.round(e.clientY), t: Math.floor(e.timeStamp) };
    \\    }
    \\    document.addEventListener("pointerdown", function (e) {
    \\      tracked = e.pointerId;
    \\      // Capture touch/pen so a finger-drag survives the card re-rendering
    \\      // mid-drag. Mouse needs no capture (document sees every move) and
    \\      // capturing a mouse pointer can interfere with button clicks.
    \\      if (e.pointerType !== "mouse") {
    \\        try { captureEl.setPointerCapture(e.pointerId); } catch (err) {}
    \\      }
    \\    });
    \\    document.addEventListener("pointermove", function (e) {
    \\      if (e.pointerId === tracked) app.ports.pointerMoved.send(sample(e));
    \\    });
    \\    function end(e) {
    \\      if (e.pointerId !== tracked) return;
    \\      tracked = null;
    \\      app.ports.pointerUp.send(sample(e));
    \\    }
    \\    document.addEventListener("pointerup", end);
    \\    document.addEventListener("pointercancel", end);
    \\  })();
    \\</script>
    \\</div>
    \\</body></html>
;
