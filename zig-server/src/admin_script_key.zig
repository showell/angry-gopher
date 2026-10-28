//! admin_script_key: /admin/script-key, the script route's public key and
//! target (metal-vmm QUEUE 200), set the way the session secret is: the
//! admin's page, and the admin's password typed again (a session or the
//! bearer alone is not enough). zig-metal-unikernel has no shell, so this is
//! how `{auth}/shale.conf` reaches the volume.
//!
//! **WHY A PASSWORD, NOT THE BEARER**: the script route's two locks are the
//! bearer and the signature. A bearer that leaked must not be able to put
//! its own key here and sign for itself; the password is a third thing,
//! never sent by the signer or kept on the box.

const std = @import("std");
const limits = @import("limits.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const webbox = @import("webbox");
const http = webbox.http;
const html = webbox.html;
const script_route = @import("shale").script_route;
const users = @import("users.zig");
const ui = @import("admin_ui.zig");
const throttle = @import("login_throttle.zig");

const Request = std.http.Server.Request;

pub fn render(req: *Request, io: Io, alloc: Alloc, client: ?[]const u8) !void {
    if (req.head.method != .POST) return form(req, io, alloc, "", .ok);
    if (throttle.check(io, client, ui.admin_uid)) |b| return form(req, io, alloc, b.text(), .too_many_requests);
    const sent = (try http.readLimitedBody(req, alloc, limits.body.secret_form)) orelse return;
    const password = (try http.formField(alloc, sent, "password")) orelse "";
    if (!try users.checkUserPassword(io, alloc, ui.admin_uid, password)) {
        throttle.recordFailure(io, client, ui.admin_uid);
        return form(req, io, alloc, "That is not the password.", .forbidden);
    }
    throttle.clearAddress(client);
    const key = std.mem.trim(u8, (try http.formField(alloc, sent, "public_key")) orelse "", " \t\r\n");
    const target = std.mem.trim(u8, (try http.formField(alloc, sent, "target")) orelse "", " \t\r\n");
    const prefix = "public_key = ";
    const key_hex = if (std.mem.startsWith(u8, key, prefix)) key[prefix.len..] else key;
    const text = try std.fmt.allocPrint(alloc, "public_key = {s}\ntarget = {s}\n", .{ key_hex, target });
    _ = script_route.parseConfig(text) catch
        return form(req, io, alloc, "The key is 64 hex digits (shale-sign pubkey prints it), and the target a host name (a-z 0-9 . -).", .bad_request);
    const paths = try script_route.Paths.under(alloc, webbox.store.auth_base orelse users.auth_root);
    // The sequence rises to the clock's seconds with the key: nothing
    // signed before now runs after, even if the old sequence was lost.
    const floor: u64 = @intCast(@max(0, @divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s)));
    script_route.installKey(io, alloc, paths, text, floor) catch |e| {
        if (e == error.ReadOnlyFileSystem) return e;
        return form(req, io, alloc, try std.fmt.allocPrint(alloc, "The key was not set: {s}.", .{@errorName(e)}), .internal_server_error);
    };
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "The script key is set", "");
    try b.print(alloc, "<p>Scripts signed by that key for <b>{s}</b> run here now, sent with the admin's API key to <code>POST /admin/script</code>.</p>\n", .{try html.htmlEscape(alloc, target)});
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

fn form(req: *Request, io: Io, alloc: Alloc, err: []const u8, status: std.http.Status) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "The script key", "");
    const paths = try script_route.Paths.under(alloc, webbox.store.auth_base orelse users.auth_root);
    // absent-ok: a page that only says whether a key is set; the route refuses a config it cannot read.
    const now_set = (webbox.store.readOrNull(io, alloc, paths.config, .limited(4096)) catch null) != null;
    try b.print(alloc,
        \\<p>The public key that signed scripts are checked against, and the name they must be signed for.
        \\{s}</p>
        \\<p>On the box, in the shale checkout: <code>zig build shale-sign -- keygen</code> once, then <code>pubkey</code> prints the key.
        \\The private key never leaves the box.</p>
        \\
    , .{if (now_set) "A key is set; this replaces it." else "No key is set: the script route refuses every request."});
    if (err.len != 0) try b.print(alloc, "<p class=\"err\">{s}</p>\n", .{try html.htmlEscape(alloc, err)});
    try b.appendSlice(alloc,
        \\<form method="post" action="/admin/script-key">
        \\<label>Public key <input name="public_key" size="70"></label><br>
        \\<label>Target <input name="target" value="lynrummy.com" size="30"></label><br>
        \\<label>Password <input type="password" name="password"></label>
        \\<button type="submit">Set the key</button>
        \\</form>
        \\
    );
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .status = status, .extra_headers = &.{http.html_ct} });
}
