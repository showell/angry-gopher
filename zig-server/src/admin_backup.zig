//! admin_backup: GET /admin/backup — everything the Store keeps, as one tar,
//! for the admin to download (gopher-metal QUEUE item 35).
//!
//! gopher-metal has no shell, so this is how its data leaves the machine. The
//! same route on Linux makes the two hosts' archives comparable, member by
//! member.
//!
//! **STREAMED, NOT BUILT.** A tar of 250 MB will not fit in gopher-metal's
//! memory, so the archive is written as it is walked: one header, then the
//! file in 64 KiB pieces read positionally, then the next. Memory is one
//! piece, whatever the data's size. The price: an error after the first byte
//! cannot become an error status, so it ends the archive early.
//!
//! **SO THE LAST MEMBER SAYS IT IS WHOLE.** A tar cut between two members
//! reads as complete: GNU tar and Python's tarfile list it and exit 0
//! (gopher-metal REVIEW-admin-backup.md, finding 2, measured). So the archive
//! ends with `backup-manifest.txt`, written only once everything before it
//! was: every file's SHA-256, size and path, then `end: N files, M bytes`.
//! An archive without it, or whose files do not match it, was cut short.
//! gopher-metal's droplet/check_backup.py checks one, and refuses one that
//! does not hold.
//!
//! **WHAT IS IN IT:** the two roots roots.point gave the Store, spelled as
//! gopher-metal spells them (`data/...`, `auth/...`), every folder and file,
//! in name order on both hosts, with each file's modification time. Secrets
//! are included: the session secret and the password hashes are part of
//! what a restore needs, and the route is admin-only.
//!
//! **IT ASKS FOR THE PASSWORD AGAIN** (gopher-metal REVIEW-admin-backup.md,
//! finding 1). The session secret is in it, and the secret mints every
//! session and every player's cookie. A session lasts a year and cannot be
//! revoked, so a copied cookie must not be enough for it. A GET (or HEAD)
//! shows a form; the archive is the answer to a POST with uid 1's password.
//! An API key reaches the form and no further, since it carries no password.
//!
//! A path ustar cannot hold (longer than its 255 bytes) is left out and
//! named in a last member, `backup-skipped.txt`. The Store's path limit
//! (256 as gopher-metal spells it) means at most a path of exactly 256. So
//! is anything that cannot be looked at, or is neither a file nor a folder
//! (a link), each with why: only a root not there yet is left out unsaid.

const std = @import("std");
const ustar = @import("ustar.zig");
const limits = @import("limits.zig");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("store.zig");
const http = @import("http.zig");
const users = @import("users.zig");
const chat = @import("chat.zig");
const html = @import("html.zig");
const ui = @import("admin_ui.zig");
const throttle = @import("login_throttle.zig");

const Request = std.http.Server.Request;

/// How much of a file is read at a time.
const piece = 64 * 1024;

const tar_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/x-tar" },
    .{ .name = "content-disposition", .value = "attachment; filename=\"gopher-backup.tar\"" },
    .{ .name = "cache-control", .value = "no-store" },
};

/// How many files this process has put into archives: for a test to see
/// whether a request walked the data.
pub var files_archived: usize = 0;

pub fn render(req: *Request, io: Io, alloc: Alloc, client: ?[]const u8) !void {
    const data = store.data_base orelse return req.respond("the data roots are not configured here\n", .{ .status = .service_unavailable });
    const auth = store.auth_base orelse return req.respond("the data roots are not configured here\n", .{ .status = .service_unavailable });

    // **A HEAD READS NOTHING** (gopher-metal REVIEW-admin-backup.md, finding
    // 7): it is the form's, as a GET is. Walking the data to write it into
    // nothing cost a whole backup's reads; on metal, that is every other
    // request waiting.
    if (req.head.method != .POST) return form(req, alloc, "", .ok);
    // **THE RE-ENTRY IS THROTTLED LIKE SIGN-IN** (QUEUE.md item 100): a stolen
    // admin session must not guess the password unbounded, which is what the
    // re-entry exists to stop. Refused before the hash, against the address and
    // uid 1's account (the same counters sign-in uses).
    if (throttle.check(io, client, ui.admin_uid)) |b| return form(req, alloc, b.text(), .too_many_requests);
    const sent = (try http.readLimitedBody(req, alloc, limits.body.secret_form)) orelse return;
    const password = (try chat.formField(alloc, sent, "password")) orelse "";
    if (!users.checkUserPassword(io, alloc, ui.admin_uid, password)) {
        throttle.recordFailure(io, client, ui.admin_uid);
        return form(req, alloc, "That is not the password.", .forbidden);
    }
    throttle.clearAddress(io, client);

    // A failed backup is an error answer, never an archive cut short: what
    // can be known before the answer starts is asked first (QUEUE 110).
    checkRoots(io, alloc, data, auth) catch |e| {
        const msg = try std.fmt.allocPrint(alloc, "The backup failed: a root cannot be looked at ({s}).\n", .{@errorName(e)});
        return req.respond(msg, .{ .status = .internal_server_error });
    };

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &tar_headers },
    }) catch return;
    archive(io, alloc, &body.writer, data, auth) catch return;
    body.end() catch return;
}

