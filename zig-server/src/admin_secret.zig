//! admin_secret: /admin/secret — changing the session secret, for the day
//! it leaks (gopher-metal QUEUE item 66; SECRET-LEAK.md there).
//!
//! gopher-metal has no shell, so this is how its secret is changed. A GET
//! shows a form that says what a change does; a POST with uid 1's password
//! (a session alone is not enough, as for /admin/backup) and a number of
//! days changes it (users.rotateSecret):
//!   - every member's session ends at once, the admin's too: they log in
//!     again with their passwords;
//!   - a player's cookie, signed with the old secret, still names them for
//!     the days given, and is re-signed on their next visit; after that it
//!     names no one. Players have no password, so a player who does not come
//!     back in time is lost. 0 days carries no one over: for a leak that is
//!     being used.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const users = @import("users.zig");
const chat = @import("chat.zig");
const html = @import("html.zig");
const ui = @import("admin_ui.zig");

const Request = std.http.Server.Request;

/// The most days the old secret may be kept for players.
pub const max_days = 90;

pub fn render(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method != .POST) return form(req, alloc, "", .ok);
    const sent = (try http.readLimitedBody(req, alloc, 4096)) orelse return;
    const password = (try chat.formField(alloc, sent, "password")) orelse "";
    if (!users.checkUserPassword(io, alloc, ui.admin_uid, password))
        return form(req, alloc, "That is not the password.", .forbidden);
    const days_text = std.mem.trim(u8, (try chat.formField(alloc, sent, "days")) orelse "", " ");
    const days = std.fmt.parseInt(i64, days_text, 10) catch -1;
    if (days < 0 or days > max_days)
        return form(req, alloc, std.fmt.comptimePrint("The days are a number from 0 to {d}.", .{max_days}), .bad_request);
    users.rotateSecret(io, alloc, days) catch |e|
        return form(req, alloc, try std.fmt.allocPrint(alloc, "The secret was not changed: {s}.", .{@errorName(e)}), .internal_server_error);

    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "The secret is changed", "");
    try b.print(alloc,
        \\<p>Every member's session has ended, yours too: <a href="/login/full">log in again</a>.</p>
        \\<p>Players' cookies are renewed on their next visit for {d} day(s); after that, a player who has not come back is not recognised.</p>
        \\
    , .{days});
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

fn form(req: *Request, alloc: Alloc, err: []const u8, status: std.http.Status) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "Change the session secret", "");
    try b.appendSlice(alloc,
        \\<p>Do this when the secret may have leaked: a backup lost or copied, a machine gone. Whoever has it can
        \\sign in as anyone until it changes.</p>
        \\<ul><li>Every member's session ends at once, yours too. Members log in again with their passwords.</li>
        \\<li>Players have no password. Their cookies are renewed on their next visit for the days you give; after
        \\that, a player who has not come back is not recognised. 0 days carries no one over.</li></ul>
        \\
    );
    if (err.len != 0) try b.print(alloc, "<p class=\"err\">{s}</p>\n", .{try html.htmlEscape(alloc, err)});
    try b.appendSlice(alloc,
        \\<form method="post" action="/admin/secret">
        \\<label>Days players' cookies are still renewed <input name="days" value="7" size="3"></label><br>
        \\<label>Password <input type="password" name="password"></label>
        \\<button type="submit">Change the secret</button>
        \\</form>
        \\
    );
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .status = status, .extra_headers = &.{http.html_ct} });
}
