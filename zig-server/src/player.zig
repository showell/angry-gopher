//! player: the LOCAL identity — a name, no password, for the two pages that
//! need *a* user rather than *the* user (/game and /puzzles).
//!
//! It exists so that Lyn Rummy does not reach into the chat account store. The
//! account store (users.zig over `~/Auth`) carries passwords, API keys, sessions
//! and members; a puzzle board needs none of that, only a key to file a game
//! under and a name to print on it. This module is the whole of what those pages
//! ask for, in about a page of code, reading one directory that belongs to this
//! machine.
//!
//! On-disk shape under {player_root}/:
//!   {id}/name        the display name
//!   {id}/last-seen   unix seconds, bumped on a move
//!   next-id.txt      the counter for locally-minted ids
//!
//! **A LOCALLY-MINTED ID IS `p<n>`, NEVER A BARE NUMBER.** Account ids are bare
//! decimals, and both identities ride the same `gopher_uid` cookie during the
//! transition, so disjoint spellings are what keeps a fresh player from landing
//! on an existing account's game directory. It also means the account resolver
//! ignores a player cookie outright — its guest arm requires all digits — so a
//! player can never be mistaken for a chat principal.
//!
//! **THE COOKIE IS DELIBERATELY THE OLD ONE.** `gopher_uid` already sits in
//! every returning visitor's browser carrying the id their games are filed
//! under, guest and member alike (the member login sets it too). Reusing it is
//! what lets this ship without anyone re-registering or losing a game; the
//! seeded names in deploy/seed-players.sh are the other half.
//!
//! **WHAT THIS DOES NOT DO, ON PURPOSE.** There is no password, no session
//! signature, and no check that the name is free. Anyone who sets
//! `gopher_uid` by hand reaches that player's game list. That is the same
//! honour-system the guest tier has always had — protection here would mean
//! carrying the account store across the boundary, which is the thing being
//! undone. Nothing behind a real gate (chat, settings, admin, uploads) resolves
//! through this module.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const html = @import("html.zig");
const names = @import("names.zig");
const counter = @import("counter.zig");

/// player_root is the local player directory (config.zig points it at
/// {data_dir}/players at startup; the default is repo-relative from zig-server/).
pub var player_root: []const u8 = "../games/lynrummy/players-data";

/// cookie_name is shared with the account store's guest arm on purpose — see the
/// module header.
pub const cookie_name = "gopher_uid";

/// cookie_max_age is one year, matching the identity cookie login.zig issues.
const cookie_max_age = 60 * 60 * 24 * 365;

/// local_prefix marks an id this module minted, keeping it out of the account
/// store's decimal space.
const local_prefix = "p";

pub const Player = struct { id: []const u8, name: []const u8 };

// ── resolution ───────────────────────────────────────────────────────────────

/// current resolves the player a request acts as: the cookie's id if it names a
/// player on disk, else the zero value (id == ""). An id that does not exist is
/// no identity at all, so a stale cookie sends someone to the name page rather
/// than filing games under a phantom.
pub fn current(io: Io, alloc: Alloc, req: *std.http.Server.Request) !Player {
    const id = (try http.cookie(req, alloc, cookie_name)) orelse return .{ .id = "", .name = "" };
    if (!isSafeID(id)) return .{ .id = "", .name = "" };
    const name = (try readField(io, alloc, id, "name")) orelse return .{ .id = "", .name = "" };
    return .{ .id = id, .name = name };
}

/// isSafeID rejects anything that could escape player_root or a data directory.
/// Ids come from a cookie, so this is the one place they are untrusted.
fn isSafeID(id: []const u8) bool {
    if (id.len == 0 or id.len > 24) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

// ── issuance ─────────────────────────────────────────────────────────────────

/// allocate mints a fresh local player with `name` and returns its id (`p<n>`).
pub fn allocate(io: Io, alloc: Alloc, name: []const u8) ![]const u8 {
    const counter_path = try std.fs.path.join(alloc, &.{ player_root, "next-id.txt" });
    const n = try counter.next(io, alloc, counter_path);
    const id = try std.fmt.allocPrint(alloc, "{s}{d}", .{ local_prefix, n });
    try setName(io, alloc, id, name);
    return id;
}

/// mirror gives an account id a player row with the same id, so a chat member
/// keeps one game history across both identities. Idempotent; it refreshes the
/// name, since the account store is that name's owner while both exist.
/// This is the ONLY call into this module from the chat side, and it goes away
/// with login.zig when the surfaces separate.
pub fn mirror(io: Io, alloc: Alloc, id: []const u8, name: []const u8) void {
    if (!isSafeID(id) or name.len == 0) return;
    setName(io, alloc, id, name) catch {};
}

/// setName writes a player's display name, creating the row (whose existence IS
/// the player).
fn setName(io: Io, alloc: Alloc, id: []const u8, name: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ player_root, id });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "name" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = name });
}

