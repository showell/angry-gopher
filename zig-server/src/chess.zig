//! chess: serves /chess — little chess toys, starting with the Knight's Tour.
//! A minimal public surface like /driving: no auth, no state.
//!
//! The tour is a zig→WASM core (games/chess/knight/knight.zig, built by
//! ops/build_chess_wasm) + a dumb plain-JS board host: the wasm owns the
//! precomputed knight-move graph and a stepwise DFS whose place/remove events
//! land on a scrubbable tape; board.js just draws the 64 move numbers it
//! exposes and forwards clicks/transport input.

const std = @import("std");
const http = @import("http.zig");

const knight_wasm = @embedFile("knight_wasm");
const chess_board_js = @embedFile("chess_board_js");

// A near-empty shell: board.js builds its own canvas + DOM, then fetches +
// instantiates knight.wasm and draws the board state zig maintains.
const page =
    "<!DOCTYPE html>\n" ++
    "<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
    "<title>Knight's Tour</title></head><body>" ++
    "<script src=\"/chess/knight.js\"></script>" ++
    "</body></html>";

/// handle dispatches /chess/* — the route table, a switch on the path tail.
pub fn handle(req: *std.http.Server.Request, sub: []const u8) !void {
    if (sub.len == 0 or std.mem.eql(u8, sub, "/")) {
        try req.respond(page, .{ .extra_headers = &.{http.html_ct} });
    } else if (std.mem.eql(u8, sub, "/knight.js")) {
        try req.respond(chess_board_js, .{ .extra_headers = &.{http.js_ct} });
    } else if (std.mem.eql(u8, sub, "/knight.wasm")) {
        try req.respond(knight_wasm, .{ .extra_headers = &.{http.wasm_ct} });
    } else {
        try http.notFound(req);
    }
}
