//! admin_ui: the shell and the gate the two admin screens share.
//!
//! There are two screens, because there are two subjects: `admin.zig` is the
//! CHAT roster (members, last-seen, image quota, API keys) and
//! `admin_lynrummy.zig` is the GAME roster (players, sessions, disk, delete).
//! Splitting them stopped chat's admin from reaching into the game store for a
//! stats column, which was the one place a chat module imported `storage`.
//!
//! **THE GATE IS THE OPEN QUESTION.** `requireAdmin` resolves through the chat
//! account store, because a password is the only credential the site has. On a
//! machine where chat does not live — the public box, after the split — there is
//! nothing here to check a password against, so the game admin will need either
//! its own credential or a hop to the box that has one. Nothing is decided; this
//! is the one file that would change when it is.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const users = @import("users.zig");

const Request = std.http.Server.Request;

/// admin_uid is the sole admin. Hardcoded to Steve's uid 1 (per his call) until
/// an admin flag is added.
pub const admin_uid = "1";

/// requireAdmin answers whether the request may proceed, having already written
/// the refusal when it may not: a redirect to the password gate with no
/// identity, a 404 for anyone else (an admin surface should not confirm it
/// exists).
pub fn requireAdmin(req: *Request, io: Io, alloc: Alloc) !bool {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0) {
        try http.redirect(req, "/login/full");
        return false;
    }
    if (!std.mem.eql(u8, uid, admin_uid)) {
        try http.notFound(req);
        return false;
    }
    return true;
}

// ── the shell ────────────────────────────────────────────────────────────────

/// begin emits the doctype, the shared stylesheet, the cross-link between the
/// two screens (with `here` rendered bold-without-href) and the heading.
pub fn begin(b: *std.ArrayList(u8), alloc: Alloc, heading: []const u8, here: []const u8) !void {
    try b.appendSlice(alloc, page_head);
    try b.appendSlice(alloc, "<nav><a href=\"/\">← Home</a> · ");
    try tab(b, alloc, "/admin", "Chat", here);
    try b.appendSlice(alloc, " · ");
    try tab(b, alloc, "/admin/lynrummy", "Lyn Rummy", here);
    try b.print(alloc, "</nav>\n<h1>{s}</h1>\n", .{heading});
}

fn tab(b: *std.ArrayList(u8), alloc: Alloc, href: []const u8, label: []const u8, here: []const u8) !void {
    if (std.mem.eql(u8, href, here)) {
        try b.print(alloc, "<strong>{s}</strong>", .{label});
    } else {
        try b.print(alloc, "<a href=\"{s}\">{s}</a>", .{ href, label });
    }
}

pub fn end(b: *std.ArrayList(u8), alloc: Alloc) !void {
    try b.appendSlice(alloc, "</body></html>");
}

// ── format helpers ───────────────────────────────────────────────────────────

/// humanizeSince renders elapsed seconds as a coarse relative string ("just now",
/// "Nm ago", "Nh ago", "Nd ago").
pub fn humanizeSince(alloc: Alloc, elapsed_s: i64) ![]const u8 {
    const d = if (elapsed_s < 0) 0 else elapsed_s;
    if (d < 60) return "just now";
    if (d < 3600) return std.fmt.allocPrint(alloc, "{d}m ago", .{@divTrunc(d, 60)});
    if (d < 86400) return std.fmt.allocPrint(alloc, "{d}h ago", .{@divTrunc(d, 3600)});
    return std.fmt.allocPrint(alloc, "{d}d ago", .{@divTrunc(d, 86400)});
}

/// sinceOrNever is humanizeSince for an optional timestamp — "never" when a
/// principal has no recorded activity at all.
pub fn sinceOrNever(alloc: Alloc, now: i64, last_seen: ?i64) ![]const u8 {
    return if (last_seen) |t| humanizeSince(alloc, now - t) else "never";
}

/// humanBytes renders a byte count as "N B" / "N.N {K,M,G,…}B" (1024-based).
pub fn humanBytes(alloc: Alloc, n: i64) ![]const u8 {
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

/// mostRecentFirst orders a roster: anyone active-ever above anyone never
/// active, most-recent first within that. Both screens sort the same way, and
/// the rosters are tiny, so this pairs with a stable insertion sort.
pub fn mostRecentFirst(a: ?i64, b: ?i64) bool {
    if ((a != null) != (b != null)) return a != null;
    if (a == null) return false; // both never-active — preserve order
    return a.? > b.?;
}

pub fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

const page_head =
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
    \\
;

// ══ TESTS ════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "humanBytes crosses each unit boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("512 B", try humanBytes(a, 512));
    try testing.expectEqualStrings("1.0 KB", try humanBytes(a, 1024));
    try testing.expectEqualStrings("1.5 KB", try humanBytes(a, 1536));
    try testing.expectEqualStrings("1.0 MB", try humanBytes(a, 1024 * 1024));
    try testing.expectEqualStrings("1.0 GB", try humanBytes(a, 1024 * 1024 * 1024));
}

test "humanizeSince is coarse, and never negative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("just now", try humanizeSince(a, 0));
    try testing.expectEqualStrings("just now", try humanizeSince(a, -99)); // clock skew
    try testing.expectEqualStrings("59m ago", try humanizeSince(a, 3599));
    try testing.expectEqualStrings("1h ago", try humanizeSince(a, 3600));
    try testing.expectEqualStrings("2d ago", try humanizeSince(a, 2 * 86400));
}

test "mostRecentFirst puts the active above the never-active" {
    try testing.expect(mostRecentFirst(100, 50));
    try testing.expect(!mostRecentFirst(50, 100));
    try testing.expect(mostRecentFirst(1, null)); // active-ever wins
    try testing.expect(!mostRecentFirst(null, 1));
    try testing.expect(!mostRecentFirst(null, null)); // stable: preserve order
}
