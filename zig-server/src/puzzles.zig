//! puzzles: serves /puzzles — the Lyn Rummy puzzle surface.
//! Three routes:
//!   GET  /puzzles                                   the page (catalog baked in)
//!   GET  /puzzles/puzzle.js                          the Elm bundle
//!   POST /puzzles/sessions/<id>/puzzles/<idx>/actions  append one action line
//!
//! Phase 3 (now): the whole surface is gated JUST_NEEDS_NAME — every request
//! resolves its identity (users.currentUserID), and with no identity we redirect
//! to /login exactly like Go's Gated wrapper. The resolved id is the storage key
//! (replacing the phase-2 stub). The page allocates a real session id + writes
//! meta; POST .../actions appends to disk.

const std = @import("std");
const http = @import("http.zig");
const storage = @import("storage.zig");
const users = @import("users.zig");

const puzzle_js = @embedFile("puzzle_js");

// maxAppendBytes caps a single action line.
const maxAppendBytes = 64 * 1024;

// The curated catalogs, easiest-first (1-line … 6-line). Wired in build.zig.
const catalogs = [_][]const u8{
    @embedFile("puzzle_cat_1"),
    @embedFile("puzzle_cat_2"),
    @embedFile("puzzle_cat_3"),
    @embedFile("puzzle_cat_4"),
    @embedFile("puzzle_cat_5"),
    @embedFile("puzzle_cat_6"),
};

const Alloc = std.mem.Allocator;

/// handle dispatches /puzzles/* — the route table (a switch on the path tail).
/// `sub` keeps its leading '/' (e.g. "/puzzle.js", "/sessions/3/...").
///
/// The whole surface is gated JUST_NEEDS_NAME: resolve identity first and, with
/// none, redirect to /login (mirroring Go's Gated wrapper — the strategy IS the
/// contract, so the inner handlers never re-check). The resolved id is the
/// storage key for every write below.
pub fn handle(req: *std.http.Server.Request, io: std.Io, alloc: Alloc, sub: []const u8) !void {
    const user_id = try users.currentUserID(io, alloc, req);
    if (user_id.len == 0) {
        try http.redirect(req, "/login");
        return;
    }

    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try page(req, io, alloc, user_id);
    } else if (std.mem.eql(u8, sub, "/puzzle.js")) {
        try req.respond(puzzle_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.startsWith(u8, sub, "/sessions/")) {
        try sessionRoute(req, io, alloc, user_id, sub["/sessions/".len..]);
    } else {
        try http.notFound(req);
    }
}

/// sessionRoute handles the one session route Go exposes:
///   POST /sessions/<id>/puzzles/<idx>/actions  — append one action line.
/// `rest` is the path after "/sessions/".
fn sessionRoute(req: *std.http.Server.Request, io: std.Io, alloc: Alloc, user_id: []const u8, rest: []const u8) !void {
    var it = std.mem.splitScalar(u8, rest, '/');
    const id_str = it.next() orelse return http.notFound(req);
    const session_id = std.fmt.parseInt(i64, id_str, 10) catch return http.notFound(req);
    if (session_id <= 0) return http.notFound(req);

    // Expect exactly: puzzles / <idx> / actions, POST.
    const seg_puzzles = it.next() orelse return http.notFound(req);
    const idx_str = it.next() orelse return http.notFound(req);
    const seg_actions = it.next() orelse return http.notFound(req);
    if (it.next() != null) return http.notFound(req); // trailing junk
    if (!std.mem.eql(u8, seg_puzzles, "puzzles") or !std.mem.eql(u8, seg_actions, "actions")) {
        return http.notFound(req);
    }
    if (req.head.method != .POST) return http.notFound(req);

    const puzzle_idx = std.fmt.parseInt(i32, idx_str, 10) catch return http.notFound(req);
    if (puzzle_idx < 0) return http.notFound(req);

    try appendAction(req, io, alloc, user_id, session_id, puzzle_idx);
}

