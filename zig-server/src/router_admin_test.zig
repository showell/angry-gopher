//! router.zig's tests: the admin surfaces and the host's setup.

const std = @import("std");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
const client_address = @import("webbox").client_address;
const free_space = @import("webbox").free_space;
const mem_meter = @import("webbox").mem_meter;
const search_index = @import("search_index.zig");
const testing = std.testing;
const harness = @import("router_harness.zig");
const router = @import("router.zig");

// ── /admin/backup (zig-metal-unikernel REVIEW-admin-backup.md) ──────────────────────

test "route: HEAD /admin/backup reads nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const admin_backup = @import("admin_backup.zig");
    const me = try harness.adminSession(a, io);

    const before = admin_backup.files_archived;
    const head = try harness.serve(a, io, try std.fmt.allocPrint(a, "HEAD /admin/backup HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{me}));
    try testing.expectEqualStrings("200 OK", harness.status(head));
    try testing.expectEqual(before, admin_backup.files_archived);
    // The download (a POST with the password) does walk it: the secret and
    // the account files, at least.
    const got = try harness.postForm(a, io, "/admin/backup", me, "password=hunter2");
    try testing.expectEqualStrings("200 OK", harness.status(got));
    try testing.expect(admin_backup.files_archived >= before + 3);
}

test "route: start does the host's setup in one call: the data and the store pointed at, every session's record, search's index, the free space and the proxy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(a);
    defer meter.restore();
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const host_space = free_space.save();
    defer host_space.restore();
    const host_proxy = client_address.save();
    defer host_proxy.restore();
    const chat_store = @import("chat_store.zig");
    const disk = @import("webbox").store;
    const md = try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.md" });
    try disk.write(io, a, md, "MSG_ChitChat_1\nfrom: Steve\ndate: 2026-10-10T00:00:00Z\n\nhello world", .{});
    // The store's bases are start's to set (webbox's site.zig), not the
    // application's: cleared here, so only start can have set them.
    disk.setBases("", "");
    const data_dir = try std.fs.path.join(a, &.{ uid_site.base, "data" });
    const auth_dir = try std.fs.path.join(a, &.{ uid_site.base, "auth" });
    var started = try router.start(io, .{
        .roots = .{ .data_dir = data_dir, .auth_dir = auth_dir },
        .free_space = .unknown,
        .trusted_proxy = "10.0.0.2",
    });
    _ = &started;
    try testing.expectEqual(@as(usize, 1), started.app.backfilled);
    try testing.expect(try disk.has(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "ChitChat.count" })));
    try testing.expectEqual(@as(usize, 1), started.app.search.?.messages);
    try testing.expectEqual(@as(?*const fn () ?free_space.Space, null), free_space.reader);
    try testing.expectEqualStrings("10.0.0.2", client_address.trusted_proxy.?);
    try testing.expectEqualStrings(data_dir, disk.data_base.?);
    try testing.expectEqualStrings(auth_dir, disk.auth_base.?);
    // Its own copies, which outlive whatever the host built its Host from.
    try testing.expect(disk.data_base.?.ptr != data_dir.ptr and disk.auth_base.?.ptr != auth_dir.ptr);
}

test "route: only a member's own session is the admin; a non-member's session, or a gopher_uid, is no one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const ask = struct {
        fn admin(al: std.mem.Allocator, i: Io, cookie: []const u8) ![]const u8 {
            return harness.serve(al, i, try std.fmt.allocPrint(al, "GET /admin HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{cookie}));
        }
    };

    // uid 1 with a name and no password is not a member: a session signed
    // rightly for it names no one.
    try users.setUserName(io, a, "1", "Steve");
    const early = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "1", now)});
    try testing.expectEqualStrings("303 See Other", harness.status(try ask.admin(a, io, early)));

    // Once a member, the session is the admin; a signed gopher_uid for the
    // same id is not a session, and is no one here.
    const me = try harness.adminSession(a, io);
    try testing.expectEqualStrings("200 OK", harness.status(try ask.admin(a, io, me)));
    try testing.expectEqualStrings("303 See Other", harness.status(try ask.admin(a, io, try harness.signedUid(a, "1"))));
}

