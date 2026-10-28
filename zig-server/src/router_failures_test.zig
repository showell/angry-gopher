//! router.zig's tests: the store-failure class: a failure is a 500, never silence or a lie.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_codec = @import("chat_codec.zig");
const Io = @import("host_io").Io;
const player = @import("player.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
const streams = @import("webbox").bus;
const Bus = streams.Bus;
const Hub = streams.Hub;
const mem_meter = @import("webbox").mem_meter;
const testing = std.testing;
const harness = @import("router_harness.zig");
const router = @import("router.zig");

test "fs: a doc that cannot be looked at is a server error, never a 404 (metal-vmm QUEUE 114)" {
    // A 404 says "no such doc", and an API client's next save may then
    // replace one that is there (QUEUE 105's pattern, through a wrapper:
    // docs_store.docExists).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const docs_store = @import("docs_store.zig");
    // The docs page allocates through it, and presence keeps a map in it for
    // the life of the process: an arena freed at the test's end would leave
    // the next test that marks someone active a map in freed memory.
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});

    const kept = try docs_store.docPath(a, "2", "kept");
    try harness.UidSite.disk.write(io, a, kept, "# kept\n", .{});
    const fine = try harness.UidSite.ask(a, io, "/chat/docs/kept.md", member);
    try testing.expectEqualStrings("200 OK", harness.status(fine));

    // The same doc, now a link to itself: it cannot be looked at.
    const lost = try docs_store.docPath(a, "2", "lost");
    try std.Io.Dir.cwd().symLink(io, "lost.md", lost, .{});
    const resp = try harness.UidSite.ask(a, io, "/chat/docs/lost.md", member);
    try testing.expect(std.mem.indexOf(u8, harness.status(resp), "404") == null);
    try testing.expect(std.mem.startsWith(u8, harness.status(resp), "5"));
}

/// The host's Io, but every file removal fails: a store whose delete is
/// refused, while reads and writes go on (metal-vmm QUEUE 129).
/// Refused only under paths holding this, when it is set (QUEUE 134(e)).
var refuse_under: []const u8 = "";

/// Or, when set, a file of this name wherever it is, by a full path or by
/// the name alone as std's deleteTree asks (QUEUE 138(f)).
var refuse_named: []const u8 = "";

fn removalsFail(io: Io, vt: *Io.VTable) Io {
    const refused = struct {
        // Not std's failingDirDeleteFile, which answers FileNotFound: that
        // is "already gone", which a revoke rightly takes as done.
        fn deleteFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
            const named = refuse_named.len > 0 and std.mem.eql(u8, std.fs.path.basename(sub_path), refuse_named);
            const under = refuse_named.len == 0 and std.mem.indexOf(u8, sub_path, refuse_under) != null;
            if (!named and !under) return real.?.dirDeleteFile(userdata, dir, sub_path);
            return error.AccessDenied;
        }
        var real: ?*const Io.VTable = null;
    };
    refused.real = io.vtable;
    vt.* = io.vtable.*;
    vt.dirDeleteFile = refused.deleteFile;
    return .{ .userdata = io.userdata, .vtable = vt };
}

test "route: a key revoke whose removal fails is not answered as revoked, and the key is still there to say so (metal-vmm QUEUE 129)" {
    // `clearUserAPIKey` was `store.remove(...) catch {}`, and /settings/apikey
    // then redirected to `?keyrevoked=1`: the member told their key was gone
    // while it went on authenticating.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});
    const key = try users.setUserAPIKey(io, a, "2");

    var vt: Io.VTable = undefined;
    const failing = removalsFail(io, &vt);
    const raw = try std.fmt.allocPrint(a, "POST /settings/apikey HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 8\r\n\r\nrevoke=1", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(failing, a);
    var b = Bus.of(&hub);
    _ = router.route(&req, failing, a, &b) catch {};
    try out.writer.flush();
    try testing.expect(std.mem.indexOf(u8, out.written(), "keyrevoked") == null);
    try testing.expect(std.mem.startsWith(u8, harness.status(out.written()), "500"));
    // The key is there, and still the key.
    try testing.expectEqualStrings(key, (try users.getUserAPIKey(io, a, "2")).?);
}

test "route: a release whose removals fail is not answered as done, and the account is still there (metal-vmm QUEUE 129)" {
    // Logout's release ran `deleteUserData(...) catch {}`, then deleted the
    // record (each removal itself `catch {}`), then said "logged out": a
    // refused removal left the account logging in, or its data kept, while
    // its member was told both were gone.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});
    const data = try std.fs.path.join(a, &.{ harness.UidSite.storage.data_root, "2", "next-session-id.txt" });
    try harness.UidSite.disk.write(io, a, data, "2\n", .{});

    var vt: Io.VTable = undefined;
    const failing = removalsFail(io, &vt);
    const raw = try std.fmt.allocPrint(a, "POST /logout HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrelease=yes", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(failing, a);
    var b = Bus.of(&hub);
    _ = router.route(&req, failing, a, &b) catch {};
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, harness.status(out.written()), "500"));
    // The account is there, and still logs in.
    try testing.expect(try users.principalExists(io, a, "2"));
    try testing.expect(try users.checkUserPassword(io, a, "2", "hunter2"));
    _ = try harness.UidSite.disk.stat(io, a, data); // and its data, which the release could not remove
}

