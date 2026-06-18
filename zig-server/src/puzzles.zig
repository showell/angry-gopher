//! puzzles: serves /puzzles — the Lyn Rummy puzzle surface. Mirrors Go's
//! server/lynrummy/puzzle.go. Three routes:
//!   GET  /puzzles                                   the page (catalog baked in)
//!   GET  /puzzles/puzzle.js                          the Elm bundle
//!   POST /puzzles/sessions/<id>/puzzles/<idx>/actions  append one action line
//!
//! Phase 1 (this file so far): the page + bundle. The catalog (6 curated DSL
//! files, easiest-first) is concatenated at request time and baked into the Elm
//! flag, exactly as Go does, so there are zero round trips before play. Storage
//! + the POST path land in phase 2; real identity in phase 3 (session_id is a
//! stub until then).

const std = @import("std");
const http = @import("http.zig");

const puzzle_js = @embedFile("puzzle_js");

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
pub fn handle(req: *std.http.Server.Request, alloc: Alloc, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try page(req, alloc);
    } else if (std.mem.eql(u8, sub, "/puzzle.js")) {
        try req.respond(puzzle_js, .{ .extra_headers = &.{http.js_ct} });
    } else {
        try http.notFound(req);
    }
}

/// page renders the HTML host with the full catalog + session id baked into the
/// Elm flag. Mirrors Go's puzzlePage (minus storage, which is phase 2).
fn page(req: *std.http.Server.Request, alloc: Alloc) !void {
    const catalog = try loadCatalog(alloc);
    const indented = try indentLines(alloc, catalog);

    const session_id: i64 = 0; // phase-1 stub; real allocation in phase 2

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