test "route: /admin/backup asks for the password again, and gives nothing without it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const admin_backup = @import("admin_backup.zig");
    const me = try harness.adminSession(a, io);
    const before = admin_backup.files_archived;

    // The session alone: a form, not the archive.
    const page = try harness.UidSite.ask(a, io, "/admin/backup", me);
    try testing.expectEqualStrings("200 OK", harness.status(page));
    try testing.expect(std.mem.indexOf(u8, page, "type=\"password\"") != null);
    try testing.expect(std.mem.indexOf(u8, page, "application/x-tar") == null);
    // A wrong password, and none: refused, nothing walked.
    for ([_][]const u8{ "password=wrong", "", "pass=hunter2" }) |body| {
        const r = try harness.postForm(a, io, "/admin/backup", me, body);
        try testing.expectEqualStrings("403 Forbidden", harness.status(r));
        try testing.expect(std.mem.indexOf(u8, r, "application/x-tar") == null);
    }
    try testing.expectEqual(before, admin_backup.files_archived);
    // The right one: the archive, ending with its manifest.
    const tar = try harness.postForm(a, io, "/admin/backup", me, "password=hunter2");
    try testing.expectEqualStrings("200 OK", harness.status(tar));
    try testing.expect(std.mem.indexOf(u8, tar, "application/x-tar") != null);
    try testing.expect(std.mem.indexOf(u8, tar, admin_backup.manifest_name) != null);
    // Nobody else gets as far as the form, with the admin's password or not:
    // no identity is sent to log in, and a member who is not the admin is a 404.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postForm(a, io, "/admin/backup", "gopher_uid=1", "password=hunter2")));
    try users.setUserName(io, a, "2", "apoorva");
    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const other = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.postForm(a, io, "/admin/backup", other, "password=hunter2")));
    try testing.expectEqual(@as(usize, 0), admin_backup.files_archived - before - countFiles(tar));
}

/// How many manifest lines name a file, in an archive's text.
fn countFiles(tar: []const u8) usize {
    const at = std.mem.lastIndexOf(u8, tar, "\nend: ") orelse return 0;
    var it = std.mem.tokenizeAny(u8, tar[at + "\nend: ".len ..], " ");
    return std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
}

/// A host's whole log, for /admin/log's test: two boots of request lines.
const TestLogs = struct {
    fn get(_: Io, _: std.mem.Allocator) anyerror!?@import("webbox").host_facts.Logs {
        return .{
            .this_boot = "  boot: ram\n" ++
                "  2026-10-13T14:01:59.900Z request 11: GET /gopher/chat -> ok, 200 in 3.0 ms (base: 1)\n" ++
                "  2026-10-13T14:02:07.123Z request 12: POST /gopher/chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)\n" ++
                "    upload: 9000 bytes, arrived in 40 ms\n",
            .capacity = 1280 * 1024,
            .lost = 7,
            .booted_unix = 1_791_900_000,
            .host_commit = "abc1234",
            .before = .{ .boot = 4, .text = "  2026-10-13T13:00:00.000Z request 900: GET /admin/host -> ok, 200 in 1.0 ms (base: 1)\n  RESTART: a panic\n" },
        };
    }
};