test "route: a release whose last removal fails leaves an account that can release again, never one gone with its leftovers kept (metal-vmm QUEUE 134(e))" {
    // The account record went first (auth_root: its password), then its
    // private state (users_root). A failure there answered 500 for an
    // account already released: nobody could log in to try again, and the
    // folder stayed. Authority goes last, as the retire's does.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});
    const private = try std.fs.path.join(a, &.{ users.users_root, "2" });
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ private, "upload-bytes" }), "1\n", .{});

    var vt: Io.VTable = undefined;
    refuse_under = private;
    defer refuse_under = "";
    const failing = removalsFail(io, &vt);
    const raw = try std.fmt.allocPrint(a, "POST /logout HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrelease=yes", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(failing, a);
    var b = Bus.of(&hub);
    _ = router.route(&req, failing, a, &b) catch {};
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, harness.status(out.written()), "500"));
    // Still an account that logs in, to release again.
    try testing.expect(try users.checkUserPassword(io, a, "2", "hunter2"));
    // And again, the disk willing: released, nothing left.
    refuse_under = "";
    try testing.expect(std.mem.indexOf(u8, try harness.postForm(a, io, "/logout", member, "release=yes"), "500") == null);
    try testing.expect(!try users.principalExists(io, a, "2"));
    try testing.expect(!try harness.UidSite.disk.has(io, a, private));
}

test "route: a release whose removal inside the account fails keeps the password, whatever order the folder is walked in (metal-vmm QUEUE 138(f))" {
    // The account's folder (auth_root/<id>) went by std's deleteTree, in the
    // order the folder was read: the password could go before a file whose
    // removal then failed, and the account was gone with its leftovers kept.
    // Each of the account's other files is refused in turn: the password
    // goes last, so it is there every time. (QUEUE 134(e)'s test refused all
    // of users_root, which depended on how std's deleteTree walks.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // presence outlives the test
    defer meter.restore();

    const account = try std.fs.path.join(a, &.{ users.auth_root, "2" });
    // Thirty files besides it: whatever order a folder is read in, the
    // password is last of them one time in thirty-one, so the walk that
    // removed it before a refused file is seen.
    const others = [_][]const u8{ "name", "api-key", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25", "f26", "f27", "f28" };
    for (others) |refused| {
        try users.setUserPassword(io, a, "2", "hunter2");
        for (others) |f| try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ account, f }), "x", .{});
        const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
        const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});

        var vt: Io.VTable = undefined;
        refuse_named = refused;
        defer refuse_named = "";
        const failing = removalsFail(io, &vt);
        const raw = try std.fmt.allocPrint(a, "POST /logout HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrelease=yes", .{member});
        var reader: std.Io.Reader = .fixed(raw);
        var out: std.Io.Writer.Allocating = .init(a);
        var server = std.http.Server.init(&reader, &out.writer);
        var req = try server.receiveHead();
        req.head.keep_alive = false;
        var hub = Hub.init(failing, a);
        var b = Bus.of(&hub);
        _ = router.route(&req, failing, a, &b) catch {};
        try out.writer.flush();
        try testing.expect(std.mem.startsWith(u8, harness.status(out.written()), "500"));
        // Still an account that logs in, to release again.
        try testing.expect(try users.checkUserPassword(io, a, "2", "hunter2"));
        // And again, the disk willing: released, nothing left.
        refuse_named = "";
        try testing.expect(std.mem.indexOf(u8, try harness.postForm(a, io, "/logout", member, "release=yes"), "500") == null);
        try testing.expect(!try users.principalExists(io, a, "2"));
        try testing.expect(!try harness.UidSite.disk.has(io, a, account));
    }
}

test "route: an error after a request's body was read is answered 500 too, never with silence (metal-vmm QUEUE 127(b))" {
    // Reading the body moves the reader past `received_head`, so that state
    // cannot say whether a head went out: a move whose append fails, after
    // its body was read, was answered with nothing. Here the session's
    // actions.dsl is a folder: the session is there, and the append fails.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();

    const id = try player.allocate(io, a, .literal("Nikhil"));
    const me = try harness.signedUid(a, id);
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/game/new-session", me, "state")));
    const s1 = try std.fs.path.join(a, &.{ harness.UidSite.storage.data_root, id, "lynrummy-elm", "sessions", "1" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ s1, "actions.dsl" }));

    const raw = try std.fmt.allocPrint(a, "POST /game/sessions/1/actions HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 4\r\n\r\nmove", .{me});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    try testing.expect(std.meta.isError(router.route(&req, io, a, &b)));
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, harness.status(out.written()), "500"));
    // And the writer the router lent the handler is given back.
    try testing.expect(server.out == &out.writer);
}

test "fs: a handler's error is answered 500, never with silence (metal-vmm QUEUE 123)" {
    // On metal, `GET /puzzles -> ReadFailed` reached the console and the
    // client got nothing (the box's durable sweep, seed 173): an error that
    // escapes a handler was dropped by the host. Here a doc that is a
    // folder: it is there, and reading it fails.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const docs_store = @import("docs_store.zig");
    const meter = mem_meter.useForTest(std.heap.page_allocator); // as above: presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});
    try std.Io.Dir.cwd().createDirPath(io, try docs_store.docPath(a, "2", "folder"));

    const raw = try std.fmt.allocPrint(a, "GET /chat/docs/folder.md HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{member});
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    // The error still goes to the host, to log; the client is told first,
    // and told nothing of it (QUEUE 134(f)): its name is the log's.
    try testing.expect(std.meta.isError(router.route(&req, io, a, &b)));
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, harness.status(out.written()), "500"));
    try testing.expect(std.mem.endsWith(u8, out.written(), "\r\n\r\nThe server failed.\n"));
}

/// A POST whose handler fails: the answer it was given (route answers the
/// failure, then hands the error on to the host, to log).
fn postFailing(a: std.mem.Allocator, io: Io, target: []const u8, cookies: []const u8, body: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ target, cookies, body.len, body });
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    try testing.expect(std.meta.isError(router.route(&req, io, a, &b)));
    try out.writer.flush();
    return out.written();
}

