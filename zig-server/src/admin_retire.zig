//! admin_retire: /admin/retire — retiring old topics and users, from inside the
//! app (QUEUE.md item 104). The box did it once by hand on prod; metal has no
//! shell, so this is how it is done on the machine with no operating system, and
//! the same route on Linux keeps the two hosts comparable.
//!
//! **TWO STEPS, BOTH BEHIND THE PASSWORD.** Like /admin/backup and
//! /admin/secret, a session alone is not enough — the re-entry is throttled
//! (QUEUE.md item 100), refused before the bcrypt against the address and uid
//! 1's account. A POST with the password and no `confirm` runs a **dry run**:
//! it reads, changes nothing, and lists what would go — by kind and name,
//! **never a message body** — with a second form to confirm. A POST with
//! `confirm=1` and the password **carries it out** through the Store's own
//! paths, so metal's FAT volume stays consistent, and shows what was removed.
//! A second confirm removes nothing (chat_retire projects the post-removal
//! state, so it is idempotent).

const std = @import("std");
const limits = @import("limits.zig");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const users = @import("users.zig");
const chat = @import("chat.zig");
const html = @import("html.zig");
const ui = @import("admin_ui.zig");
const throttle = @import("login_throttle.zig");
const retire = @import("chat_retire.zig");

const Request = std.http.Server.Request;

/// The most days back the form accepts (ten years): a guard on a fat-fingered
/// number, not a real limit.
const max_days = 3650;

pub fn render(req: *Request, io: Io, alloc: Alloc, client: ?[]const u8) !void {
    if (req.head.method != .POST) return form(req, alloc, defaults(), "", .ok);

    // The re-entry, throttled like sign-in (QUEUE.md item 100).
    if (throttle.check(io, client, ui.admin_uid)) |b| return form(req, alloc, defaults(), b.text(), .too_many_requests);
    const sent = (try http.readLimitedBody(req, alloc, limits.body.retire_form)) orelse return;
    const password = (try chat.formField(alloc, sent, "password")) orelse "";
    const in = try readForm(alloc, sent);
    if (!users.checkUserPassword(io, alloc, ui.admin_uid, password)) {
        throttle.recordFailure(io, client, ui.admin_uid);
        return form(req, alloc, in, "That is not the password.", .forbidden);
    }
    throttle.clearAddress(io, client);

    if (in.days_err) return form(req, alloc, in, std.fmt.comptimePrint("The days are a number from 0 to {d}.", .{max_days}), .bad_request);

    const confirm = std.mem.eql(u8, (try chat.formField(alloc, sent, "confirm")) orelse "", "1");
    var pl = try retire.plan(io, alloc, .{ .days = in.days, .keep = in.keep, .now = ui.nowUnix(io) }, confirm);
    return result(req, alloc, in, &pl, confirm);
}

// ── the form (the dry run lives below it after a preview) ─────────────────────

/// What the form carries between the preview and the confirm: the two
/// parameters the admin set, and whether the days field parsed.
const Input = struct {
    days: u32,
    days_text: []const u8,
    days_err: bool,
    keep: []const []const u8,
    keep_text: []const u8,
};

fn defaults() Input {
    return .{ .days = retire.default_days, .days_text = "30", .days_err = false, .keep = &retire.default_keep, .keep_text = default_keep_text };
}

const default_keep_text = "Steve, apoorva, damian, Claude, Debbie";

/// Reads `days` and `keep` from the POST body. An unparseable or out-of-range
/// `days` is flagged (days_err) rather than guessed; an empty `keep` keeps
/// no one (every account is removed) — the caller sees the count before it
/// confirms, so an empty box is caught by eye, not by a silent default.
fn readForm(alloc: Alloc, body: []const u8) !Input {
    const days_text = std.mem.trim(u8, (try chat.formField(alloc, body, "days")) orelse "30", " \t\r\n");
    const parsed = std.fmt.parseInt(u32, days_text, 10) catch null;
    const keep_text = std.mem.trim(u8, (try chat.formField(alloc, body, "keep")) orelse default_keep_text, " \t\r\n");
    return .{
        .days = if (parsed) |d| d else retire.default_days,
        .days_text = days_text,
        .days_err = parsed == null or parsed.? > max_days,
        .keep = try parseKeep(alloc, keep_text),
        .keep_text = keep_text,
    };
}

/// The keep list: names split on commas and newlines, trimmed, blanks dropped.
fn parseKeep(alloc: Alloc, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ",\r\n");
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len != 0) try out.append(alloc, name);
    }
    return out.toOwnedSlice(alloc);
}

