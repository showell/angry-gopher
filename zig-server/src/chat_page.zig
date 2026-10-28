//! chat_page: the chat subsystem's one page the Zig still writes, the 404
//! that says why. The rest (the conversation page, the first-topic shell, the
//! empty /chat and the sidebar's payload) are the Roc's (roc-webbox
//! chat/Pages.roc), held to what the Zig wrote by chat_twin_test.zig's frozen
//! hashes (metal-vmm QUEUE 263d). Leans on chat_chrome.zig for the shared shell.

const std = @import("std");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const users = @import("users.zig");
const html = @import("webbox").html;
const chrome = @import("chat_chrome.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;
const htmlEscape = html.htmlEscape; // internal alias; impl in html.zig

fn sendHtml(req: *Request, status: std.http.Status, bytes: []const u8) !void {
    try req.respond(bytes, .{ .status = status, .extra_headers = &.{http.html_ct} });
}

/// **A 404 THAT SAYS WHY** (metal-vmm QUEUE 156(j)): `what` names what is not
/// there, and `back` is where to go instead. A page, not a bare "not found".
pub fn notFoundPage(req: *Request, io: Io, alloc: Alloc, uid: []const u8, what: []const u8, back: []const u8) !void {
    const viewer = try users.getUserName(io, alloc, uid);
    try sendHtml(req, .not_found, try notFoundHtml(alloc, viewer, what, back));
}

/// notFoundPage's bytes, for `viewer`.
pub fn notFoundHtml(alloc: Alloc, viewer: []const u8, what: []const u8, back: []const u8) ![]const u8 {
    var page = try chrome.page(alloc, "Chat", "Not here", viewer, "chat");
    const b = &page.body;
    try b.print(alloc, "<p>{s}</p><p><a href=\"{s}\">Go back</a></p>", .{ try htmlEscape(alloc, what), try htmlEscape(alloc, back) });
    return page.bytes();
}