test "route: a pin, a bookmark or the login mirror that will not write is a 500, never a quiet success (156(g))" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // The pins' folder is a file: the pin cannot be written.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "pinned-sessions" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Plans/pin", steve, "")));
    // The bookmarks' folder is a file: a send is refused before it stores.
    const bookmarks = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions" });
    try std.Io.Dir.cwd().deleteTree(io, bookmarks);
    try harness.UidSite.disk.write(io, a, bookmarks, "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=hello&cid=x")));
    const raw = (try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Plans")).?;
    try testing.expectEqual(@as(usize, 1), (try chat_codec.decodeChatFile(a, raw)).len);
    // The player row is a file where its folder goes: the login's mirror fails.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ player.player_root, "1" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/login/full", "x=y", "name=Steve&password=pw&action=login")));
}

test "route: a pins file that will not read is a 500, never read as no pins; a missing one is no pins (the Roc's files: missing and failed are two answers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Ann");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_3/new", steve, "topic=Plans")));
    // 1_2's pins file is a folder, a pin inside it: it cannot be read, and
    // the pin is not written over it, as "no pins" would be.
    const pins = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "pinned-sessions", "1_2" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ pins, "kept" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Plans/pin", steve, "")));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Plans/unpin", steve, "")));
    try testing.expect(try harness.UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ pins, "kept" })));
    // 1_3's is missing: no pins, and the pin is the file's one line.
    try testing.expectEqualStrings("204 No Content", harness.status(try harness.postAs(a, io, "/chat/c/1_3/Plans/pin", steve, "")));
    try testing.expectEqualStrings("Plans\n", try harness.UidSite.disk.read(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "pinned-sessions", "1_3" }), .unlimited));
}

test "route: a reaction that will not store, and a sidecar that will not read, are 500s, never a quiet answer (C4: the Roc's routes keep the host's errors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // The sidecar is a folder: it can be neither appended to nor read.
    const sidecar = try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_2"), "sessions", "Plans.reactions.jsonl" });
    try std.Io.Dir.cwd().createDirPath(io, sidecar);
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Plans/react", steve, "msg=1&emoji=%F0%9F%91%8D")));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/c/1_2/Plans/reactions", steve)));
}

test "route: a topic's page whose resume pointer will not write, and a landing whose topics will not list, are 500s (C3: the Roc's pages keep the host's errors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // The bookmarks' folder is a file: the page's resume pointer cannot be written.
    const bookmarks = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions" });
    try std.Io.Dir.cwd().deleteTree(io, bookmarks);
    try harness.UidSite.disk.write(io, a, bookmarks, "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/c/1_2/Plans", steve)));
    // The conversation's topics folder is a file: its landing cannot list them.
    const sessions = try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_3"), "sessions" });
    _ = try harness.memberSession(a, io, "3", "Ann");
    try harness.UidSite.disk.write(io, a, sessions, "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/c/1_3", steve)));
}

test "route: a new topic whose topics will not list writes nothing more, and /chat, the conversations and a new topic's bookmark that will not read or write are 500s (C3: after a failure the host does nothing more)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Ann");
    const state = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1" });
    // 1_3's topics folder is a file: the duplicate check cannot read, and the
    // bookmark the Roc would go on to write is not written.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_3"), "sessions" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_3/new", steve, "topic=Plans")));
    try testing.expect(!try harness.UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ state, "last-sessions", "1_3" })));
    try testing.expect(!try harness.UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ state, "last-conv" })));
    // The partner's DM will not list: the conversations are a 500.
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/conversations", steve)));
    // The bookmarks' folder is a file: a new topic in 1_2 is refused before
    // it is made.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ state, "last-sessions" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expect((try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Plans")) == null);
    // The last-conv pointer is a folder: /chat cannot read where to resume.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ state, "last-conv" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat", steve)));
}

test "route: a new topic whose first message will not append, and /chat whose resume topic will not read, are 500s (C3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // A folder where the new topic's transcript goes: not a topic (the list
    // passes folders over), so the topic is made, and its first message
    // cannot be written.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_2"), "sessions", "Ghost.md" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/new", steve, "topic=Ghost")));
    // A folder where the DM's last-viewed topic goes: /chat cannot resume.
    const last = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "last-sessions", "1_2" });
    try std.Io.Dir.cwd().deleteTree(io, last);
    try std.Io.Dir.cwd().createDirPath(io, last);
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat", steve)));
}

test "route: a send whose message will not append, or whose channel's members will not read, is a 500, never a 303 or a 404 (O1: the Roc's send keeps the host's errors)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    // A folder where the topic's transcript goes: the append cannot write.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_2"), "sessions", "Ghost.md" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Ghost/send", steve, "markdown=hello")));
    // The channel's member file is a folder: who may send cannot be read.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "ops.channel" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/channel/ops/Standup/send", steve, "markdown=hello")));
    // A member file that names no uid is malformed: the lookup is a 500 for
    // its landing, a topic's page and a pin, never the 404 of a channel
    // that is not the member's (O2: the Roc's lookup keeps the host's errors).
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "bad.channel" }), "1\nnot a uid\n", .{});
    try harness.writeTranscript(a, io, "channels/bad", "Standup", &.{"one"});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/channel/bad", steve)));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/channel/bad/Standup", steve)));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/channel/bad/Standup/pin", steve, "")));
    try testing.expect(!try harness.UidSite.disk.has(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "pinned-sessions", "bad" })));
    // The partner's name will not read: a DM's topic page and a send to it
    // are 500s, the title read before either, as the Zig's lookup read it.
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{"one"});
    const name_file = try std.fs.path.join(a, &.{ users.auth_root, "2", "name" });
    try std.Io.Dir.cwd().deleteFile(io, name_file);
    try std.Io.Dir.cwd().createDirPath(io, name_file);
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/c/1_2/Plans", steve)));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try postFailing(a, io, "/chat/c/1_2/Plans/send", steve, "markdown=hello")));
    try testing.expectEqual(@as(usize, 1), (try chat_codec.decodeChatFile(a, (try chat_paths.readTranscript(io, a, try chat_paths.dmConvDir(a, "1_2"), "Plans")).?)).len);
}