/// The page that asks for the password, with `err` above the form if any.
fn form(req: *Request, alloc: Alloc, err: []const u8, status: std.http.Status) !void {
    var b: std.ArrayList(u8) = .empty;
    try ui.begin(&b, alloc, "Download a backup", "");
    try b.appendSlice(alloc,
        \\<p>The backup is everything the site keeps, as one tar: the session secret, every
        \\password hash and every API key among it. So it asks for your password again.</p>
        \\
    );
    if (err.len != 0) try b.print(alloc, "<p class=\"err\">{s}</p>\n", .{try html.htmlEscape(alloc, err)});
    try b.appendSlice(alloc,
        \\<form method="post" action="/admin/backup">
        \\<label>Password <input type="password" name="password" autofocus></label>
        \\<button type="submit">Download the backup</button>
        \\</form>
        \\<p class="muted">On gopher-metal, take it from prod over the private network, never through
        \\Caddy from a home connection: metal answers nothing else while it streams.</p>
        \\
    );
    try ui.end(&b, alloc);
    try req.respond(b.items, .{ .status = status, .extra_headers = &.{http.html_ct} });
}

pub const manifest_name = "backup-manifest.txt";

/// The whole archive of the two roots into `w`: their members, then
/// `backup-skipped.txt` if anything was, then the manifest, then the end. An
/// error stops it where it is, with no manifest.
pub fn archive(io: Io, alloc: Alloc, w: *std.Io.Writer, data: []const u8, auth: []const u8) !void {
    try checkRoots(io, alloc, data, auth);
    var skipped: std.ArrayList(u8) = .empty;
    var m = Manifest{};
    const buf = try alloc.alloc(u8, piece);
    var t = Tar{ .w = w };
    for ([_][2][]const u8{ .{ "data", data }, .{ "auth", auth } }) |root| {
        try walk(io, alloc, &t, root[1], root[0], buf, &skipped, &m, true);
    }
    if (skipped.items.len > 0) {
        try t.file("backup-skipped.txt", skipped.items);
        try m.add(alloc, "backup-skipped.txt", skipped.items.len, digest(skipped.items));
    }
    try m.lines.print(alloc, "end: {d} files, {d} bytes\n", .{ m.files, m.bytes });
    try t.file(manifest_name, m.lines.items);
    try t.end();
}

/// **A ROOT THAT CANNOT BE LOOKED AT FAILS THE BACKUP** (metal-vmm QUEUE 110,
/// Steve: louder is better): an error, and no archive. Only a root not there
/// yet is no failure. Asked before the answer starts, so a failed backup is
/// an error answer, not an archive cut short; `archive` asks again.
pub fn checkRoots(io: Io, alloc: Alloc, data: []const u8, auth: []const u8) !void {
    for ([_][]const u8{ data, auth }) |root| {
        _ = try rootStat(io, alloc, root);
    }
}

