//! learn: /learn — the aspiring-developer tutorial that walks through how chat
//! was built (port of server/learn/learn.go). Top-level + unauthed (public). The
//! page is a near-empty shell that learn.js fills in via createElement; it
//! deliberately loads NO shared stylesheet (the "grow the page in JS-styles only"
//! experiment) — only colors.js + the chat widget modules its demos reuse, plus
//! the three learn bundles.
//!
//!   GET /learn                                     the shell + script loads
//!   GET /learn/{learn,callback_log,fake_host}.js   the embedded learn bundles
//!   GET /learn/source/<file>                       raw text of an allowlisted
//!                                                  module (the spoiler widget)

const std = @import("std");
const http = @import("http.zig");
const chat = @import("chat.zig");

const Request = std.http.Server.Request;

const learn_js = @embedFile("learn_js");
const callback_log_js = @embedFile("learn_callback_log_js");
const fake_host_js = @embedFile("learn_fake_host_js");

/// handle dispatches /learn* — `sub` is the path after "/learn" ("" for the
/// page, "/<x>.js" for a bundle, "/source/<file>" for a spoiler).
pub fn handle(req: *Request, sub: []const u8) !void {
    if (sub.len == 0) return req.respond(page_html, .{ .extra_headers = &.{http.html_ct} });
    if (std.mem.eql(u8, sub, "/learn.js")) return serveJS(req, learn_js);
    if (std.mem.eql(u8, sub, "/callback_log.js")) return serveJS(req, callback_log_js);
    if (std.mem.eql(u8, sub, "/fake_host.js")) return serveJS(req, fake_host_js);
    if (std.mem.startsWith(u8, sub, "/source/")) return serveSource(req, sub["/source/".len..]);
    return http.notFound(req);
}

fn serveJS(req: *Request, body: []const u8) !void {
    try req.respond(body, .{ .extra_headers = &.{http.js_ct} });
}

/// serveSource serves the raw text of an allowlisted module so the spoiler widget
/// shows real, deployed source (never drifts). 404 for anything off the list —
/// the allowlist IS the path guard. Mirrors HandleLearnSource.
fn serveSource(req: *Request, file: []const u8) !void {
    const body = sourceBytes(file) orelse return http.notFound(req);
    try req.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

/// sourceBytes maps an allowlisted served filename to its embedded bytes (the
/// SAME bundles the binary serves elsewhere, so source and runtime can't drift).
/// Mirrors Go's learnSourceAllowlist. The chat modules reuse build.zig's
/// chat_js_* embeds; the two demo modules use the learn embeds.
fn sourceBytes(file: []const u8) ?[]const u8 {
    const table = .{
        .{ "chat_image_popup.js", @embedFile("chat_js_image_popup") },
        .{ "chat_code_popup.js", @embedFile("chat_js_code_popup") },
        .{ "chat_time_popup.js", @embedFile("chat_js_time_popup") },
        .{ "message.js", @embedFile("chat_js_message") },
        .{ "message_view.js", @embedFile("chat_js_message_view") },
        .{ "nav_stack.js", @embedFile("chat_js_nav_stack") },
        .{ "middle_pane.js", @embedFile("chat_js_middle_pane") },
        .{ "chat_right_sidebar.js", @embedFile("chat_js_right_sidebar") },
        .{ "chat_compose.js", @embedFile("chat_js_compose") },
        .{ "chat_add_topic.js", @embedFile("chat_js_add_topic") },
        .{ "chat_drag_to_pin.js", @embedFile("chat_js_drag_to_pin") },
        .{ "callback_log.js", callback_log_js },
        .{ "fake_host.js", fake_host_js },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, file, e[0])) return e[1];
    }
    return null;
}

// ── the page (a static shell; learn.js builds everything else) ────────────────

const v = chat.asset_v;

/// scripts: the exact load order Go emits. colors.js + install() FIRST (chat
/// modules read ChatColors tokens at construction), then the reused chat widgets,
/// then the three learn bundles. All comptime (the asset version is a constant).
const scripts =
    "<script src=\"/chat/colors.js?v=" ++ v ++ "\"></script>" ++
    "<script>ChatColors.install();</script>" ++
    "<script src=\"/chat/chat_image_popup.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/chat_code_popup.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/chat_time_popup.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/message.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/message_view.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/nav_stack.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/middle_pane.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/chat_right_sidebar.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/chat_compose.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/chat_add_topic.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/chat/chat_drag_to_pin.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/learn/callback_log.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/learn/fake_host.js?v=" ++ v ++ "\"></script>" ++
    "<script src=\"/learn/learn.js?v=" ++ v ++ "\"></script>";

/// page_html: the minimal shell — no shared <style>, an empty #learn-root, then
/// the scripts. Em dash in the title is literal (html.EscapeString leaves it).
const page_html =
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Learn — Lyn Rummy</title>" ++
    "</head><body><div id=\"learn-root\"></div>" ++ scripts ++ "</body></html>";