test "route: a links page whose links.md will not read is a 500, never the stub that says there are none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    // A folder where the links page goes: it cannot be read.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "links.md" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/links", steve)));
}

test "route: an images or code page whose feed will not read is a 500, never a page that says there is nothing (C7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    // Folders where the feeds go: neither can be read.
    for ([_][]const u8{ "images.md", "code.md" }) |name| try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", name }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/images", steve)));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/code", steve)));
}

test "route: a recent page whose channels will not list is a 500, never a feed with them left out (C7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    // A file where the channels' folder goes: who is in which cannot be read.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels" }), "", .{});
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/recent", steve)));
}

/// A request whose handler must fail: the router's error, and the 500 the
/// site would have sent (here, what went out before it).
fn askFailing(a: std.mem.Allocator, io: Io, method: []const u8, target: []const u8, cookies: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ method, target, cookies });
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    try testing.expect(std.meta.isError(router.route(&req, io, a, &b)));
    try out.writer.flush();
    return out.written();
}

test "a doc's save: a missing body is 400 and the doc is kept; a doc that is gone is 404; a full reading list is 413, never 'save failed' 500 (metal-vmm QUEUE 172)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const docs_store = @import("docs_store.zig");
    const reading_list = @import("reading_list.zig");
    const me = try harness.signedUid(a, try player.allocate(io, a, .literal("Ada")));
    const ada = try users.allocateUser(io, a, .literal("Ada"));
    try users.setUserPassword(io, a, ada, "a password for Ada");
    const cookies = try std.fmt.allocPrint(a, "{s}; __Host-gopher_auth={s}", .{ me, (try users.signSessionNow(io, a, ada)).? });
    const slug = try docs_store.createUserDoc(io, a, ada, "Notes");
    try docs_store.writeUserDoc(io, a, ada, slug, "what Ada wrote");
    const post = struct {
        fn f(al: std.mem.Allocator, i: Io, c: []const u8, path: []const u8, body: []const u8) ![]const u8 {
            return harness.serve(al, i, try std.fmt.allocPrint(al, "POST {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ path, c, body.len, body }));
        }
    }.f;

    const no_body = try post(a, io, cookies, "/chat/docs/save", try std.fmt.allocPrint(a, "slug={s}", .{slug}));
    try testing.expectEqualStrings("400 Bad Request", harness.status(no_body));
    try testing.expectEqualStrings("what Ada wrote", try docs_store.readUserDoc(io, a, ada, slug));

    const gone = try post(a, io, cookies, "/chat/docs/save", "slug=never-made&body=x");
    try testing.expectEqualStrings("404 Not Found", harness.status(gone));

    // A reading list at its cap: the next save is the client's limit.
    try docs_store.appendToUserDoc(io, a, ada, reading_list.reading_list_slug, &@as([reading_list.max_reading_list_bytes]u8, @splat('x')), 0);
    const full = try post(a, io, cookies, "/chat/docs/save_to_reading_list", "conv=1_2&sid=s&id=s_1&body=hello");
    try testing.expectEqualStrings("413 Payload Too Large", harness.status(full));
}

test "a gallery that cannot read pages/home.txt is a 500 that names it, never a 200 (metal-vmm QUEUE 172, as the home page's)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The tests run in zig-server/, where there is no pages/home.txt.
    if (Io.Dir.cwd().access(io, "pages/home.txt", .{})) |_| return error.SkipZigTest else |_| {}
    const got = try harness.get(a, io, "/gallery");
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(got));
    try testing.expect(std.mem.indexOf(u8, got, "could not be parsed") != null);
}

test "an llms.txt that cannot read pages/home.txt is a 500 that names it, never an empty list served" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The tests run in zig-server/, where there is no pages/home.txt.
    if (Io.Dir.cwd().access(io, "pages/home.txt", .{})) |_| return error.SkipZigTest else |_| {}
    const got = try harness.get(a, io, "/llms.txt");
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(got));
    try testing.expect(std.mem.indexOf(u8, got, "pages/home.txt could not be parsed: FileNotFound") != null);
}

test "an upload that cannot be stored gives its bytes back to the allowance: the quota is never spent on a file that is not there (metal-vmm QUEUE 172)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = @import("webbox").mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const me = try harness.signedUid(a, try player.allocate(io, a, .literal("Ada")));
    const ada = try users.allocateUser(io, a, .literal("Ada"));
    try users.setUserPassword(io, a, ada, "a password for Ada");
    const bo = try users.allocateUser(io, a, .literal("Bo"));
    try users.setUserPassword(io, a, bo, "a password for Bo");
    const cookies = try std.fmt.allocPrint(a, "{s}; __Host-gopher_auth={s}", .{ me, (try users.signSessionNow(io, a, ada)).? });
    const key = try std.fmt.allocPrint(a, "{s}_{s}", .{ ada, bo });
    const dm = try std.fmt.allocPrint(a, "/chat/c/{s}/scripts", .{key});
    const hello = "markdown=hello";
    _ = try harness.serve(a, io, try std.fmt.allocPrint(a, "POST {s}/send HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ dm, cookies, hello.len, hello }));
    // Where the topic's uploads go is a file: the upload cannot be stored.
    const updir = try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, key), "sessions", "scripts.uploads" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = updir, .data = "in the way" });
    const before = try users.userUploadBytes(io, a, ada);
    const png = "\x89PNG\r\n\x1a\n" ++ repeated("\x00", 64);
    const body = "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n" ++ png ++ "\r\n--B--\r\n";
    // The handler's error goes on to the host (site.zig answers it 500 and
    // hands it on to be logged): here, to the test.
    const got = harness.serve(a, io, try std.fmt.allocPrint(a, "POST {s}/upload HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: {d}\r\n\r\n{s}", .{ dm, cookies, body.len, body }));
    try testing.expect(std.meta.isError(got));
    try testing.expectEqual(before, try users.userUploadBytes(io, a, ada));
}