fn form(req: *Request, alloc: Alloc, in: Input, err: []const u8, status: std.http.Status) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "Retire old topics and users", "");
    try b.appendSlice(alloc,
        \\<p>One tidy of the data: <strong>old topics</strong> (every topic whose newest message is older
        \\than the days below) and <strong>every account not in the keep list</strong>, removed everywhere it
        \\lives — its direct-message conversations, its line in each channel, and any kept user's pointer left
        \\dangling. <strong>Messages a removed user wrote in a kept conversation stay.</strong> This cannot be undone;
        \\take a backup first.</p>
        \\<p>Preview first: it lists what would go, by name and count, and changes nothing until you confirm.</p>
        \\
    );
    if (err.len != 0) try b.print(alloc, "<p class=\"err\">{s}</p>\n", .{try html.htmlEscape(alloc, err)});
    try b.print(alloc,
        \\<form method="post" action="/admin/retire">
        \\<label>Retire topics older than <input name="days" value="{s}" size="4"> days</label><br>
        \\<label>Keep these users (by name, comma- or line-separated):<br>
        \\<textarea name="keep" rows="3" cols="50">{s}</textarea></label><br>
        \\<label>Password <input type="password" name="password"></label>
        \\<button type="submit">Preview</button>
        \\</form>
        \\
    , .{ try html.htmlEscape(alloc, in.days_text), try html.htmlEscape(alloc, in.keep_text) });
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .status = status, .extra_headers = &.{http.html_ct} });
}

// ── the result (dry run → confirm, or confirmed) ──────────────────────────────

fn result(req: *Request, alloc: Alloc, in: Input, pl: *retire.Plan, confirmed: bool) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, if (confirmed) "Retired" else "Preview — nothing removed yet", "");

    const verb = if (confirmed) "Removed" else "Would remove";
    try b.print(alloc, "<p>{s} <strong>{d}</strong> thing(s) in all; <strong>{d}</strong> account(s) not kept. Topics older than {d} days.</p>\n", .{ verb, pl.total(), pl.members_removed, in.days });

    // Counts by kind, then the names under each. Names only, never a body.
    try b.appendSlice(alloc, "<table><tr><th>What</th><th class=\"n\">Count</th></tr>");
    inline for (std.meta.fields(retire.Kind)) |f| {
        const kind: retire.Kind = @enumFromInt(f.value);
        const n = pl.countOf(kind);
        if (n != 0) try b.print(alloc, "<tr><td>{s}</td><td class=\"n\">{d}</td></tr>", .{ kind.label(), n });
    }
    try b.print(alloc, "<tr class=\"total\"><td>total</td><td class=\"n\">{d}</td></tr></table>\n", .{pl.total()});

    if (pl.total() != 0) {
        try b.appendSlice(alloc, "<h2>Details</h2>\n<ul>");
        for (pl.items.items) |it| {
            try b.print(alloc, "<li><span class=\"muted\">{s}:</span> {s}</li>", .{ it.kind.label(), try html.htmlEscape(alloc, it.name) });
        }
        try b.appendSlice(alloc, "</ul>\n");
    }

    if (!confirmed and pl.total() != 0) {
        // Carry the SAME parameters into the confirm, and ask for the password
        // again so the destructive step is behind the re-entry too.
        try b.print(alloc,
            \\<form method="post" action="/admin/retire">
            \\<input type="hidden" name="confirm" value="1">
            \\<input type="hidden" name="days" value="{s}">
            \\<input type="hidden" name="keep" value="{s}">
            \\<p><label>Password <input type="password" name="password"></label>
            \\<button type="submit">Retire these now</button></p>
            \\</form>
            \\
        , .{ try html.htmlEscape(alloc, in.days_text), try html.htmlEscape(alloc, in.keep_text) });
    } else if (!confirmed) {
        try b.appendSlice(alloc, "<p class=\"muted\">Nothing matches — nothing to remove.</p>\n");
    } else {
        try b.appendSlice(alloc, "<p class=\"flash\">Done.</p> <p><a href=\"/admin/retire\">Back</a></p>\n");
    }
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseKeep splits on commas and newlines, trims, drops blanks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parseKeep(a, " Steve , apoorva\n damian ,\n\n Claude ");
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("Steve", got[0]);
    try testing.expectEqualStrings("apoorva", got[1]);
    try testing.expectEqualStrings("damian", got[2]);
    try testing.expectEqualStrings("Claude", got[3]);
    try testing.expectEqual(@as(usize, 0), (try parseKeep(a, "  ,\n , ")).len);
}

test "readForm flags a bad or out-of-range days, and keeps the text to echo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try readForm(a, "days=45&keep=Steve");
    try testing.expect(!ok.days_err);
    try testing.expectEqual(@as(u32, 45), ok.days);
    try testing.expect((try readForm(a, "days=notanumber&keep=Steve")).days_err);
    try testing.expect((try readForm(a, "days=99999&keep=Steve")).days_err); // past max
    // An absent days field defaults to 30 and does not error.
    const d = try readForm(a, "keep=Steve");
    try testing.expect(!d.days_err);
    try testing.expectEqual(@as(u32, 30), d.days);
}