test "route: /admin/log is the host's whole log as text, by the admin's key only, narrowed by time, request and path (metal-vmm QUEUE 189.3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const me = try harness.adminSession(a, io);

    // A host with no log of its own says so.
    @import("webbox").host_facts.provideLogs(null);
    const none = try harness.UidSite.ask(a, io, "/admin/log", me);
    try testing.expectEqualStrings("200 OK", harness.status(none));
    try testing.expect(std.mem.indexOf(u8, none, "content-type: text/plain") != null);
    try testing.expect(std.mem.indexOf(u8, none, "# This host keeps no log of its own") != null);

    @import("webbox").host_facts.provideLogs(TestLogs.get);
    defer @import("webbox").host_facts.provideLogs(null);
    const all = try harness.UidSite.ask(a, io, "/admin/log", me);
    try testing.expectEqualStrings("200 OK", harness.status(all));
    for ([_][]const u8{
        "# the host: commit abc1234\n",
        "# booted 2026-10-13 14:00:00 UTC\n",
        "# this boot: ",
        "of 1310720 kept at most; 7 written before them and no longer held; the oldest timed line 2026-10-13T14:01:59.900Z; 4 lines below\n",
        "  boot: ram\n",
        "    upload: 9000 bytes, arrived in 40 ms\n",
        "# the boot before (boot 4, kept across its restart)",
        "  RESTART: a panic\n",
    }) |want| if (std.mem.indexOf(u8, all, want) == null) {
        std.debug.print("missing: {s}\nin:\n{s}\n", .{ want, all });
        return error.TestExpectedEqual;
    };
    // One request, this boot only: its line and its upload's, no other.
    const one = try harness.UidSite.ask(a, io, "/admin/log?request=12&boot=this", me);
    try testing.expect(std.mem.indexOf(u8, one, "request 12: POST") != null);
    try testing.expect(std.mem.indexOf(u8, one, "    upload: 9000") != null);
    try testing.expect(std.mem.indexOf(u8, one, "request 11:") == null);
    try testing.expect(std.mem.indexOf(u8, one, "boot before") == null);
    // By time, both boots: the boot before ended at 13:00, before it.
    const late = try harness.UidSite.ask(a, io, "/admin/log?since=2026-10-13T14%3A02", me);
    try testing.expect(std.mem.indexOf(u8, late, "request 12:") != null);
    try testing.expect(std.mem.indexOf(u8, late, "request 11:") == null);
    try testing.expect(std.mem.indexOf(u8, late, "request 900:") == null);
    // By path.
    const admin_only = try harness.UidSite.ask(a, io, "/admin/log?path=/admin", me);
    try testing.expect(std.mem.indexOf(u8, admin_only, "request 900:") != null);
    try testing.expect(std.mem.indexOf(u8, admin_only, "request 12:") == null);
    // A filter spelled wrong is the client's, and says what is allowed.
    const bad = try harness.UidSite.ask(a, io, "/admin/log?since=yesterday", me);
    try testing.expectEqualStrings("400 Bad Request", harness.status(bad));
    try testing.expect(std.mem.indexOf(u8, bad, "boot=this|before|both") != null);
    // GET only.
    try testing.expectEqualStrings("405 Method Not Allowed", harness.status(try harness.postForm(a, io, "/admin/log", me, "x=1")));
    // Without the admin's key: a sign-in for no one, a 404 for a member.
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/admin/log", ""), "RESTART") == null);
}

test "route: /admin/host counts the requests since boot, the slowest, and puts every 5xx first (metal-vmm QUEUE 189.5)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const traffic = @import("webbox").traffic;
    const saved = traffic.global;
    defer traffic.global = saved;
    traffic.global = .{};
    const me = try harness.adminSession(a, io);
    _ = try harness.UidSite.ask(a, io, "/chat", me);
    _ = try harness.UidSite.ask(a, io, "/nope", me);
    // No errors yet: none said.
    const calm = try harness.UidSite.ask(a, io, "/admin/host", me);
    try testing.expect(std.mem.indexOf(u8, calm, "Errors since boot") == null);
    try testing.expect(std.mem.indexOf(u8, calm, "<td>requests since boot</td><td>2 requests:") != null);
    try testing.expect(std.mem.indexOf(u8, calm, "<td>by part of the site</td><td>chat 1, site 1</td>") != null);
    try testing.expect(std.mem.indexOf(u8, calm, "<td>the slowest</td>") != null);
    // A 5xx: the page leads with it, ahead of everything else.
    traffic.global.note(.{ .family = "chat", .status = 503, .took_ns = 4 * std.time.ns_per_ms, .target = "/chat/c/1_2/T/send", .at_unix_ms = 1_791_900_127_123, .err = "ReadOnlyFileSystem" });
    const loud = try harness.UidSite.ask(a, io, "/admin/host", me);
    const errors_at = std.mem.indexOf(u8, loud, "<h2>Errors since boot</h2>") orelse return error.TestExpectedEqual;
    try testing.expect(errors_at < std.mem.indexOf(u8, loud, "<h2>The application</h2>").?);
    try testing.expect(std.mem.indexOf(u8, loud, "2026-10-13T14:02:07.123Z /chat/c/1_2/T/send 503 in 4.0 ms (ReadOnlyFileSystem)") != null);
}