test "a release that can release nothing says so, never the page a release that deleted gets (metal-vmm QUEUE 172)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    // A member's id in the player cookie and no session (it lapsed): the
    // account is not this cookie's to release.
    const ada = try users.allocateUser(io, a, .literal("Ada"));
    try users.setUserPassword(io, a, ada, "a password for Ada");
    try player.mirror(io, a, ada, "Ada");
    const got = try harness.postAs(a, io, "/logout", try harness.signedUid(a, ada), "release=yes");
    try testing.expectEqualStrings("403 Forbidden", harness.status(got));
    try testing.expect(try users.principalExists(io, a, ada));
    // The logout half still happens (its cold review): every identity
    // cookie is cleared, as a logout without a release clears them.
    try testing.expect(std.mem.indexOf(u8, got, uid_cookie.cookie_name ++ "=; Path=/; Max-Age=0") != null);
}

/// `s` repeated `n` times, built at comptime (Zig 0.17 removed `s ** n`).
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        var a: [s.len * n]u8 = undefined;
        @setEvalBranchQuota(1000 + n);
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}

test "route: a chat request whose asker cannot be read is a 500, never a sign-in (the Roc router asks; the failure is kept and returned)" {
    // The Roc router asks the host who is asking (chat_router.zig `Who`), and
    // a C call cannot carry a Zig error: the error is kept and returned after
    // the call. Were it read as "not a member", a member whose session could
    // not be checked would be sent to sign in, and a disk that failed would
    // look like a signed-out browser.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator); // as above: presence outlives the test
    defer meter.restore();

    try users.setUserPassword(io, a, "2", "hunter2");
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const member = try std.fmt.allocPrint(a, "__Host-gopher_auth={s}", .{try users.signSession(a, harness.UidSite.secret, "2", now)});
    const fine = try harness.UidSite.ask(a, io, "/chat/conversations", member);
    try testing.expectEqualStrings("200 OK", harness.status(fine));

    // The member's password file, now a link to itself: checking it fails.
    // A POST: router.route's own look at the session before dispatch (a
    // legacy session moved on a GET) is a GET's alone, so this failure is
    // the chat's identity check's.
    const password = try std.fs.path.join(a, &.{ users.auth_root, "2", "password" });
    try std.Io.Dir.cwd().deleteFile(io, password);
    try std.Io.Dir.cwd().symLink(io, "password", password, .{});
    for ([_][]const u8{ "/chat/c/1_2/general/send", "/channel/ops/general/send" }) |target| {
        const answered = try postFailing(a, io, target, member, "markdown=hi");
        try testing.expect(std.mem.startsWith(u8, harness.status(answered), "500"));
    }
}

/// The bytes `method target` answered and the error the route returned, if
/// any, the Roc serving or, with `oracle`, the old Zig.
fn servedBy(a: std.mem.Allocator, io: Io, oracle: bool, method: []const u8, target: []const u8, cookies: []const u8) !struct { out: []const u8, err: ?anyerror } {
    const chat_router = @import("chat_router.zig");
    chat_router.test_oracle = oracle;
    defer chat_router.test_oracle = false;
    const raw = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 0\r\n\r\n", .{ method, target, cookies });
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    const err: ?anyerror = if (router.route(&req, io, a, &b)) |_| null else |e| e;
    try out.writer.flush();
    return .{ .out = out.written(), .err = err };
}

/// **THE ROC ANSWERS `method target` AS THE OLD ZIG DID**, byte for byte,
/// with its error or with none; the status, to say which it was.
fn asTheOldZig(a: std.mem.Allocator, io: Io, method: []const u8, target: []const u8, cookies: []const u8, status: []const u8) !void {
    const roc = try servedBy(a, io, false, method, target, cookies);
    const zig = try servedBy(a, io, true, method, target, cookies);
    if (!std.meta.eql(zig.err, roc.err) or !std.mem.eql(u8, zig.out, roc.out) or !std.mem.eql(u8, harness.status(roc.out), status)) {
        std.debug.print("{s} {s}: roc {?t} \"{s}\", zig {?t} \"{s}\", want {s}\n", .{ method, target, roc.err, harness.status(roc.out), zig.err, harness.status(zig.out), status });
        return error.TestUnexpectedResult;
    }
}

/// The bytes `method target` answered and the error the route returned, the
/// Roc serving or, with `oracle`, the old Zig.
fn answeredBy(a: std.mem.Allocator, io: Io, oracle: bool, method: []const u8, target: []const u8, cookies: []const u8) !struct { out: []const u8, err: anyerror } {
    const chat_router = @import("chat_router.zig");
    chat_router.test_oracle = oracle;
    defer chat_router.test_oracle = false;
    const raw = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Length: 0\r\n\r\n", .{ method, target, cookies });
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = Hub.init(io, a);
    var b = Bus.of(&hub);
    const err = if (router.route(&req, io, a, &b)) |_| return error.TestExpectedError else |e| e;
    try out.writer.flush();
    return .{ .out = out.written(), .err = err };
}

