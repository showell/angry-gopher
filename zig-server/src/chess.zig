//! chess: serves /chess — little chess toys. A minimal public surface like
//! /driving: no auth, no state.
//!
//! Two toys share one engine: games/chess/core/tape.zig owns the scrubbable
//! event tape + display, and each toy (knight.zig, queens.zig) is just a
//! search machine compiled into its own tiny wasm (ops/build_chess_wasm) with
//! the same ABI. board.js is the one shared JS host — the page shells below
//! differ only in the window.CHESS_TOY config they inline. The code itself is
//! part of the product: /chess/code serves the real sources (the same files
//! the wasm is built from, embedded at build time).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const html = @import("html.zig");
const users = @import("users.zig");

const knight_wasm = @embedFile("knight_wasm");
const queens_wasm = @embedFile("queens_wasm");
const chess_board_js = @embedFile("chess_board_js");

// The sources /chess/code exhibits — embedded from the exact files the wasm
// is built from, so the page can never drift from what actually runs.
const src_tape = @embedFile("chess_src_tape");
const src_knight = @embedFile("chess_src_knight");
const src_queens = @embedFile("chess_src_queens");

/// shell builds a toy page at comptime: a near-empty document whose inline
/// config is the ONLY thing distinguishing the two toys — board.js and the
/// wasm ABI are shared.
fn shell(comptime title: []const u8, comptime config: []const u8) []const u8 {
    return "<!DOCTYPE html>\n" ++
        "<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
        "<title>" ++ title ++ "</title></head><body>" ++
        "<script>window.CHESS_TOY = " ++ config ++ ";</script>" ++
        "<script src=\"/chess/board.js\"></script>" ++
        "</body></html>";
}

const knight_page = shell("Knight's Tour",
    \\{
    \\  wasm: '/chess/knight.wasm',
    \\  title: "Knight's Tour",
    \\  piece: '♞',
    \\  noun: 'knights', noun1: 'knight',
    \\  hoverHint: 'knight moves',
    \\  clickHint: 'start a tour there',
    \\  startHint: 'click a square to place the first knight',
    \\  indigoHint: 'cut off from the tour',
    \\  solvedMsg: 'tour complete!',
    \\  exhaustedMsg: 'no tour from here (search exhausted)',
    \\}
);

const queens_page = shell("Eight Queens",
    \\{
    \\  wasm: '/chess/queens.wasm',
    \\  title: 'Eight Queens',
    \\  piece: '♛',
    \\  noun: 'queens', noun1: 'queen',
    \\  hoverHint: 'queen attacks',
    \\  clickHint: 'pin the first queen there',
    \\  startHint: 'click a square to pin the first queen',
    \\  indigoHint: 'attacked — no queen can live there',
    \\  solvedMsg: 'solution found!',
    \\  exhaustedMsg: 'no solution with that pin',
    \\}
);