/// deleteRecord removes a player's row (name + last-seen). Their game data is
/// deleted separately, by storage.deleteUserData. Refuses an unsafe id so it can
/// never target a root; best-effort.
pub fn deleteRecord(io: Io, alloc: Alloc, id: []const u8) void {
    if (!isSafeID(id)) return;
    const dir = std.fs.path.join(alloc, &.{ player_root, id }) catch return;
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

/// nameOf answers a player's display name, "" when there is none.
pub fn nameOf(io: Io, alloc: Alloc, id: []const u8) ![]const u8 {
    if (!isSafeID(id)) return "";
    return (try readField(io, alloc, id, "name")) orelse "";
}

/// list enumerates every player, id-sorted with the seeded numeric ids ahead of
/// the locally-minted `p<n>` ones. The player store IS the roster of everyone who
/// can have Lyn Rummy data: the seed brought the account-store names across, and
/// a chat member who logs in is mirrored in. Powers the game admin.
pub fn list(io: Io, alloc: Alloc) ![]Player {
    var dir = Io.Dir.cwd().openDir(io, player_root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList(Player) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const id = try alloc.dupe(u8, entry.name);
        if (!isSafeID(id)) continue;
        const name = (try readField(io, alloc, id, "name")) orelse continue;
        try out.append(alloc, .{ .id = id, .name = name });
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(Player, slice, {}, lessThanByID);
    return slice;
}

/// lessThanByID sorts numerically within each spelling, seeded ids first: the
/// numeric ones came from the account store and are the older players.
fn lessThanByID(_: void, a: Player, b: Player) bool {
    const an = std.fmt.parseInt(i64, a.id, 10) catch null;
    const bn = std.fmt.parseInt(i64, b.id, 10) catch null;
    if (an != null and bn != null) return an.? < bn.?;
    if (an != null) return true;
    if (bn != null) return false;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// lastSeen answers a player's last-activity time (Unix seconds), or null.
pub fn lastSeen(io: Io, alloc: Alloc, id: []const u8) ?i64 {
    if (!isSafeID(id)) return null;
    const raw = (readField(io, alloc, id, "last-seen") catch return null) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
}

/// touch records "now" as this player's last-seen time. Best-effort: a failed
/// write is not worth failing a move over.
pub fn touch(io: Io, alloc: Alloc, id: []const u8) void {
    touchImpl(io, alloc, id) catch {};
}

fn touchImpl(io: Io, alloc: Alloc, id: []const u8) !void {
    if (!isSafeID(id)) return;
    const dir = try std.fs.path.join(alloc, &.{ player_root, id });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "last-seen" });
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const body = try std.fmt.allocPrint(alloc, "{d}", .{now});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

fn readField(io: Io, alloc: Alloc, id: []const u8, field: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(alloc, &.{ player_root, id, field });
    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4096)) catch return null;
    return std.mem.trimEnd(u8, raw, "\r\n");
}

/// cookie is the Set-Cookie value that binds a browser to a player.
pub fn cookie(alloc: Alloc, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ cookie_name, id, cookie_max_age });
}

// ── /play, the name page ─────────────────────────────────────────────────────

/// handle serves /play: GET asks for a name, POST mints a player and returns to
/// `next` (an internal path, default "/"). This is the door /game and /puzzles
/// send a nameless visitor to.
pub fn handle(req: *std.http.Server.Request, io: Io, alloc: Alloc) !void {
    // Header-derived state is read BEFORE the body: the body read invalidates
    // the live head, so the target and the current player are resolved up front.
    const target = try http.target(req, alloc);
    const cur = try current(io, alloc, req);

    const from_query = try queryNext(alloc, target);

    if (req.head.method != .POST) {
        return renderPage(req, alloc, cur.name, from_query, "");
    }

    const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
    const next = sanitizeNext((try formField(alloc, body, "next")) orelse from_query);
    const vr = try names.validateUserName(alloc, (try formField(alloc, body, "name")) orelse "");
    if (vr.err.len != 0) return renderPage(req, alloc, cur.name, next, vr.err);

    const id = try allocate(io, alloc, vr.name);
    var hs: std.ArrayList(std.http.Header) = .empty;
    try hs.append(alloc, .{ .name = "location", .value = next });
    try hs.append(alloc, .{ .name = "set-cookie", .value = try cookie(alloc, id) });
    try req.respond("", .{ .status = .see_other, .extra_headers = hs.items });
}

/// queryNext reads ?next= off the request target, so a GET /play?next=/game
/// remembers where the visitor was headed.
fn queryNext(alloc: Alloc, target: []const u8) ![]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return "/";
    return sanitizeNext((try formField(alloc, target[q + 1 ..], "next")) orelse "/");
}

/// sanitizeNext keeps only internal redirect targets, so ?next= is never an open
/// redirect.
fn sanitizeNext(next: []const u8) []const u8 {
    if (std.mem.startsWith(u8, next, "/") and !std.mem.startsWith(u8, next, "//")) return next;
    return "/";
}

/// formField reads one `a=b&c=d` field, percent- and plus-decoded. A local copy
/// of the parse chat.zig also has: this module does not import chat.
fn formField(alloc: Alloc, body: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return try formDecode(alloc, pair[eq + 1 ..]);
    }
    return null;
}

