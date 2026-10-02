//! admin: /admin — the CHAT roster. Members and agents: who they are, when they
//! were last here, what they have uploaded against the cap, and their bot API
//! key. Admin-only.
//!
//!   GET  /admin          the roster
//!   POST /admin/apikey   generate (or revoke=1) a member's API key
//!   GET  /admin/host     the running server: admin_host.zig
//!
//! The GAME roster — players, sessions, disk, delete — is a separate screen at
//! /admin/lynrummy (admin_lynrummy.zig), and the two cross-link. They were one
//! page, which meant this one walked `{data_root}` for a stats column: the only
//! place a chat module imported the game store. Now each screen asks its own
//! subject, and the shell and the gate they share live in admin_ui.zig.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const users = @import("users.zig");
const chat = @import("chat.zig");
const html = @import("html.zig");
const settings = @import("settings.zig");
const ui = @import("admin_ui.zig");
const admin_host = @import("admin_host.zig");
const admin_backup = @import("admin_backup.zig");

const Request = std.http.Server.Request;

/// handle dispatches /admin* — `sub` is the path after "/admin".
pub fn handle(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    if (!try ui.requireAdmin(req, io, alloc)) return;
    if (std.mem.eql(u8, sub, "/apikey")) return handleAPIKey(req, io, alloc);
    if (std.mem.eql(u8, sub, "/host")) return admin_host.render(req, io, alloc);
    if (std.mem.eql(u8, sub, "/backup")) return admin_backup.render(req, io, alloc);
    if (sub.len != 0 and !std.mem.eql(u8, sub, "/")) return http.notFound(req);
    return renderRoster(req, io, alloc);
}

// ── actions ──────────────────────────────────────────────────────────────────

/// handleAPIKey generates (POST) or revokes (POST revoke=1) a member's API key —
/// the admin acting on any member.
fn handleAPIKey(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method != .POST) return http.redirect(req, "/admin");
    const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
    const id = std.mem.trim(u8, (try chat.formField(alloc, body, "user")) orelse "", " \t\r\n");
    if (!apiKeyTarget(io, alloc, id)) return http.redirect(req, "/admin");
    const revoke = (try chat.formField(alloc, body, "revoke")) orelse "";
    if (std.mem.eql(u8, revoke, "1")) {
        users.clearUserAPIKey(io, alloc, id);
        return http.redirect(req, try std.fmt.allocPrint(alloc, "/admin?keyrevoked={s}", .{id}));
    }
    const key = try users.setUserAPIKey(io, alloc, id);
    return settings.renderKeyShown(req, io, alloc, id, key, "/admin", "Admin");
}

/// **AN ID FROM A FORM IS A UID BEFORE IT IS A PATH.** The key is written to
/// and removed from {auth_root}/<id>/api-key, and principalExists and
/// principalAuthorized look at what is on disk, not at the characters: `1/.`
/// or `1/../2` passed both and named a folder (gopher-metal's
/// REVIEW-request-paths.md, finding 5).
fn apiKeyTarget(io: Io, alloc: Alloc, id: []const u8) bool {
    return users.validUid(id) and users.principalExists(io, alloc, id) and users.principalAuthorized(io, alloc, id);
}

/// The name the revoked-key flash shows, or null for an id that is not a uid
/// (the query is raw, so it could hold a path that reads another `name`).
fn revokedName(io: Io, alloc: Alloc, id: []const u8) !?[]const u8 {
    if (!users.validUid(id)) return null;
    return try users.getUserName(io, alloc, id);
}

// ── the roster ───────────────────────────────────────────────────────────────

fn renderRoster(req: *Request, io: Io, alloc: Alloc) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "🐹 Angry Gopher members", "/admin");

    if (http.queryValue(try http.target(req, alloc), "keyrevoked")) |k| {
        if (try revokedName(io, alloc, k)) |n| {
            const name = try html.htmlEscape(alloc, n);
            try b.print(alloc, "<p class=\"flash\">Revoked the API key for <strong>{s}</strong>.</p>", .{name});
        }
    }

    try renderMembersTable(&b, io, alloc);
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

const MemberRow = struct { id: []const u8, name: []const u8, is_admin: bool, is_agent: bool, last_seen: ?i64 };