/// appendAction appends the POST body verbatim as one line in
/// puzzle_<idx>/actions.dsl.
/// The per-puzzle dir is created on first append.
fn appendAction(req: *std.http.Server.Request, io: std.Io, alloc: Alloc, user_id: []const u8, session_id: i64, puzzle_idx: i32) !void {
    if (!try storage.puzzleSessionExists(io, alloc, user_id, session_id)) {
        return http.notFound(req);
    }

    const body = (try http.readLimitedBody(req, alloc, maxAppendBytes)) orelse return;

    const rel = try std.fmt.allocPrint(alloc, "puzzle_{d}/actions.dsl", .{puzzle_idx});
    try storage.appendPuzzleSessionDslLine(io, alloc, user_id, session_id, rel, body);
    try req.respond("", .{ .status = .no_content });
}

/// page allocates a puzzle session, writes meta, and renders the HTML host with
/// both session_id and the full catalog baked into the Elm flag. Zero post-load
/// round trips before play.
fn page(req: *std.http.Server.Request, io: std.Io, alloc: Alloc, user_id: []const u8) !void {
    const catalog = try loadCatalog(alloc);
    const indented = try indentLines(alloc, catalog);

    const session_id = try storage.allocatePuzzleSessionID(io, alloc, user_id);

    // meta DSL: server-owned created_at, then a snapshot of the catalog this
    // session was bound to (so replay-by-index survives later catalog drift).
    const created_at: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const meta_dsl = try std.fmt.allocPrint(alloc, "created_at: {d}\n\ncatalog:\n{s}\n", .{ created_at, indented });
    try storage.writePuzzleSessionFile(io, alloc, user_id, session_id, "meta", meta_dsl);

    // Flag is one DSL string — `session_id:` scalar then a `catalog:` block.
    // Elm's Lib.PuzzleFlagDsl parses it whole.
    const flag_dsl = try std.fmt.allocPrint(alloc, "session_id: {d}\n\ncatalog:\n{s}\n", .{ session_id, indented });
    const flag_json = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(flag_dsl, .{})});

    const body = try std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ page_pre, flag_json, page_post });
    try req.respond(body, .{ .extra_headers = &.{http.html_ct} });
}

/// loadCatalog concatenates the catalogs, stripping `#` comments and blank
/// lines, surviving lines joined by '\n' (no trailing). Matches Go's loadCatalog.
fn loadCatalog(alloc: Alloc) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (catalogs) |cat| {
        var it = std.mem.splitScalar(u8, cat, '\n');
        while (it.next()) |raw| {
            var line = raw;
            if (std.mem.indexOfScalar(u8, line, '#')) |i| line = line[0..i];
            line = std.mem.trimEnd(u8, line, " \t");
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            if (!first) try out.append(alloc, '\n');
            first = false;
            try out.appendSlice(alloc, line);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// indentLines prefixes every non-empty line with two spaces; empty lines pass
/// through. Matches Go's indentLines.
fn indentLines(alloc: Alloc, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        if (l.len != 0) try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, l);
    }
    return out.toOwnedSlice(alloc);
}

// The HTML host, copied verbatim from Go's puzzlePage (parity, not redesign:
// Steve's "no CSS from Go" rule is about NEW features; this is an existing
// surface being ported byte-for-byte). Split around the single `flags:` slot —
// `page_pre` ends at `flags:`, the flag JSON goes in the format's space, and
// `page_post` resumes at ` });`.
const page_pre =
    \\<!doctype html>
    \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\  body { margin: 0; font-family: sans-serif; background: #f4f4ec;
    \\         touch-action: none; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
    \\</style>
    \\</head><body>
    \\<div id="root"></div>
    \\<script src="/puzzles/puzzle.js"></script>
    \\<script>
    \\  var app = Elm.Puzzle.init({ node: document.getElementById("root"), flags:
;

const page_post =
    \\ });
    \\  // Pointer transport: pointerdown captures the pointer; move/up are
    \\  // forwarded to Elm. Capture set synchronously (no Elm round-trip) so
    \\  // fast taps aren't missed; only the active pointer is forwarded.
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
    \\</body></html>
;
