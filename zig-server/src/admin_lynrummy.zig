//! admin_lynrummy: /admin/lynrummy — the GAME roster. Every player, what they
//! have on disk, and the one destructive action (delete a player's game data).
//!
//! It reads two things and nothing else: the PLAYER store for who exists
//! (player.zig), and `{data_root}/<id>/` for what they have. No DB — the
//! directory walk IS the query, and the on-disk layout is the schema:
//!
//!   {data_root}/<id>/lynrummy-elm/sessions/<n>/actions.dsl   a game
//!   {data_root}/<id>/puzzle/sessions/<n>/                    a puzzle session
//!
//!   GET  /admin/lynrummy                 the roster
//!   GET  /admin/lynrummy/delete?user=ID  the "are you sure" confirm page
//!   POST /admin/lynrummy/delete          delete that player's game-data subtree
//!
//! **THIS USED TO BE HALF OF /admin, AND THAT COST SOMETHING.** The chat admin
//! walked the game store for a stats column, which was the only place a chat
//! module imported `storage`. The rosters were also drawn from different sets —
//! the members table from the account store, the "name-only" table from
//! password-less accounts, which stopped growing the moment player.zig replaced
//! the guest login. One screen per subject fixes both: this one asks the player
//! store, and it is the complete answer, because the seed brought the old
//! account names across and a chat member who logs in is mirrored in.
//!
//! The gate is `admin_ui.requireAdmin`, and where it should live once the
//! surfaces separate is the open question written up in that file.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const html = @import("html.zig");
const player = @import("player.zig");
const storage = @import("storage.zig");
const ui = @import("admin_ui.zig");

const Request = std.http.Server.Request;

/// handle dispatches /admin/lynrummy* — `sub` is the path after it.
pub fn handle(req: *Request, io: Io, alloc: Alloc, sub: []const u8) !void {
    if (!try ui.requireAdmin(req, io, alloc)) return;
    if (std.mem.eql(u8, sub, "/delete")) return handleDelete(req, io, alloc);
    if (sub.len != 0 and !std.mem.eql(u8, sub, "/")) return http.notFound(req);
    return renderRoster(req, io, alloc);
}

const self_url = "/admin/lynrummy";

// ── the one destructive action ───────────────────────────────────────────────

/// handleDelete confirms (GET) and performs (POST) deletion of one player's
/// on-disk game data. The player's row in the identity store is left alone: this
/// deletes what they PLAYED, not who they are.
fn handleDelete(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method == .POST) {
        const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
        const id = std.mem.trim(u8, (try formField(alloc, body, "user")) orelse "", " \t\r\n");
        if (!try exists(io, alloc, id)) return http.redirect(req, self_url);
        storage.deleteUserData(io, alloc, id) catch return req.respond("delete failed\n", .{ .status = .internal_server_error });
        return http.redirect(req, try std.fmt.allocPrint(alloc, self_url ++ "?deleted={s}", .{id}));
    }
    const id = std.mem.trim(u8, http.queryValue(try http.target(req, alloc), "user") orelse "", " \t\r\n");
    if (!try exists(io, alloc, id)) return http.redirect(req, self_url);
    return renderDeleteConfirm(req, io, alloc, id);
}

/// exists is the guard every id from a form or a query passes through: a player
/// we know, never a path someone typed.
fn exists(io: Io, alloc: Alloc, id: []const u8) !bool {
    if (id.len == 0) return false;
    return (try player.nameOf(io, alloc, id)).len != 0;
}

// ── the roster ───────────────────────────────────────────────────────────────

const PlayerStats = struct {
    id: []const u8,
    name: []const u8,
    last_seen: ?i64,
    game_sessions: i64,
    puzzle_sessions: i64,
    total_actions: i64,
    disk_bytes: i64,
};

fn renderRoster(req: *Request, io: Io, alloc: Alloc) !void {
    var rows: std.ArrayList(PlayerStats) = .empty;
    var grand = PlayerStats{ .id = "", .name = "All players", .last_seen = null, .game_sessions = 0, .puzzle_sessions = 0, .total_actions = 0, .disk_bytes = 0 };
    for (try player.list(io, alloc)) |p| {
        const st = gatherStats(io, alloc, p);
        try rows.append(alloc, st);
        grand.game_sessions += st.game_sessions;
        grand.puzzle_sessions += st.puzzle_sessions;
        grand.total_actions += st.total_actions;
        grand.disk_bytes += st.disk_bytes;
    }
    std.sort.insertion(PlayerStats, rows.items, {}, byRecency);

    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "🐹 Lyn Rummy players", self_url);

    // Flash, keyed by the id in the query.
    if (http.queryValue(try http.target(req, alloc), "deleted")) |d| {
        try b.print(alloc, "<p class=\"flash\">Deleted game data for <strong>{s}</strong>.</p>", .{
            try html.htmlEscape(alloc, d),
        });
    }

    try b.print(alloc, roster_head, .{try html.htmlEscape(alloc, storage.data_root)});
    if (rows.items.len == 0) {
        try b.appendSlice(alloc, "<tr><td colspan=\"7\" class=\"muted\">No players yet.</td></tr>");
    }
    const now = ui.nowUnix(io);
    for (rows.items) |st| {
        const del = try std.fmt.allocPrint(alloc, "<a class=\"del\" href=\"" ++ self_url ++ "/delete?user={s}\">Delete sessions</a>", .{
            try html.htmlEscape(alloc, st.id),
        });
        try writeRow(&b, alloc, st, "", try ui.sinceOrNever(alloc, now, st.last_seen), del);
    }
    if (rows.items.len > 1) try writeRow(&b, alloc, grand, "total", "", "");
    try b.appendSlice(alloc, "</table>");
    try ui.end(&b, alloc);

    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

