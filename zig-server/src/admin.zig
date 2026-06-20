//! admin: /admin — a filesystem view of per-player on-disk data plus member
//! management. Go gates this ADMIN_ONLY via the
//! user's Admin flag; per Steve the port hardcodes admin = uid 1 (him, on prod
//! and locally) until an admin flag is ported. No DB — it walks {data_root}/
//! <user>/ directly (also the on-disk partition layout). Read-only stats plus two
//! guarded actions: delete a player's game data, and generate/revoke a member's
//! API key.
//!
//!   GET  /admin                 the overview (members table + per-player stats)
//!   GET  /admin/delete?user=ID  the "are you sure" confirm page
//!   POST /admin/delete          delete that player's game-data subtree
//!   POST /admin/apikey          generate (or revoke=1) a member's API key

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const users = @import("users.zig");
const storage = @import("storage.zig");
const chat = @import("chat.zig");
const settings = @import("settings.zig");

const Request = std.http.Server.Request;

/// admin_uid is the sole admin. Go reads the principal's Admin flag; the port
/// hardcodes Steve's uid 1 (per his call) until that flag is ported.
const admin_uid = "1";

/// handle dispatches /admin* — `sub` is the path after "/admin".
pub fn handle(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0) return http.redirect(req, "/login");
    if (!std.mem.eql(u8, uid, admin_uid)) return http.notFound(req); // ADMIN_ONLY

    if (std.mem.eql(u8, sub, "/delete")) return handleDelete(req, io, alloc);
    if (std.mem.eql(u8, sub, "/apikey")) return handleAPIKey(req, io, alloc);
    return renderOverview(req, io, alloc);
}

// ── actions ───────────────────────────────────────────────────────────────────

/// handleDelete confirms (GET) and performs (POST) deletion of one player's
/// on-disk game data, by user id.
fn handleDelete(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method == .POST) {
        const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
        const id = std.mem.trim(u8, (try chat.formField(alloc, body, "user")) orelse "", " \t\r\n");
        if (id.len == 0 or !users.principalExists(io, alloc, id)) return http.redirect(req, "/admin");
        storage.deleteUserData(io, alloc, id) catch return req.respond("delete failed\n", .{ .status = .internal_server_error });
        return http.redirect(req, try std.fmt.allocPrint(alloc, "/admin?deleted={s}", .{id}));
    }
    const id = std.mem.trim(u8, queryValue(req.head.target, "user") orelse "", " \t\r\n");
    if (id.len == 0 or !users.principalExists(io, alloc, id)) return http.redirect(req, "/admin");
    return renderDeleteConfirm(req, io, alloc, id);
}

/// handleAPIKey generates (POST) or revokes (POST revoke=1) a member's API key —
/// the admin acting on any member.
fn handleAPIKey(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method != .POST) return http.redirect(req, "/admin");
    const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
    const id = std.mem.trim(u8, (try chat.formField(alloc, body, "user")) orelse "", " \t\r\n");
    if (id.len == 0 or !users.principalExists(io, alloc, id) or !users.principalAuthorized(io, alloc, id)) {
        return http.redirect(req, "/admin");
    }
    const revoke = (try chat.formField(alloc, body, "revoke")) orelse "";
    if (std.mem.eql(u8, revoke, "1")) {
        users.clearUserAPIKey(io, alloc, id);
        return http.redirect(req, try std.fmt.allocPrint(alloc, "/admin?keyrevoked={s}", .{id}));
    }
    const key = try users.setUserAPIKey(io, alloc, id);
    return settings.renderKeyShown(req, io, alloc, id, key, "/admin", "Admin");
}

// ── overview ───────────────────────────────────────────────────────────────────

const UserStats = struct {
    id: []const u8,
    name: []const u8,
    game_sessions: i64,
    puzzle_sessions: i64,
    total_actions: i64,
    disk_bytes: i64,
};