test "route: a malformed channel on its own route is the old Zig's answer, byte for byte, and its error (the Roc parses the member file and fails the request by its reason)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const file = try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "bad.channel" });
    try harness.writeTranscript(a, io, "channels/bad", "Standup", &.{"one"});
    var compared: usize = 0;
    for ([_][]const u8{ "1\nnot a uid\n", "1\n../../x\n", "1\n3 # Claude\n", "1\n2\n1\n", "007\n", "+7\n" }) |bad| {
        try harness.UidSite.disk.write(io, a, file, bad, .{});
        for ([_][2][]const u8{ .{ "GET", "/channel/bad" }, .{ "GET", "/channel/bad/Standup" }, .{ "GET", "/channel/bad/Standup/reactions" }, .{ "POST", "/channel/bad/Standup/pin" }, .{ "POST", "/channel/bad/new" } }) |ask| {
            const before = chat_paths.malformed_channels;
            const roc = try answeredBy(a, io, false, ask[0], ask[1], steve);
            const zig = try answeredBy(a, io, true, ask[0], ask[1], steve);
            try testing.expectEqual(error.MalformedChannel, roc.err);
            try testing.expectEqual(zig.err, roc.err);
            try testing.expectEqualStrings(zig.out, roc.out);
            try testing.expectEqualStrings("500 Internal Server Error", harness.status(roc.out));
            // Its own route refuses it; only a listing counts it.
            try testing.expectEqual(before, chat_paths.malformed_channels);
            compared += 1;
        }
    }
    try testing.expectEqual(@as(usize, 30), compared);
}

test "route: a topics folder that is not there is no topics; one that is a file fails the request (Host.list!: missing and failed are two answers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Ann");
    // 1_2 has no folder at all, 1_3 an empty one: both are the page that
    // offers a topic, as the old Zig's.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ try chat_paths.dmConvDir(a, "1_3"), "sessions" }));
    for ([_][]const u8{ "/chat/c/1_2", "/chat/c/1_3" }) |target| {
        const got = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{ target, steve }));
        try testing.expectEqualStrings("200 OK", harness.status(got));
    }
    // A folder of channels that is a file: /chat/msg cannot list them.
    const chat_store = @import("chat_store.zig");
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels" }), "", .{});
    const roc = try answeredBy(a, io, false, "GET", "/chat/msg/Standup_1", steve);
    try testing.expectEqual(error.NotDir, roc.err);
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(roc.out));
}

test "route: an account whose name or password will not read fails exactly the routes whose old Zig read it, with its error, byte for byte (Host.list_accounts! lists it as unreadable, Host.fail! fails on it); every other route answers as the old Zig did; never a name of \"\" or no such account" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{"one"});
    // Debbie's name a folder: there, and unreadable.
    const name = try std.fs.path.join(a, &.{ users.auth_root, "2", "name" });
    try harness.UidSite.disk.remove(io, a, name);
    try std.Io.Dir.cwd().createDirPath(io, name);
    const failed = "500 Internal Server Error";
    // Her DM's topics: the old Zig read her name for the title and failed
    // with its error (error.IsDir), byte for byte.
    try asTheOldZig(a, io, "GET", "/chat/c/1_2/Plans", steve, failed);
    try asTheOldZig(a, io, "POST", "/chat/c/1_2/Plans/pin", steve, failed);
    try asTheOldZig(a, io, "GET", "/chat/c/1_2/Plans/reactions", steve, failed);
    try testing.expectEqual(@as(?anyerror, error.IsDir), (try servedBy(a, io, false, "GET", "/chat/c/1_2/Plans/reactions", steve)).err);
    // The roster read a member's name: the conversations and a message's
    // topic fail as the old Zig's did.
    try asTheOldZig(a, io, "GET", "/chat/conversations", steve, failed);
    try asTheOldZig(a, io, "GET", "/chat/msg/Plans_1", steve, failed);
    // **WHAT NEVER READ HER NAME IS SERVED**, as the old Zig served it: the
    // DM's landing with a topic, and the member's own pages.
    try asTheOldZig(a, io, "GET", "/chat/c/1_2", steve, "303 See Other");
    try asTheOldZig(a, io, "GET", "/chat/links", steve, "200 OK");
    try asTheOldZig(a, io, "GET", "/chat/images", steve, "200 OK");
    try asTheOldZig(a, io, "GET", "/chat/code", steve, "200 OK");
    // The disk willing again: served.
    try std.Io.Dir.cwd().deleteTree(io, name);
    try users.setUserName(io, a, "2", "Debbie");
    const ok = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET /chat/conversations HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{steve}));
    try testing.expectEqualStrings("200 OK", harness.status(ok));
    try testing.expect(std.mem.indexOf(u8, ok, "Debbie") != null);

    // **A PASSWORD THAT CANNOT BE CHECKED** (a link to itself): only the
    // roster read it (listAuthorized, the agent's and a guest's too), so
    // the conversations and a message's topic fail with its error; her DM,
    // found by her folder and titled by her name, is served as before.
    const password = try std.fs.path.join(a, &.{ users.auth_root, "2", "password" });
    try std.Io.Dir.cwd().deleteFile(io, password);
    try std.Io.Dir.cwd().symLink(io, "password", password, .{});
    try asTheOldZig(a, io, "GET", "/chat/conversations", steve, failed);
    try asTheOldZig(a, io, "GET", "/chat/msg/Plans_1", steve, failed);
    try testing.expectEqual(@as(?anyerror, error.SymLinkLoop), (try servedBy(a, io, false, "GET", "/chat/conversations", steve)).err);
    try asTheOldZig(a, io, "GET", "/chat/c/1_2/Plans/reactions", steve, "200 OK");
    try asTheOldZig(a, io, "GET", "/chat/c/1_2", steve, "303 See Other");
    try asTheOldZig(a, io, "GET", "/chat/links", steve, "200 OK");
    try asTheOldZig(a, io, "GET", "/chat/images", steve, "200 OK");
}