/// renderMembersTable lists the official principals (members + agents) with time
/// since last active (most-recent first; never-active last), lifetime image total
/// vs the cap, and per-member API-key controls.
fn renderMembersTable(b: *std.ArrayList(u8), io: Io, alloc: Alloc) !void {
    var rows: std.ArrayList(MemberRow) = .empty;
    for (try users.listAuthorized(io, alloc)) |m| {
        try rows.append(alloc, .{
            .id = m.id,
            .name = m.name,
            .is_admin = std.mem.eql(u8, m.id, ui.admin_uid),
            .is_agent = users.principalIsAgent(m.id),
            .last_seen = users.userLastSeen(io, alloc, m.id),
        });
    }
    // Active-ever sorts above never-active; among active, most-recent first.
    // Insertion sort = stable, and the roster is tiny.
    std.sort.insertion(MemberRow, rows.items, {}, memberLessThan);

    try b.appendSlice(alloc, member_table_head);
    if (rows.items.len == 0) {
        try b.appendSlice(alloc, "<tr><td colspan=\"4\" class=\"muted\">No members yet.</td></tr>");
    }
    const now = ui.nowUnix(io);
    for (rows.items) |row| {
        var name = try html.htmlEscape(alloc, row.name);
        if (row.is_admin) name = try std.fmt.allocPrint(alloc, "{s} <span class=\"muted\">(admin)</span>", .{name});
        if (row.is_agent) name = try std.fmt.allocPrint(alloc, "{s} <span class=\"muted\">(agent)</span>", .{name});
        const since = try ui.sinceOrNever(alloc, now, row.last_seen);
        const images = try std.fmt.allocPrint(alloc, "{s} / {s}", .{
            try ui.humanBytes(alloc, users.userUploadBytes(io, alloc, row.id)),
            try ui.humanBytes(alloc, users.max_upload_lifetime_bytes),
        });
        try b.print(alloc, "<tr><td>{s}</td><td>{s}</td><td class=\"n\">{s}</td><td>", .{ name, since, images });
        try appendApiKeyCell(b, io, alloc, row.id);
        try b.appendSlice(alloc, "</td></tr>");
    }
    try b.appendSlice(alloc, "</table>");
}

fn memberLessThan(_: void, a: MemberRow, b: MemberRow) bool {
    return ui.mostRecentFirst(a.last_seen, b.last_seen);
}

/// appendApiKeyCell writes the API-key controls for one member: Generate (becomes
/// Regenerate + Revoke once a key exists), all POSTing to /admin/apikey.
fn appendApiKeyCell(b: *std.ArrayList(u8), io: Io, alloc: Alloc, id: []const u8) !void {
    const has = users.userHasAPIKey(io, alloc, id);
    const gen = if (has) "Regenerate" else "Generate";
    const esc = try html.htmlEscape(alloc, id);
    try b.print(alloc, "<form class=\"inline\" method=\"post\" action=\"/admin/apikey\">" ++
        "<input type=\"hidden\" name=\"user\" value=\"{s}\">" ++
        "<button class=\"key\" type=\"submit\">{s}</button></form>", .{ esc, gen });
    if (has) {
        try b.print(alloc, " <form class=\"inline\" method=\"post\" action=\"/admin/apikey\">" ++
            "<input type=\"hidden\" name=\"user\" value=\"{s}\"><input type=\"hidden\" name=\"revoke\" value=\"1\">" ++
            "<button class=\"key revoke\" type=\"submit\">Revoke</button></form>", .{esc});
    }
}

// ── page markup ──────────────────────────────────────────────────────────────

const member_table_head =
    \\<h2>Official users</h2>
    \\<p class="muted">Members (password holders): time since last activity, lifetime image-upload total (vs the per-user cap), and a bot API key (acts as the member, no admin).</p>
    \\<table>
    \\<tr><th>Name</th><th>Last active</th><th class="n">Images</th><th>API key</th></tr>
;

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const store = @import("store.zig");

test "fs: the admin's key form and revoked flash take uids only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = users.auth_root;
    defer users.auth_root = saved;
    users.auth_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "auth" });

    // Members 1 and 2, each with a password and a name.
    for ([_][]const u8{ "1", "2" }) |id| {
        try store.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, id, "password" }), "x", .{});
        try store.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, id, "name" }), id, .{});
    }
    try testing.expect(apiKeyTarget(io, a, "1"));
    try testing.expect(!apiKeyTarget(io, a, "9")); // no such member
    // Paths that name member folders by another spelling.
    for ([_][]const u8{ "1/.", "1/../2", "./1", "" }) |id| {
        try testing.expect(!apiKeyTarget(io, a, id));
        try testing.expect((try revokedName(io, a, id)) == null);
    }
    try testing.expectEqualStrings("2", (try revokedName(io, a, "2")).?);
}