fn renderOverview(req: *Request, io: Io, alloc: Alloc) !void {
    const ids = try users.listUserIDs(io, alloc);

    var grand = UserStats{ .id = "", .name = "All players", .game_sessions = 0, .puzzle_sessions = 0, .total_actions = 0, .disk_bytes = 0 };
    var rows: std.ArrayList(UserStats) = .empty;
    for (ids) |id| {
        const st = gatherUserStats(io, alloc, id);
        try rows.append(alloc, st);
        grand.game_sessions += st.game_sessions;
        grand.puzzle_sessions += st.puzzle_sessions;
        grand.total_actions += st.total_actions;
        grand.disk_bytes += st.disk_bytes;
    }

    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, overview_head);

    // Flash (delete / key-revoke confirmations), keyed by uid in the query.
    if (queryValue(req.head.target, "deleted")) |d| {
        const name = try chat.htmlEscape(alloc, try users.getUserName(io, alloc, d));
        try b.print(alloc, "<p class=\"flash\">Deleted game data for <strong>{s}</strong>.</p>", .{name});
    } else if (queryValue(req.head.target, "keyrevoked")) |k| {
        const name = try chat.htmlEscape(alloc, try users.getUserName(io, alloc, k));
        try b.print(alloc, "<p class=\"flash\">Revoked the API key for <strong>{s}</strong>.</p>", .{name});
    }

    try renderMembersTable(&b, io, alloc);

    try b.print(alloc, "<h2>Sessions per player</h2>\n<p class=\"muted\">Read straight from {s}.</p>\n<table>\n" ++
        "<tr><th>Player</th><th class=\"n\">Games</th><th class=\"n\">Puzzles</th><th class=\"n\">Actions</th><th class=\"n\">Disk</th><th></th></tr>", .{
        try chat.htmlEscape(alloc, storage.data_root),
    });

    if (rows.items.len == 0) {
        try b.appendSlice(alloc, "<tr><td colspan=\"6\" class=\"muted\">No players yet.</td></tr>");
    }
    for (rows.items) |st| {
        const del = try std.fmt.allocPrint(alloc, "<a class=\"del\" href=\"/admin/delete?user={s}\">Delete sessions</a>", .{st.id});
        try writeStatsRow(&b, alloc, st, "", del);
    }
    if (rows.items.len > 1) try writeStatsRow(&b, alloc, grand, "total", "");
    try b.appendSlice(alloc, "</table></body></html>");

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
            .is_admin = std.mem.eql(u8, m.id, admin_uid),
            .is_agent = users.principalIsAgent(m.id),
            .last_seen = users.userLastSeen(io, alloc, m.id),
        });
    }
    // Active-ever sorts above never-active; among active, most-recent first.
    // Insertion sort = stable (Go uses SliceStable), and the roster is tiny.
    std.sort.insertion(MemberRow, rows.items, {}, memberLessThan);

    try b.appendSlice(alloc, member_table_head);
    if (rows.items.len == 0) {
        try b.appendSlice(alloc, "<tr><td colspan=\"4\" class=\"muted\">No members yet.</td></tr>");
    }
    const now = nowUnix(io);
    for (rows.items) |row| {
        var name = try chat.htmlEscape(alloc, row.name);
        if (row.is_admin) name = try std.fmt.allocPrint(alloc, "{s} <span class=\"muted\">(admin)</span>", .{name});
        if (row.is_agent) name = try std.fmt.allocPrint(alloc, "{s} <span class=\"muted\">(agent)</span>", .{name});
        const since = if (row.last_seen) |t| try humanizeSince(alloc, now - t) else "never";
        const images = try std.fmt.allocPrint(alloc, "{s} / {s}", .{
            try humanBytes(alloc, users.userUploadBytes(io, alloc, row.id)),
            try humanBytes(alloc, users.max_upload_lifetime_bytes),
        });
        try b.print(alloc, "<tr><td>{s}</td><td>{s}</td><td class=\"n\">{s}</td><td>", .{ name, since, images });
        try appendApiKeyCell(b, io, alloc, row.id);
        try b.appendSlice(alloc, "</td></tr>");
    }
    try b.appendSlice(alloc, "</table>");
}

fn memberLessThan(_: void, a: MemberRow, b: MemberRow) bool {
    const a_ever = a.last_seen != null;
    const b_ever = b.last_seen != null;
    if (a_ever != b_ever) return a_ever; // active-ever first
    if (!a_ever) return false; // both never-active — preserve order
    return a.last_seen.? > b.last_seen.?; // most-recent first
}

/// appendApiKeyCell writes the API-key controls for one member: Generate (becomes
/// Regenerate + Revoke once a key exists), all POSTing to /admin/apikey.
fn appendApiKeyCell(b: *std.ArrayList(u8), io: Io, alloc: Alloc, id: []const u8) !void {
    const has = users.userHasAPIKey(io, alloc, id);
    const gen = if (has) "Regenerate" else "Generate";
    const esc = try chat.htmlEscape(alloc, id);
    try b.print(alloc, "<form class=\"inline\" method=\"post\" action=\"/admin/apikey\">" ++
        "<input type=\"hidden\" name=\"user\" value=\"{s}\">" ++
        "<button class=\"key\" type=\"submit\">{s}</button></form>", .{ esc, gen });
    if (has) {
        try b.print(alloc, " <form class=\"inline\" method=\"post\" action=\"/admin/apikey\">" ++
            "<input type=\"hidden\" name=\"user\" value=\"{s}\"><input type=\"hidden\" name=\"revoke\" value=\"1\">" ++
            "<button class=\"key revoke\" type=\"submit\">Revoke</button></form>", .{esc});
    }
}