/// **A ROOT IS "NOT THERE YET" ONLY IF IT IS NOT FOUND**: a root whose path
/// runs through a file (`NotDir`), or whose name is too long, is a root that
/// cannot be looked at, and fails the backup. `store.statOrNull` counts those
/// as absent, as a lookup by a request's name should; a root is the
/// backup's own setting, and missing it whole must be loud.
fn rootStat(io: Io, alloc: Alloc, path: []const u8) !?store.Stat {
    return store.stat(io, alloc, path) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

/// What the manifest says: a line per file, and the totals.
const Manifest = struct {
    lines: std.ArrayList(u8) = .empty,
    files: u64 = 0,
    bytes: u64 = 0,

    fn add(m: *Manifest, alloc: Alloc, path: []const u8, size: u64, sum: [Sha256.digest_length]u8) !void {
        if (m.files == 0) try m.lines.appendSlice(alloc, "gopher-backup manifest 1\n");
        try m.lines.print(alloc, "{x} {d} {s}\n", .{ sum, size, path });
        m.files += 1;
        m.bytes += size;
    }
};

const Sha256 = std.crypto.hash.sha2.Sha256;

fn digest(bytes: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

/// Writes `dir` (on this host) as `name` (in the archive) and everything
/// under it, in name order, each file into the manifest as it goes.
fn walk(io: Io, alloc: Alloc, t: *Tar, dir: []const u8, name: []const u8, buf: []u8, skipped: *std.ArrayList(u8), m: *Manifest, root: bool) !void {
    // **WHAT IS NOT TAKEN IS NAMED** (metal-vmm QUEUE 104): a folder inside
    // that cannot be looked at, or anything neither a file nor a folder, goes
    // in backup-skipped.txt with why. A root is not a skip: one not there yet
    // is left out unsaid, and one that cannot be looked at fails the backup
    // (QUEUE 110, `checkRoots`).
    const st = (if (root) try rootStat(io, alloc, dir) else store.statOrNull(io, alloc, dir) catch |e| {
        try skipped.print(alloc, "{s}/ (cannot be looked at: {s})\n", .{ name, @errorName(e) });
        return;
    }) orelse return;
    if (!try t.folder(name, mtimeOf(st))) {
        try skipped.print(alloc, "{s}/\n", .{name});
        return;
    }
    const entries = try store.list(io, alloc, dir);
    std.mem.sort(store.Entry, entries, {}, byName);
    for (entries) |e| {
        const host_path = try std.fs.path.join(alloc, &.{ dir, e.name });
        const arc_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ name, e.name });
        switch (e.kind) {
            .directory => try walk(io, alloc, t, host_path, arc_path, buf, skipped, m, false),
            .file => {
                // absent-ok: a file inside that cannot be looked at is a named skip (backup-skipped.txt), not a failed backup (QUEUE 110).
                const fst = store.stat(io, alloc, host_path) catch |err| {
                    try skipped.print(alloc, "{s} (cannot be looked at: {s})\n", .{ arc_path, @errorName(err) });
                    continue;
                };
                if (!ustar.fits(arc_path)) {
                    try skipped.print(alloc, "{s}\n", .{arc_path});
                    continue;
                }
                try t.header(arc_path, fst.size, mtimeOf(fst), '0');
                var h = Sha256.init(.{});
                var at: u64 = 0;
                while (at < fst.size) {
                    const want: usize = @intCast(@min(buf.len, fst.size - at));
                    const n = try store.readAt(io, alloc, host_path, at, buf[0..want]);
                    if (n == 0) return error.FileShrank; // the header promised more
                    h.update(buf[0..n]);
                    try t.w.writeAll(buf[0..n]);
                    at += n;
                }
                try t.pad(fst.size);
                try m.add(alloc, arc_path, fst.size, h.finalResult());
                files_archived += 1;
            },
            .other => try skipped.print(alloc, "{s} (neither a file nor a folder)\n", .{arc_path}),
        }
    }
}

fn byName(_: void, a: store.Entry, b: store.Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn mtimeOf(st: store.Stat) u64 {
    const s = @divFloor(st.mtime, std.time.ns_per_s);
    return if (s < 0) 0 else @intCast(s);
}

// ── ustar ────────────────────────────────────────────────────────────────────

const Tar = struct {
    w: *std.Io.Writer,

    fn folder(t: *Tar, name: []const u8, mtime: u64) !bool {
        var with_slash_buf: [260]u8 = undefined;
        if (name.len + 1 > with_slash_buf.len) return false;
        @memcpy(with_slash_buf[0..name.len], name);
        with_slash_buf[name.len] = '/';
        const with_slash = with_slash_buf[0 .. name.len + 1];
        if (!ustar.fits(with_slash)) return false;
        try t.header(with_slash, 0, mtime, '5');
        return true;
    }

    fn file(t: *Tar, name: []const u8, data: []const u8) !void {
        try t.header(name, data.len, 0, '0');
        try t.w.writeAll(data);
        try t.pad(data.len);
    }

    fn header(t: *Tar, path: []const u8, size: u64, mtime: u64, typeflag: u8) !void {
        const hdr = try ustar.header(path, size, mtime, typeflag);
        try t.w.writeAll(&hdr);
    }

    fn pad(t: *Tar, size: u64) !void {
        const zeros: [512]u8 = @splat(0);
        const n: usize = @intCast((512 - size % 512) % 512);
        try t.w.writeAll(zeros[0..n]);
    }

    /// Two zero blocks end a tar.
    fn end(t: *Tar) !void {
        const zeros: [1024]u8 = @splat(0);
        try t.w.writeAll(&zeros);
    }
};

/// The file members of a ustar archive, as (name, content), in order.
fn members(alloc: Alloc, tar: []const u8) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    var at: usize = 0;
    while (at + 512 <= tar.len) {
        const h = tar[at..][0..512];
        if (std.mem.allEqual(u8, h, 0)) break;
        const name_end = std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100;
        const prefix_end = std.mem.indexOfScalar(u8, h[345..500], 0) orelse 155;
        const name = if (prefix_end > 0)
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ h[345..][0..prefix_end], h[0..name_end] })
        else
            h[0..name_end];
        const size = try std.fmt.parseInt(u64, std.mem.trimEnd(u8, h[124..136], &.{ 0, ' ' }), 8);
        at += 512;
        if (h[156] == '0') try out.append(alloc, .{ name, tar[at..][0..@intCast(size)] });
        at += @intCast((size + 511) / 512 * 512);
    }
    return out.items;
}