// The launch pad for the toys: the site's generic top bar (Home · Chat · Blog,
// same as home.zig/blog.zig — the way back home) over two cards + the
// under-the-hood link, styled to match the boards' dark chrome.
const index_head =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>Chess Toys</title>
    \\<style>
    \\.app-top { background: #f0ede4; border-bottom: 1px solid #c9bfa7; padding: 8px 24px;
    \\           font-family: sans-serif; display: flex; justify-content: space-between;
    \\           align-items: baseline; position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: #000080; text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.app-top-user { font-size: 13px; color: #444; }
    \\.app-top-user a { color: #000080; }
    \\</style></head>
    \\<body style="margin:0;background:#0b0b0d;min-height:100vh;display:flex;flex-direction:column">
;
const index_body =
    \\<div style="flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;
    \\gap:18px;padding:24px;font-family:ui-monospace,Menlo,monospace;color:#cfd2d6">
    \\<div style="font-size:24px;letter-spacing:1px;color:#e8e2d6">Chess Toys</div>
    \\<div style="font-size:13px;color:#9aa0a6;max-width:520px;text-align:center">
    \\Classic backtracking searches you can watch think — and scrub, in both directions.</div>
    \\<div style="display:flex;gap:16px;flex-wrap:wrap;justify-content:center">
    \\<a href="/chess/knight" style="display:block;width:220px;padding:18px;background:#1d1f24;
    \\border:1px solid #33363d;border-radius:8px;color:#cfd2d6;text-decoration:none">
    \\<div style="font-size:34px;text-align:center">&#9822;</div>
    \\<div style="font-size:16px;text-align:center;margin-top:6px;color:#e8e2d6">Knight's Tour</div>
    \\<div style="font-size:12px;color:#9aa0a6;margin-top:8px">Visit all 64 squares exactly once.
    \\Knights pile on, dead-end, and get pulled back off.</div></a>
    \\<a href="/chess/queens" style="display:block;width:220px;padding:18px;background:#1d1f24;
    \\border:1px solid #33363d;border-radius:8px;color:#cfd2d6;text-decoration:none">
    \\<div style="font-size:34px;text-align:center">&#9819;</div>
    \\<div style="font-size:16px;text-align:center;margin-top:6px;color:#e8e2d6">Eight Queens</div>
    \\<div style="font-size:12px;color:#9aa0a6;margin-top:8px">Eight queens, none attacking another.
    \\Pin the first one anywhere; the search fills in the rest.</div></a>
    \\</div>
    \\<div style="font-size:12px;color:#6d7278">same engine underneath —
    \\<a href="/chess/code" style="color:#8a93a0">see how it works</a></div>
    \\</div></body></html>
;

/// respondIndex renders the launch pad with the generic site top bar (the link
/// back Home) — viewer resolved for the user chip, never gated, like /blog.
fn respondIndex(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, uid: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, index_head);
    try b.appendSlice(alloc,
        "<header class=\"app-top\"><div class=\"app-top-home\">" ++
        "<a href=\"/\">Home</a> · <a href=\"/chat\">Chat</a> · <a href=\"/blog\">Blog</a></div>" ++
        "<div class=\"app-top-user\">");
    const name = if (uid.len == 0) "" else try users.getUserName(io, alloc, uid);
    if (name.len == 0) {
        try b.appendSlice(alloc, "<a href=\"/login\">Log in</a>");
    } else {
        try b.print(alloc, "<strong>{s}</strong> · <a href=\"/logout\">Log out</a>", .{try html.htmlEscape(alloc, name)});
    }
    try b.appendSlice(alloc, "</div></header>");
    try b.appendSlice(alloc, index_body);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// /chess/code: the sources as exhibit. The intro tells the architecture story;
// the files below it are the ones the wasm is actually built from.
const code_intro =
    \\<div style="max-width:760px;font-size:14px;line-height:1.55;color:#b9bec6">
    \\<p>Both toys are one architecture. <b>core/tape.zig</b> is the shared engine: a search
    \\emits an <b>event tape</b> — place a piece, remove a piece, one byte per event — and the
    \\display just walks a cursor over that tape, applying events forward or inverting them
    \\backward. That single idea is what makes every animation pausable and scrubbable in both
    \\directions: rewinding is not a feature bolted onto the search, it falls out of the data
    \\structure. The engine also owns the red overlay: a square where a piece was placed,
    \\found doomed, and pulled off ("empty and ever-touched" — the two are the same thing,
    \\because a square's events strictly alternate place/remove).</p>
    \\<p>Each toy is then just a <b>machine</b>: <b>knight.zig</b> precomputes the knight-move
    \\graph at compile time and runs a depth-first search for a full tour; <b>queens.zig</b>
    \\runs the classic row-by-row eight-queens search with column/diagonal bitmasks. A machine
    \\implements four things — <code>target_count</code>, <code>genOne</code> (one search
    \\transition, one event), <code>resetMachine</code>, and its own "impossible right now"
    \\overlay (the indigo squares: unreachable for the knight, attacked for the queens). The
    \\shared wasm ABI is emitted from one list, so the toys cannot drift apart.</p>
    \\<p>Everything above compiles to a freestanding WebAssembly module of a few kilobytes —
    \\no allocator, no imports, no JS framework. The browser side, <b>board.js</b>, is
    \\deliberately dumb: it draws the 64 move numbers and two overlay masks the wasm exposes,
    \\and forwards clicks. These are the exact sources the live modules are built from,
    \\embedded into the server binary at build time. Also on
    \\<a href="https://github.com/showell/angry-gopher/tree/master/games/chess" style="color:#8a93a0">GitHub</a>.</p>
    \\</div>
;

const CodeFile = struct { name: []const u8, body: []const u8 };
const code_files = [_]CodeFile{
    .{ .name = "games/chess/core/tape.zig", .body = src_tape },
    .{ .name = "games/chess/knight.zig", .body = src_knight },
    .{ .name = "games/chess/queens.zig", .body = src_queens },
    .{ .name = "games/chess/board.js", .body = chess_board_js },
};

fn respondCodePage(req: *std.http.Server.Request, alloc: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc,
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Chess Toys — under the hood</title></head>
        \\<body style="margin:0;background:#0b0b0d;display:flex;flex-direction:column;align-items:center;
        \\gap:14px;padding:36px 16px;font-family:ui-monospace,Menlo,monospace;color:#cfd2d6">
        \\<div style="font-size:12px"><a href="/chess" style="color:#8a93a0">chess toys</a></div>
        \\<div style="font-size:22px;letter-spacing:1px;color:#e8e2d6">Under the hood</div>
    );
    try out.appendSlice(alloc, code_intro);
    for (code_files) |f| {
        try out.appendSlice(alloc, "<div style=\"width:min(900px,100%)\"><div style=\"font-size:13px;color:#e8e2d6;margin:18px 0 6px\">");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, "</div><pre style=\"margin:0;padding:14px;background:#14161a;border:1px solid #2a2d33;" ++
            "border-radius:6px;overflow-x:auto;font-size:12px;line-height:1.45;color:#c4cad2\">");
        try out.appendSlice(alloc, try html.htmlEscape(alloc, f.body));
        try out.appendSlice(alloc, "</pre></div>");
    }
    try out.appendSlice(alloc, "</body></html>");
    try req.respond(out.items, .{ .extra_headers = &.{http.html_ct} });
}

/// handle dispatches /chess/* — the route table, a switch on the path tail.
pub fn handle(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, uid: []const u8, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try respondIndex(req, io, alloc, uid);
    } else if (std.mem.eql(u8, sub, "/knight")) {
        try req.respond(knight_page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/queens")) {
        try req.respond(queens_page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/code")) {
        try respondCodePage(req, alloc);
    } else if (std.mem.eql(u8, sub, "/board.js")) {
        try req.respond(chess_board_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.eql(u8, sub, "/knight.wasm")) {
        try req.respond(knight_wasm, .{ .extra_headers = &.{http.wasm_ct} });
    } else if (std.mem.eql(u8, sub, "/queens.wasm")) {
        try req.respond(queens_wasm, .{ .extra_headers = &.{http.wasm_ct} });
    } else {
        try http.notFound(req);
    }
}