fn formDecode(alloc: Alloc, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '+' => try out.append(alloc, ' '),
            '%' => {
                if (i + 2 >= raw.len) return error.BadEscape;
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.BadEscape;
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.BadEscape;
                try out.append(alloc, @intCast(hi * 16 + lo));
                i += 2;
            },
            else => try out.append(alloc, raw[i]),
        }
    }
    return out.items;
}

fn renderPage(req: *std.http.Server.Request, alloc: Alloc, current_name: []const u8, next: []const u8, err_msg: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, page_head);
    if (current_name.len != 0) {
        try b.print(alloc, "<p class=\"muted\">Currently playing as <strong>{s}</strong>.</p>", .{try html.htmlEscape(alloc, current_name)});
    }
    if (err_msg.len != 0) {
        try b.print(alloc, "<p class=\"err\">{s}</p>", .{try html.htmlEscape(alloc, err_msg)});
    }
    // The tail carries JavaScript braces, so it is appended rather than
    // formatted; only the one escaped value is printed.
    try b.appendSlice(alloc, "<form id=\"f\" method=\"post\" action=\"/play\">\n");
    try b.print(alloc, "  <input type=\"hidden\" name=\"next\" value=\"{s}\">\n", .{try html.htmlEscape(alloc, next)});
    try b.appendSlice(alloc, page_tail);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

const page_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 80px auto; max-width: 420px; padding: 0 24px; }
    \\h1 { color: #000080; }
    \\.muted { color: #888; font-size: 14px; }
    \\.err { color: #b00020; font-size: 14px; }
    \\input[type=text] { font-size: 16px; padding: 8px; width: 100%; box-sizing: border-box; margin: 8px 0; }
    \\button { background: #000080; color: white; border: none; padding: 10px 20px;
    \\         font-size: 15px; border-radius: 4px; cursor: pointer; }
    \\button:hover { background: #0000a0; }
    \\a { color: #000080; }
    \\</style>
    \\</head><body>
    \\<h1>What should we call you?</h1>
    \\<p class="muted">No password — just a name, so your games and puzzles have somewhere to live. Letters, numbers, spaces, and apostrophes.</p>
    \\
;

const page_tail =
    \\  <input id="name" name="name" type="text" maxlength="40" placeholder="Your name" autofocus>
    \\  <button type="submit">Start playing</button>
    \\</form>
    \\<p class="muted" style="margin-top:16px">Here for chat? <a href="/login/full">Log in with a password &rarr;</a></p>
    \\<script>
    \\  var inp = document.getElementById('name');
    \\  if (!inp.value) { var n = localStorage.getItem('gopher_user'); if (n) inp.value = n; }
    \\  document.getElementById('f').addEventListener('submit', function () {
    \\    localStorage.setItem('gopher_user', inp.value);
    \\  });
    \\</script>
    \\</body></html>
;

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// The store is a filesystem contract (a name must PERSIST under the id it was
// minted with), so those run against a real temp tree; the id and redirect
// policies are pure and get their own cases.

const testing = std.testing;

test "isSafeID accepts account and local spellings, rejects traversal" {
    try testing.expect(isSafeID("1"));
    try testing.expect(isSafeID("p7"));
    try testing.expect(!isSafeID(""));
    try testing.expect(!isSafeID(".."));
    try testing.expect(!isSafeID("a/b"));
    try testing.expect(!isSafeID("p-1"));
    try testing.expect(!isSafeID("a" ** 25));
}

test "sanitizeNext keeps internal paths and refuses an open redirect" {
    try testing.expectEqualStrings("/game", sanitizeNext("/game"));
    try testing.expectEqualStrings("/", sanitizeNext("//evil.example"));
    try testing.expectEqualStrings("/", sanitizeNext("https://evil.example"));
    try testing.expectEqualStrings("/", sanitizeNext(""));
}

test "formField decodes plus and percent escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Steve Howell", (try formField(a, "name=Steve+Howell&next=%2Fgame", "name")).?);
    try testing.expectEqualStrings("/game", (try formField(a, "name=x&next=%2Fgame", "next")).?);
    try testing.expect((try formField(a, "name=x", "missing")) == null);
}

test "fs: a minted player is p-prefixed, readable back, and disjoint from account ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = player_root;
    defer player_root = saved;
    player_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "players" });

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = try allocate(io, a, "Nikhil");
    try testing.expect(std.mem.startsWith(u8, id, local_prefix));
    try testing.expect(!std.ascii.isDigit(id[0])); // never collides with an account id
    try testing.expectEqualStrings("Nikhil", try nameOf(io, a, id));

    // A second player gets a distinct id.
    const id2 = try allocate(io, a, "Debbie");
    try testing.expect(!std.mem.eql(u8, id, id2));

    // mirror gives an account id a row under its own numeric spelling.
    mirror(io, a, "1", "Steve");
    try testing.expectEqualStrings("Steve", try nameOf(io, a, "1"));

    // An id with no row is no identity.
    try testing.expectEqualStrings("", try nameOf(io, a, "p999"));
}