test "fs: the archive ends with a manifest of every file; one cut short has none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const data = try std.fs.path.join(a, &.{ base, "data" });
    const auth = try std.fs.path.join(a, &.{ base, "auth" });
    const big = try a.alloc(u8, 3 * piece + 17); // more than one piece
    for (big, 0..) |*c, i| c.* = @truncate(i *% 31);
    try store.write(io, a, try std.fs.path.join(a, &.{ data, "chat", "_session_secret" }), "a secret, at least 32 bytes long....", .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ data, "lynrummy", "p1", "big" }), big, .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ auth, "1", "name" }), "Steve", .{});

    var whole: std.Io.Writer.Allocating = .init(a);
    try archive(io, a, &whole.writer, data, auth);
    const got = try members(a, whole.written());
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings(manifest_name, got[3][0]);
    var lines = std.mem.splitScalar(u8, got[3][1], '\n');
    try std.testing.expectEqualStrings("gopher-backup manifest 1", lines.next().?);
    for (got[0..3]) |m| {
        var want: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(m[1], &want, .{});
        const line = try std.fmt.allocPrint(a, "{x} {d} {s}", .{ want, m[1].len, m[0] });
        try std.testing.expectEqualStrings(line, lines.next().?);
    }
    var total: usize = 0;
    for (got[0..3]) |m| total += m[1].len;
    try std.testing.expectEqual(big.len + 36 + 5, total); // the three files written
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "end: 3 files, {d} bytes", .{total}), lines.next().?);

    // The same archive, into a writer that runs out partway through the big
    // file: an error, and no manifest in what was written.
    const cut = try a.alloc(u8, 2048 + piece);
    var short: std.Io.Writer = .fixed(cut);
    try std.testing.expectError(error.WriteFailed, archive(io, a, &short, data, auth));
    try std.testing.expect(std.mem.indexOf(u8, short.buffered(), manifest_name) == null);
}

test "fs: what the backup cannot take is named in backup-skipped.txt, never dropped (metal-vmm QUEUE 104)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const data = try std.fs.path.join(a, &.{ base, "data" });
    try store.write(io, a, try std.fs.path.join(a, &.{ data, "chat", "kept" }), "kept", .{});
    // A link in the tree is neither a file nor a folder the backup takes.
    try tmp.dir.symLink(io, "kept", "data/chat/link", .{});
    const auth = try std.fs.path.join(a, &.{ base, "auth" });

    var whole: std.Io.Writer.Allocating = .init(a);
    try archive(io, a, &whole.writer, data, auth);
    const got = try members(a, whole.written());
    var skipped: ?[]const u8 = null;
    for (got) |m| if (std.mem.eql(u8, m[0], "backup-skipped.txt")) {
        skipped = m[1];
    };
    try std.testing.expect(skipped != null);
    try std.testing.expect(std.mem.indexOf(u8, skipped.?, "data/chat/link") != null);
}

test "fs: a root that cannot be looked at fails the backup, no archive (metal-vmm QUEUE 110)" {
    // It was named in backup-skipped.txt and the backup answered OK: a whole
    // root missing from a backup is louder as a failure (Steve, 2026-10-08).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const data = try std.fs.path.join(a, &.{ base, "data" });
    try store.write(io, a, try std.fs.path.join(a, &.{ data, "chat", "kept" }), "kept", .{});
    // There, and not to be looked at: a link to itself loops.
    try tmp.dir.symLink(io, "auth", "auth", .{});
    const auth = try std.fs.path.join(a, &.{ base, "auth" });

    var whole: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(std.meta.isError(archive(io, a, &whole.writer, data, auth)));
    // A root whose path runs through a file cannot be looked at either: it is
    // NotDir, not "not there yet" (a cold review of 110, 2026-10-08).
    try store.write(io, a, try std.fs.path.join(a, &.{ base, "afile" }), "x", .{});
    var through: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(std.meta.isError(archive(io, a, &through.writer, data, try std.fs.path.join(a, &.{ base, "afile", "auth" }))));
    // A root not there yet is no failure.
    var fine: std.Io.Writer.Allocating = .init(a);
    try archive(io, a, &fine.writer, data, try std.fs.path.join(a, &.{ base, "not-yet" }));
}