test "route: /admin/secret changes the secret: members log in again, players are re-signed for the days given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const me = try harness.adminSession(a, io);
    const id = try player.allocate(io, a, "Nikhil");
    const old_uid = try harness.signedUid(a, id); // signed with the secret before the change
    const secret_path = try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret" });

    // The form; a wrong password and bad days change nothing.
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/admin/secret", me), "type=\"password\"") != null);
    try testing.expectEqualStrings("403 Forbidden", harness.status(try harness.postForm(a, io, "/admin/secret", me, "password=wrong&days=7")));
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postForm(a, io, "/admin/secret", me, "password=hunter2&days=abc")));
    try testing.expectEqualStrings("400 Bad Request", harness.status(try harness.postForm(a, io, "/admin/secret", me, "password=hunter2&days=91")));
    try testing.expectEqualStrings(harness.UidSite.secret, try harness.UidSite.disk.read(io, a, secret_path, .limited(256)));
    // Nobody but the admin reaches it.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postForm(a, io, "/admin/secret", "gopher_uid=1", "password=hunter2&days=7")));

    // The change.
    const done = try harness.postForm(a, io, "/admin/secret", me, "password=hunter2&days=7");
    try testing.expectEqualStrings("200 OK", harness.status(done));
    const new_secret = try harness.UidSite.disk.read(io, a, secret_path, .limited(256));
    try testing.expect(!std.mem.eql(u8, new_secret, harness.UidSite.secret));
    try testing.expectEqual(@as(usize, 64), new_secret.len);

    // The admin's session has ended; the password still logs in.
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.UidSite.ask(a, io, "/admin", me)));
    const relogin = try harness.postForm(a, io, "/login/full", "x=y", "name=Steve&password=hunter2&action=login");
    try testing.expect(std.mem.indexOf(u8, relogin, "set-cookie: __Host-gopher_auth=") != null);

    // The player's old cookie still names them, on a POST too, and a GET
    // re-signs it with the new secret.
    try testing.expect(harness.playingAs(try harness.postForm(a, io, "/play", old_uid, ""), "Nikhil"));
    const renewed = try harness.UidSite.ask(a, io, "/play", old_uid);
    try testing.expectEqualStrings("303 See Other", harness.status(renewed));
    const fresh = harness.setUid(renewed) orelse return error.NoSetCookie;
    try testing.expectEqualStrings(id, uid_cookie.verify(new_secret, fresh, harness.nowSecs(io)).?);
    try testing.expect(harness.playingAs(try harness.UidSite.ask(a, io, "/play", try std.fmt.allocPrint(a, "__Host-gopher_uid={s}", .{fresh})), "Nikhil"));

    // Once the days are over, the old cookie names no one.
    try harness.UidSite.disk.replace(io, a, try std.fs.path.join(a, &.{ users.session_secret_dir, "_session_secret.previous-until" }), "1\n", .{});
    const late = try harness.UidSite.ask(a, io, "/play", old_uid);
    try testing.expectEqualStrings("200 OK", harness.status(late));
    try testing.expect(!harness.playingAs(late, "Nikhil"));
    try testing.expect(harness.setUid(late) == null);
}

test "route: an admin delete of a player there is not says so, 404, where it went back to the roster as if done (156(i))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const me = try harness.adminSession(a, io);
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.postForm(a, io, "/admin/lynrummy/delete", me, "user=p999")));
    try testing.expectEqualStrings("404 Not Found", harness.status(try harness.UidSite.ask(a, io, "/admin/lynrummy/delete?user=p999", me)));
    const id = try player.allocate(io, a, "Nikhil");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, try std.fmt.allocPrint(a, "/admin/lynrummy/delete?user={s}", .{id}), me)));
}