test "route: a conversation's page fails where sidebarOf failed, with its error, byte for byte: an account the roster reads, the viewer's name, a channel's member file, the channels folder, a pins file that is a folder, topics that will not list; a malformed channel is skipped, never a failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const root = chat_store.chat_root;
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Ann");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{"one"});
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"one"});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ root, "channels", "ops.channel" }), "1\n2\n", .{});
    const ok = "200 OK";
    const failed = "500 Internal Server Error";
    const both = [_][]const u8{ "/chat/c/1_2/Plans", "/channel/ops/Standup" };
    for (both) |target| try asTheOldZig(a, io, "GET", target, steve, ok);

    // **A MALFORMED CHANNEL IN THE ROSTERS IS SKIPPED AND COUNTED**, never
    // the page's failure.
    const bad = try std.fs.path.join(a, &.{ root, "channels", "bad.channel" });
    try harness.UidSite.disk.write(io, a, bad, "1\n1\n", .{});
    for (both) |target| try asTheOldZig(a, io, "GET", target, steve, ok);
    try harness.UidSite.disk.remove(io, a, bad);

    // An account only the roster reads (Ann: in neither conversation), its
    // name a folder: both pages fail with its error.
    const ann_name = try std.fs.path.join(a, &.{ users.auth_root, "3", "name" });
    try harness.UidSite.disk.remove(io, a, ann_name);
    try std.Io.Dir.cwd().createDirPath(io, ann_name);
    for (both) |target| try asTheOldZig(a, io, "GET", target, steve, failed);
    try testing.expectEqual(@as(?anyerror, error.IsDir), (try servedBy(a, io, false, "GET", both[1], steve)).err);
    try std.Io.Dir.cwd().deleteTree(io, ann_name);
    try users.setUserName(io, a, "3", "Ann");
    // Its password a link to itself: the roster's stat of it fails.
    const ann_password = try std.fs.path.join(a, &.{ users.auth_root, "3", "password" });
    try std.Io.Dir.cwd().deleteFile(io, ann_password);
    try std.Io.Dir.cwd().symLink(io, "password", ann_password, .{});
    for (both) |target| try asTheOldZig(a, io, "GET", target, steve, failed);
    try testing.expectEqual(@as(?anyerror, error.SymLinkLoop), (try servedBy(a, io, false, "GET", both[0], steve)).err);
    try std.Io.Dir.cwd().deleteFile(io, ann_password);
    try users.setUserPassword(io, a, "3", "pw");
    for (both) |target| try asTheOldZig(a, io, "GET", target, steve, ok);

    // The viewer's own name a folder: a channel's page reads it first.
    const steve_name = try std.fs.path.join(a, &.{ users.auth_root, "1", "name" });
    try harness.UidSite.disk.remove(io, a, steve_name);
    try std.Io.Dir.cwd().createDirPath(io, steve_name);
    try asTheOldZig(a, io, "GET", both[1], steve, failed);
    try std.Io.Dir.cwd().deleteTree(io, steve_name);
    try users.setUserName(io, a, "1", "Steve");

    // A member file of another channel that is a folder: it will not read.
    const gone = try std.fs.path.join(a, &.{ root, "channels", "gone.channel" });
    try std.Io.Dir.cwd().createDirPath(io, gone);
    for (both) |target| try asTheOldZig(a, io, "GET", target, steve, failed);
    try std.Io.Dir.cwd().deleteTree(io, gone);

    // **A PINS FILE THAT IS A FOLDER IS NEVER NO PINS**.
    const pins = try std.fs.path.join(a, &.{ root, "users", "1", "pinned-sessions", "1_2" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ pins, "kept" }));
    try asTheOldZig(a, io, "GET", both[0], steve, failed);
    try testing.expectEqual(@as(?anyerror, error.IsDir), (try servedBy(a, io, false, "GET", both[0], steve)).err);
    try std.Io.Dir.cwd().deleteTree(io, pins);
    try asTheOldZig(a, io, "GET", both[0], steve, ok);

    // Topics that will not list: the conversation's sessions folder a file.
    const sessions = try std.fs.path.join(a, &.{ root, "channels", "ops", "sessions" });
    try std.Io.Dir.cwd().deleteTree(io, sessions);
    try harness.UidSite.disk.write(io, a, sessions, "", .{});
    try asTheOldZig(a, io, "GET", both[1], steve, failed);
    try testing.expectEqual(@as(?anyerror, error.NotDir), (try servedBy(a, io, false, "GET", both[1], steve)).err);

    // The channels folder a file: no member's channels can be listed.
    try harness.UidSite.disk.remove(io, a, sessions);
    try harness.writeTranscript(a, io, "channels/ops", "Standup", &.{"one"});
    const channels = try std.fs.path.join(a, &.{ root, "channels" });
    try std.Io.Dir.cwd().deleteTree(io, channels);
    try harness.UidSite.disk.write(io, a, channels, "", .{});
    try asTheOldZig(a, io, "GET", both[0], steve, failed);
    try testing.expectEqual(@as(?anyerror, error.NotDir), (try servedBy(a, io, false, "GET", both[0], steve)).err);
}