fn byRecency(_: void, a: PlayerStats, b: PlayerStats) bool {
    return ui.mostRecentFirst(a.last_seen, b.last_seen);
}

fn writeRow(b: *std.ArrayList(u8), alloc: Alloc, st: PlayerStats, cls: []const u8, since: []const u8, actions_cell: []const u8) !void {
    const row_class = if (cls.len != 0) try std.fmt.allocPrint(alloc, " class=\"{s}\"", .{cls}) else "";
    const who = if (st.id.len == 0)
        try html.htmlEscape(alloc, st.name)
    else
        try std.fmt.allocPrint(alloc, "{s} <span class=\"muted\">#{s}</span>", .{
            try html.htmlEscape(alloc, st.name), try html.htmlEscape(alloc, st.id),
        });
    try b.print(alloc, "<tr{s}><td>{s}</td><td>{s}</td><td class=\"n\">{d}</td><td class=\"n\">{d}</td>" ++
        "<td class=\"n\">{d}</td><td class=\"n\">{s}</td><td>{s}</td></tr>", .{
        row_class,        who,
        since,            st.game_sessions,
        st.puzzle_sessions, st.total_actions,
        try ui.humanBytes(alloc, st.disk_bytes), actions_cell,
    });
}

/// renderDeleteConfirm is the "are you sure" page — it spells out exactly what
/// will be removed before the POST that does it.
fn renderDeleteConfirm(req: *Request, io: Io, alloc: Alloc, id: []const u8) !void {
    const st = gatherStats(io, alloc, .{ .id = id, .name = try player.nameOf(io, alloc, id) });
    const page = try std.fmt.allocPrint(alloc, delete_confirm_template, .{
        try html.htmlEscape(alloc, st.name),
        st.game_sessions,
        st.puzzle_sessions,
        st.total_actions,
        try ui.humanBytes(alloc, st.disk_bytes),
        try html.htmlEscape(alloc, id),
    });
    try req.respond(page, .{ .extra_headers = &.{http.html_ct} });
}

// ── stats: the directory walk IS the query ───────────────────────────────────

/// gatherStats walks one player's subtree for game/puzzle session counts, total
/// action lines, and disk bytes. Every failure reads as zero: an admin page must
/// render even when a player has nothing on disk yet.
fn gatherStats(io: Io, alloc: Alloc, p: player.Player) PlayerStats {
    var st = PlayerStats{
        .id = p.id,
        .name = p.name,
        .last_seen = player.lastSeen(io, alloc, p.id),
        .game_sessions = 0,
        .puzzle_sessions = 0,
        .total_actions = 0,
        .disk_bytes = 0,
    };
    const uroot = storage.userDataDir(alloc, p.id) catch return st;
    const games_dir = std.fs.path.join(alloc, &.{ uroot, "lynrummy-elm", "sessions" }) catch return st;
    const puzzles_dir = std.fs.path.join(alloc, &.{ uroot, "puzzle", "sessions" }) catch return st;

    st.game_sessions = countSubdirs(io, games_dir);
    st.puzzle_sessions = countSubdirs(io, puzzles_dir);
    st.disk_bytes = dirBytes(io, alloc, uroot);

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

/// dirBytes sums file sizes under `path`, recursively (0 if missing).
fn dirBytes(io: Io, alloc: Alloc, path: []const u8) i64 {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var total: i64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = std.fs.path.join(alloc, &.{ path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => total += dirBytes(io, alloc, child),
            .file => {
                const body = Io.Dir.cwd().readFileAlloc(io, child, alloc, .unlimited) catch continue;
                total += @intCast(body.len);
            },
            else => {},
        }
    }
    return total;
}

/// countTextLines counts nonempty lines in a file (0 if missing).
fn countTextLines(io: Io, alloc: Alloc, path: []const u8) i64 {
    const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return 0;
    var n: i64 = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) n += 1;
    }
    return n;
}

// ── forms ────────────────────────────────────────────────────────────────────

/// formField reads one `a=b&c=d` field. Ids are the only values this page
/// accepts, and `exists` re-checks every one against the player store, so the
/// parse stays deliberately small — this module does not import chat.
fn formField(alloc: Alloc, body: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return try alloc.dupe(u8, pair[eq + 1 ..]);
    }
    return null;
}

// ── page markup ──────────────────────────────────────────────────────────────

const roster_head =
    \\<p class="muted">Everyone with a name on this machine, and what they have in {s}. "Last active" is their most recent move.</p>
    \\<table>
    \\<tr><th>Player</th><th>Last active</th><th class="n">Games</th><th class="n">Puzzles</th><th class="n">Actions</th><th class="n">Disk</th><th></th></tr>
;

// delete_confirm_template. Args: name, games, puzzles, actions, disk, id.
// {{ }} escape the CSS braces for std.fmt.
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
    \\<nav><a href="/admin/lynrummy">← Players</a></nav>
    \\<h1>Delete sessions for &ldquo;{s}&rdquo;?</h1>
    \\<div class="box">
    \\<p>This permanently removes <strong>all</strong> on-disk game data for this player:</p>
    \\<p><strong>{d}</strong> games · <strong>{d}</strong> puzzles · {d} actions · {s} on disk</p>
    \\<p class="warn">This cannot be undone. Their name is kept, so they keep playing under the same id with a fresh, empty history.</p>
    \\<form method="post" action="/admin/lynrummy/delete">
    \\  <input type="hidden" name="user" value="{s}">
    \\  <button type="submit" class="danger">Yes, delete</button>
    \\  <a class="cancel" href="/admin/lynrummy">Cancel</a>
    \\</form>
    \\</div>
    \\</body></html>
;
