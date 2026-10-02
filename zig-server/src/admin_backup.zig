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
//! cannot become an error status, so it ends the archive early, and a
//! truncated tar is what the admin gets. A tar reader says so.
//!
//! **WHAT IS IN IT:** the two roots roots.point gave the Store, spelled as
//! gopher-metal spells them (`data/...`, `auth/...`), every folder and file,
//! in name order on both hosts, with each file's modification time. Secrets
//! are included: the session secret and the password hashes are part of
//! what a restore needs, and the route is admin-only.
//!
//! A path ustar cannot hold (longer than its 255 bytes) is left out and
//! named in a last member, `backup-skipped.txt`. The Store's path limit
//! (256 as gopher-metal spells it) means at most a path of exactly 256.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("store.zig");

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

pub fn render(req: *Request, io: Io, alloc: Alloc) !void {
    const data = store.data_base orelse return req.respond("the data roots are not configured here\n", .{ .status = .service_unavailable });
    const auth = store.auth_base orelse return req.respond("the data roots are not configured here\n", .{ .status = .service_unavailable });

    // **A HEAD READS NOTHING** (gopher-metal REVIEW-admin-backup.md, finding
    // 7). The body is left out of the answer anyway, and walking the data to
    // write it into nothing cost a whole backup's reads; on metal, that is
    // every other request waiting.
    if (req.head.method == .HEAD) return req.respond("", .{ .extra_headers = &tar_headers });

    var hbuf: [4096]u8 = undefined;
    var body = req.respondStreaming(&hbuf, .{
        .respond_options = .{ .extra_headers = &tar_headers },
    }) catch return;

    var skipped: std.ArrayList(u8) = .empty;
    const buf = try alloc.alloc(u8, piece);
    var t = Tar{ .w = &body.writer };
    for ([_][2][]const u8{ .{ "data", data }, .{ "auth", auth } }) |root| {
        walk(io, alloc, &t, root[1], root[0], buf, &skipped) catch return;
    }
    if (skipped.items.len > 0) {
        t.file("backup-skipped.txt", skipped.items) catch return;
    }
    t.end() catch return;
    body.end() catch return;
}

/// Writes `dir` (on this host) as `name` (in the archive) and everything
/// under it, in name order.
fn walk(io: Io, alloc: Alloc, t: *Tar, dir: []const u8, name: []const u8, buf: []u8, skipped: *std.ArrayList(u8)) !void {
    const st = store.stat(io, alloc, dir) catch return; // a root not there yet
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
            .directory => try walk(io, alloc, t, host_path, arc_path, buf, skipped),
            .file => {
                const fst = store.stat(io, alloc, host_path) catch continue;
                if (!fits(arc_path)) {
                    try skipped.print(alloc, "{s}\n", .{arc_path});
                    continue;
                }
                try t.header(arc_path, fst.size, mtimeOf(fst), '0');
                var at: u64 = 0;
                while (at < fst.size) {
                    const want: usize = @intCast(@min(buf.len, fst.size - at));
                    const n = try store.readAt(io, alloc, host_path, at, buf[0..want]);
                    if (n == 0) return error.FileShrank; // the header promised more
                    try t.w.writeAll(buf[0..n]);
                    at += n;
                }
                try t.pad(fst.size);
                files_archived += 1;
            },
            .other => {},
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

/// Whether ustar can hold `path`: in its 100-byte name field, or split at a
/// slash into a 155-byte prefix and the name.
pub fn fits(path: []const u8) bool {
    return split(path) != null;
}

/// `path` as (prefix, name) for a ustar header, or null when it cannot be.
pub fn split(path: []const u8) ?struct { prefix: []const u8, name: []const u8 } {
    if (path.len <= 100) return .{ .prefix = "", .name = path };
    // The latest slash that leaves a name of at most 100 and a prefix of at
    // most 155.
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] != '/') continue;
        if (path.len - i - 1 > 100) return null;
        if (i <= 155 and path.len - i - 1 > 0) return .{ .prefix = path[0..i], .name = path[i + 1 ..] };
    }
    return null;
}

const Tar = struct {
    w: *std.Io.Writer,

    fn folder(t: *Tar, name: []const u8, mtime: u64) !bool {
        var with_slash_buf: [260]u8 = undefined;
        if (name.len + 1 > with_slash_buf.len) return false;
        @memcpy(with_slash_buf[0..name.len], name);
        with_slash_buf[name.len] = '/';
        const with_slash = with_slash_buf[0 .. name.len + 1];
        if (!fits(with_slash)) return false;
        try t.header(with_slash, 0, mtime, '5');
        return true;
    }

    fn file(t: *Tar, name: []const u8, data: []const u8) !void {
        try t.header(name, data.len, 0, '0');
        try t.w.writeAll(data);
        try t.pad(data.len);
    }

    fn header(t: *Tar, path: []const u8, size: u64, mtime: u64, typeflag: u8) !void {
        const parts = split(path) orelse return error.NameTooLong;
        var hdr: [512]u8 = @splat(0);
        @memcpy(hdr[0..parts.name.len], parts.name);
        octalField(hdr[100..108], if (typeflag == '5') 0o755 else 0o644);
        octalField(hdr[108..116], 0);
        octalField(hdr[116..124], 0);
        octalField(hdr[124..136], size);
        octalField(hdr[136..148], mtime);
        @memset(hdr[148..156], ' ');
        hdr[156] = typeflag;
        @memcpy(hdr[257..263], "ustar\x00");
        hdr[263] = '0';
        hdr[264] = '0';
        @memcpy(hdr[345..][0..parts.prefix.len], parts.prefix);
        var sum: u32 = 0;
        for (hdr) |c| sum += c;
        octalDigits(hdr[148..154], sum);
        hdr[154] = 0;
        hdr[155] = ' ';
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

/// `value` as (field.len - 1) octal digits and a NUL: ustar's numeric fields.
fn octalField(field: []u8, value: u64) void {
    const digits = field.len - 1;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    field[digits] = 0;
}

/// Exactly field.len octal digits: the checksum's six.
fn octalDigits(field: []u8, value: u64) void {
    var v = value;
    var i = field.len;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

test "a long path goes in ustar's prefix, split at a slash, and one too long does not fit" {
    const short = split("data/chat/1_2/sessions/topic.md").?;
    try std.testing.expectEqualStrings("", short.prefix);
    const sid = "A" ++ "b" ** 78 ++ "9";
    const long_path = "data/chat/1_2/sessions/" ++ sid ++ ".reactions.jsonl";
    const got = split(long_path).?;
    try std.testing.expectEqualStrings("data/chat/1_2/sessions", got.prefix);
    try std.testing.expectEqualStrings(sid ++ ".reactions.jsonl", got.name);
    // A last name over 100 bytes cannot be held, whatever the prefix.
    try std.testing.expect(split("data/" ++ "x" ** 101) == null);
    // Nor a prefix over 155.
    try std.testing.expect(split("p" ** 160 ++ "/name") == null);
    try std.testing.expect(fits("data/" ++ "y" ** 95));
}