fn writeStatsRow(b: *std.ArrayList(u8), alloc: Alloc, st: UserStats, cls: []const u8, actions_cell: []const u8) !void {
    const row_class = if (cls.len != 0) try std.fmt.allocPrint(alloc, " class=\"{s}\"", .{cls}) else "";
    try b.print(alloc, "<tr{s}><td>{s}</td><td class=\"n\">{d}</td><td class=\"n\">{d}</td><td class=\"n\">{d}</td><td class=\"n\">{s}</td><td>{s}</td></tr>", .{
        row_class,            try chat.htmlEscape(alloc, st.name),
        st.game_sessions,     st.puzzle_sessions,
        st.total_actions,     try humanBytes(alloc, st.disk_bytes),
        actions_cell,
    });
}

/// renderDeleteConfirm is the "are you sure" page — it spells out exactly what
/// will be removed before the POST that does it.
fn renderDeleteConfirm(req: *Request, io: Io, alloc: Alloc, id: []const u8) !void {
    const st = gatherUserStats(io, alloc, id);
    const name = try chat.htmlEscape(alloc, try users.getUserName(io, alloc, id));
    const disk = try humanBytes(alloc, st.disk_bytes);
    const page = try std.fmt.allocPrint(alloc, delete_confirm_template, .{
        name, st.game_sessions, st.puzzle_sessions, st.total_actions, disk, try chat.htmlEscape(alloc, id),
    });
    try req.respond(page, .{ .extra_headers = &.{http.html_ct} });
}

// ── stats (walk {data_root}/<user>/ directly) ────────────────────────────────

/// gatherUserStats walks one player's subtree for game/puzzle session counts,
/// total action lines, and disk bytes.
fn gatherUserStats(io: Io, alloc: Alloc, id: []const u8) UserStats {
    const uroot = storage.userDataDir(alloc, id) catch return zeroStats(id);
    const games_dir = std.fs.path.join(alloc, &.{ uroot, "lynrummy-elm", "sessions" }) catch return zeroStats(id);
    const puzzles_dir = std.fs.path.join(alloc, &.{ uroot, "puzzle", "sessions" }) catch return zeroStats(id);

    var st = UserStats{
        .id = id,
        .name = users.getUserName(io, alloc, id) catch "",
        .game_sessions = countSubdirs(io, games_dir),
        .puzzle_sessions = countSubdirs(io, puzzles_dir),
        .total_actions = 0,
        .disk_bytes = dirBytes(io, alloc, uroot),
    };
    // Total actions = nonempty lines across every game session's actions.dsl.
    if (Io.Dir.cwd().openDir(io, games_dir, .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const dsl = std.fs.path.join(alloc, &.{ games_dir, entry.name, "actions.dsl" }) catch continue;
            st.total_actions += countTextLines(io, alloc, dsl);
        }
    } else |_| {}
    return st;
}

fn zeroStats(id: []const u8) UserStats {
    return .{ .id = id, .name = "", .game_sessions = 0, .puzzle_sessions = 0, .total_actions = 0, .disk_bytes = 0 };
}

/// countSubdirs counts immediate subdirectories of `dir_path` (0 if missing).
fn countSubdirs(io: Io, dir_path: []const u8) i64 {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: i64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) n += 1;
    }
    return n;
}

/// dirBytes sums the sizes of every regular file under `path` (recursive; missing
/// dir → 0).
fn dirBytes(io: Io, alloc: Alloc, path: []const u8) i64 {
    var total: i64 = 0;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = std.fs.path.join(alloc, &.{ path, entry.name }) catch continue;
        if (entry.kind == .directory) {
            total += dirBytes(io, alloc, child);
        } else {
            const st = Io.Dir.cwd().statFile(io, child, .{}) catch continue;
            total += @intCast(st.size);
        }
    }
    return total;
}