test "route: /chat/msg skips a malformed channel and counts it for /admin/host; a roster that will not read is a 500, never a topic not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try harness.UidSite.init(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    // The rosters are the host's to read and its bookkeeping the operator's
    // (the Roc decides only which are the member's): a malformed channel
    // that would be first by bytes is skipped, counted and named, and the
    // next of the member's answers.
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "Abad.channel" }), "1\nnot a uid\n", .{});
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "ops.channel" }), "1\n", .{});
    for ([_][]const u8{ "channels/Abad", "channels/ops" }) |d| try harness.writeTranscript(a, io, d, "Standup", &.{"one"});
    const before = chat_paths.malformed_channels;
    const got = try harness.serve(a, io, try std.fmt.allocPrint(a, "GET /chat/msg/Standup_1 HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{steve}));
    try testing.expectEqualStrings("302 Found", harness.status(got));
    try testing.expectEqualStrings("/channel/ops/Standup#msg-Standup_1", harness.responseHeader(got, "Location").?);
    try testing.expectEqual(before + 1, chat_paths.malformed_channels);
    try testing.expectEqualStrings("Abad", chat_paths.malformed_last);
    // A member file that is a folder will not read at all: the request's failure.
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "gone.channel" }));
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/msg/Standup_1", steve)));
}

// ── one bad byte is not a lasting 500 (metal-vmm QUEUE 267) ──────────────────
//
// The other side of this file's rule: what the request must understand and
// cannot is its 500, but one damaged entry, row, account or file among many
// is its own, skipped (and counted) or kept to its own lookup, never a page
// down for everyone.

fn site(a: std.mem.Allocator, io: Io) !harness.UidSite {
    return harness.UidSite.init(a, io);
}

test "route: a torn feed entry, a torn recent row and a member file that is not UTF-8 are each skipped and counted, and the page served (metal-vmm QUEUE 267)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try site(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const chat_store = @import("chat_store.zig");
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    const before = chat_paths.dropped;
    const head = "Sent by Debbie at 2026-10-10T00:00:00Z, source MSG_Plans_{d} in 1_2:\n";
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1", "images.md" }), std.fmt.comptimePrint(head, .{1}) ++ "<img src=\"/a.png\">\n\n-------------\n\n" ++ std.fmt.comptimePrint(head, .{2}) ++ "<img src=\"/\xf0\x9f.png\">", .{});
    const images = try harness.UidSite.ask(a, io, "/chat/images", steve);
    try testing.expectEqualStrings("200 OK", harness.status(images));
    try testing.expect(std.mem.indexOf(u8, images, "Plans_1") != null and std.mem.indexOf(u8, images, "Plans_2") == null);
    try testing.expectEqual(before.get(.feed_entry) + 1, chat_paths.dropped.get(.feed_entry));
    // A row whose text is not UTF-8 (here its author's stored name, which
    // names the row and labels the DM): that row is left out, the rest served.
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try testing.expectEqualStrings("303 See Other", harness.status(try harness.postAs(a, io, "/chat/c/1_2/Plans/send", debbie, "markdown=fine&cid=x")));
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, "2", "name" }), "Deb\xc3", .{});
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, "/chat/recent", steve)));
    try testing.expectEqual(before.get(.recent_row) + 1, chat_paths.dropped.get(.recent_row));
    // A channel's member file that is not UTF-8 is malformed, skipped and
    // counted by every listing, and /chat/recent still served.
    const malformed = chat_paths.malformed_channels;
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "bad.channel" }), "1\n\xff\n", .{});
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, "/chat/recent", steve)));
    try testing.expect(chat_paths.malformed_channels > malformed);
}

test "route: an account whose name is not UTF-8 fails only a lookup of that name, never every member's chat (metal-vmm QUEUE 267)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try site(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    _ = try harness.memberSession(a, io, "3", "Ann");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    try harness.UidSite.disk.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, "3", "name" }), "A\xffn", .{});
    // A page that never reads Ann's name is served: the listing of every
    // account is not failed by hers.
    try testing.expectEqualStrings("200 OK", harness.status(try harness.UidSite.ask(a, io, "/chat/images", steve)));
    // His DM with Ann is titled by her name: that lookup alone fails.
    try testing.expectEqualStrings("500 Internal Server Error", harness.status(try askFailing(a, io, "GET", "/chat/c/1_3", steve)));
}

test "route: a DM's new topic whose announcement will not store is made all the same, 200, the drop counted, never a 500 whose retry is a 409 (metal-vmm QUEUE 267)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try site(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    // general2 is a topic (the list keeps all but folders) that nothing can
    // be appended to: a link into a folder that is not there.
    const dir = try chat_paths.dmConvDir(a, "1_2");
    try std.Io.Dir.cwd().symLink(io, "nowhere/general2.md", try std.fs.path.join(a, &.{ dir, "sessions", "general2.md" }), .{});
    const before = chat_paths.dropped.get(.announcement);
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Ideas")));
    try testing.expectEqual(before + 1, chat_paths.dropped.get(.announcement));
    try testing.expect((try chat_paths.readTranscript(io, a, dir, "Ideas")) != null);
    // The topic is there, so a second make of it is the 409 it should be.
    try testing.expectEqualStrings("409 Conflict", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Ideas")));
}

test "route: a send too big for its form is the host's 413 and the whole answer: nothing stored, and one response, never a second (metal-vmm QUEUE 268)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var uid_site = try site(a, io);
    defer uid_site.deinit();
    const meter = mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    try testing.expectEqualStrings("200 OK", harness.status(try harness.postAs(a, io, "/chat/c/1_2/new", steve, "topic=Plans")));
    const dir = try chat_paths.dmConvDir(a, "1_2");
    const before = (try chat_paths.readTranscript(io, a, dir, "Plans")).?;
    const big = try a.alloc(u8, 70 * 1024);
    @memset(big, 'x');
    const got = try harness.postAs(a, io, "/chat/c/1_2/Plans/send", steve, try std.fmt.allocPrint(a, "markdown={s}&cid=x", .{big}));
    try testing.expectEqualStrings("413 Payload Too Large", harness.status(got));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "HTTP/1.1 "));
    try testing.expectEqualStrings(before, (try chat_paths.readTranscript(io, a, dir, "Plans")).?);
}
