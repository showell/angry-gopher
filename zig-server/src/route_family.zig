//! route_family: what a path is before the turn, in Zig (no Roc runs
//! outside a call, roc-webbox docs/ROC-CHAT.md R1): the part of the site
//! it is for, and its body's cap. Pure; router.zig serves by them, and
//! chat_twin_test.zig holds them to the Roc router's parse.

const std = @import("std");
const http = @import("webbox").http;
const request_limits = @import("limits.zig");

/// **WHICH PART OF THE SITE A REQUEST IS FOR** (metal-vmm QUEUE 189.5), as
/// /admin/host counts them: an upload (posted or fetched), a live stream,
/// docs, the rest of chat, the games, the admin pages, or the site around
/// them (the home page, sign-in, assets).
pub const Family = enum { uploads, streams, docs, chat, games, admin, site };

pub fn familyOf(path: []const u8) Family {
    if (http.pathUnder(path, "/admin") != null) return .admin;
    const in_chat = http.pathUnder(path, "/chat") orelse http.pathUnder(path, "/channel");
    if (in_chat) |sub| {
        // As routeBodyLimit reads an upload: `.../upload/` is the upload.
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, sub, "/"), "/upload") or std.mem.indexOf(u8, sub, "/uploads/") != null) return .uploads;
        // `.../stream/` is a topic's stream too (Route.roc's segments skip
        // empty ones), as the router holds it (the hooks test below).
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, sub, "/"), "/stream") or std.mem.eql(u8, sub, "/notifications")) return .streams;
        if (http.pathUnder(sub, "/docs") != null) return .docs;
        return .chat;
    }
    for ([_][]const u8{ "/game", "/puzzles", "/driving", "/chess", "/delivery", "/play" }) |g|
        if (http.pathUnder(path, g) != null) return .games;
    return .site;
}

/// **EACH ROUTE'S CAP ON A BODY, FROM ITS PATH** (metal-vmm QUEUE 167.2): the
/// most any handler under the path reads, which the host reads the body by
/// (webbox's body.zig: before the turn, or in it under its deadline). Every
/// handler checks its own cap again (`http.readLimitedBody`), so a path's
/// is the largest of its handlers', and the test below holds each handler's
/// within its path's. Only the upload's is past `body_rule.before_turn_most`.
pub fn routeBodyLimit(path: []const u8) u64 {
    const caps = request_limits.body;
    const in_chat = http.pathUnder(path, "/chat") orelse http.pathUnder(path, "/channel");
    if (in_chat) |sub| {
        // Route.roc's segments skip empty ones: `.../upload/` is the upload.
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, sub, "/"), "/upload")) return caps.upload_any;
        if (http.pathUnder(sub, "/docs") != null) return caps.doc;
        return caps.chat_message;
    }
    if (http.pathUnder(path, "/game") != null) return caps.game_new_session;
    if (std.mem.eql(u8, path, "/admin/script")) return caps.script;
    return caps.largest_form;
}