/// countTextLines counts nonempty lines in `path` (0 if missing).
fn countTextLines(io: Io, alloc: Alloc, path: []const u8) i64 {
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return 0;
    var n: i64 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

// ── format helpers ─────────────────────────────────────────────────────────────

/// humanizeSince renders elapsed seconds as a coarse relative string ("just now",
/// "Nm ago", "Nh ago", "Nd ago").
fn humanizeSince(alloc: Alloc, elapsed_s: i64) ![]const u8 {
    const d = if (elapsed_s < 0) 0 else elapsed_s;
    if (d < 60) return "just now";
    if (d < 3600) return std.fmt.allocPrint(alloc, "{d}m ago", .{@divTrunc(d, 60)});
    if (d < 86400) return std.fmt.allocPrint(alloc, "{d}h ago", .{@divTrunc(d, 3600)});
    return std.fmt.allocPrint(alloc, "{d}d ago", .{@divTrunc(d, 86400)});
}

/// humanBytes renders a byte count as "N B" / "N.N {K,M,G,…}B" (1024-based).
fn humanBytes(alloc: Alloc, n: i64) ![]const u8 {
    const unit: i64 = 1024;
    if (n < unit) return std.fmt.allocPrint(alloc, "{d} B", .{n});
    var div: i64 = unit;
    var exp: usize = 0;
    var x = @divTrunc(n, unit);
    while (x >= unit) : (x = @divTrunc(x, unit)) {
        div *= unit;
        exp += 1;
    }
    const val = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(div));
    return std.fmt.allocPrint(alloc, "{d:.1} {c}B", .{ val, "KMGTPE"[exp] });
}

fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

// ── verbatim Go markup (admin.go) ─────────────────────────────────────────────

const overview_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 40px; max-width: 880px; }
    \\h1 { color: #000080; }
    \\h2 { color: #000080; font-size: 18px; margin-top: 32px; }
    \\nav { font-size: 13px; margin-bottom: 16px; }
    \\nav a { color: #000080; }
    \\table { border-collapse: collapse; width: 100%; margin-top: 12px; }
    \\th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
    \\td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
    \\tr:hover td { background: #f0f0ff; }
    \\.n { text-align: right; font-variant-numeric: tabular-nums; }
    \\.total td { font-weight: bold; border-top: 2px solid #000080; background: #f4f4ec; }
    \\.muted { color: #888; }
    \\.flash { background: #c6f6c6; color: #1a7a3a; padding: 8px 12px; border-radius: 4px; }
    \\a.del { color: #b00020; text-decoration: none; }
    \\a.del:hover { text-decoration: underline; }
    \\form.inline { display: inline; margin: 0; }
    \\button.key { background: #000080; color: white; border: none; padding: 3px 9px;
    \\             font-size: 12px; border-radius: 4px; cursor: pointer; }
    \\button.key:hover { background: #0000a0; }
    \\button.key.revoke { background: #b00020; }
    \\button.key.revoke:hover { background: #8a0019; }
    \\</style>
    \\</head><body>
    \\<nav><a href="/">← Home</a></nav>
    \\<h1>🐹 Angry Gopher Admin</h1>
    \\
;

const member_table_head =
    \\<h2>Official users</h2>
    \\<p class="muted">Members (password holders): time since last activity, lifetime image-upload total (vs the per-user cap), and a bot API key (acts as the member, no admin).</p>
    \\<table>
    \\<tr><th>Name</th><th>Last active</th><th class="n">Images</th><th>API key</th></tr>
;

// delete_confirm_template — Go's renderDeleteConfirm. Args: name, games, puzzles,
// actions, disk, id. {{ }} escape the CSS braces for std.fmt.
const delete_confirm_template =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body {{ font-family: sans-serif; margin: 40px; max-width: 560px; }}
    \\h1 {{ color: #000080; }}
    \\nav {{ font-size: 13px; margin-bottom: 16px; }}
    \\nav a, .cancel {{ color: #000080; }}
    \\.warn {{ color: #b00020; }}
    \\.box {{ background: #f4f4ec; border: 1px solid #ccc; border-radius: 6px; padding: 4px 20px 20px; }}
    \\button.danger {{ background: #b00020; color: white; border: none; padding: 10px 18px;
    \\                font-size: 15px; border-radius: 4px; cursor: pointer; }}
    \\button.danger:hover {{ background: #8a0019; }}
    \\.cancel {{ margin-left: 16px; }}
    \\</style>
    \\</head><body>
    \\<nav><a href="/admin">← Admin</a></nav>
    \\<h1>Delete sessions for &ldquo;{s}&rdquo;?</h1>
    \\<div class="box">
    \\<p>This permanently removes <strong>all</strong> on-disk data for this player:</p>
    \\<p><strong>{d}</strong> games · <strong>{d}</strong> puzzles · {d} actions · {s} on disk</p>
    \\<p class="warn">This cannot be undone. (They can log in again later; a fresh, empty history is created.)</p>
    \\<form method="post" action="/admin/delete">
    \\  <input type="hidden" name="user" value="{s}">
    \\  <button type="submit" class="danger">Yes, delete</button>
    \\  <a class="cancel" href="/admin">Cancel</a>
    \\</form>
    \\</div>
    \\</body></html>
;
