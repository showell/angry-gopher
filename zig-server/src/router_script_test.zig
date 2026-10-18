//! router.zig's tests: the script route.

const std = @import("std");
const Io = @import("host_io").Io;
const users = @import("users.zig");
const mem_meter = @import("webbox").mem_meter;
const webbox_site = @import("webbox").site;
const search_index = @import("search_index.zig");
const testing = std.testing;
const harness = @import("router_harness.zig");
const router = @import("router.zig");

// ── the script route (metal-vmm QUEUE 200) ──────────────────────────────────

fn scriptDurable() bool {
    return true;
}

/// A signed script's request: `body` the envelope, `auth` the header line.
fn scriptRequest(a: std.mem.Allocator, auth: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "POST /admin/script HTTP/1.1\r\nHost: x\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ auth, body.len, body });
}

test "route: a signed script deletes a topic, memory follows the store (search finds it no more), and each lock refuses alone (metal-vmm 200)" {
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
    const chat_search = @import("chat_search.zig");
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    const forgot = chat_search.forgetForTest();
    defer forgot.end();
    const store = @import("webbox").store;
    const script_route = @import("shale").script_route;
    const Ed25519 = std.crypto.sign.Ed25519;
    store.durable_now = scriptDurable;
    defer store.durable_now = null;

    const me = try harness.memberSession(a, io, "1", "Steve");
    _ = try harness.memberSession(a, io, "2", "Debbie");
    const key = try users.setUserAPIKey(io, a, "1");
    const debbie_key = try users.setUserAPIKey(io, a, "2");
    const bearer = try std.fmt.allocPrint(a, "Authorization: Bearer {s}\r\n", .{key});
    try harness.writeTranscript(a, io, "1_2", "ChitChat", &.{"the zebra crossing"});
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/messages?word=zebra", me), "\"matched\":1,") != null);

    const kp = try Ed25519.KeyPair.generateDeterministic(@splat(3));
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const src = "remove(\"chat/1_2/sessions/ChitChat.md\")\nprint(\"deleted\")\n";
    // Numbered past the clock, as the signer numbers: setting the key
    // raises the sequence to the clock's seconds.
    const signed = try script_route.signedBytes(a, "test.example", @intCast(now + 60), now + 300, src);
    const body = try script_route.envelope(a, (try kp.sign(signed, null)).toBytes(), signed);

    // No key configured: refused, never open.
    const no_key = try harness.serve(a, io, try scriptRequest(a, bearer, body));
    try testing.expectEqualStrings("403 Forbidden", harness.status(no_key));
    try testing.expect(std.mem.indexOf(u8, no_key, "refused (no_key)") != null);
    // The key set on the admin's page, the password typed again: a wrong
    // one sets nothing.
    const hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    for ([_][]const u8{ "nope", "pw" }, [_][]const u8{ "403 Forbidden", "200 OK" }) |pw, want| {
        const form = try std.fmt.allocPrint(a, "public_key={s}&target=test.example&password={s}", .{ &hex, pw });
        const set = try harness.serve(a, io, try std.fmt.allocPrint(a, "POST /admin/script-key HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ me, form.len, form }));
        try testing.expectEqualStrings(want, harness.status(set));
        if (std.mem.eql(u8, pw, "nope")) try testing.expectEqualStrings("403 Forbidden", harness.status(try harness.serve(a, io, try scriptRequest(a, bearer, body))));
    }

    // Numbered before the key was set: refused, so nothing signed before a
    // key is set again (the sequence lost, say) runs after it.
    const early = try script_route.signedBytes(a, "test.example", 1, now + 300, src);
    const stale = try harness.serve(a, io, try scriptRequest(a, bearer, try script_route.envelope(a, (try kp.sign(early, null)).toBytes(), early)));
    try testing.expectEqualStrings("409 Conflict", harness.status(stale));

    // The first lock: no bearer, a session cookie instead, another's key.
    try testing.expectEqualStrings("401 Unauthorized", harness.status(try harness.serve(a, io, try scriptRequest(a, "", body))));
    try testing.expectEqualStrings("401 Unauthorized", harness.status(try harness.serve(a, io, try scriptRequest(a, try std.fmt.allocPrint(a, "Cookie: {s}\r\n", .{me}), body))));
    try testing.expectEqualStrings("403 Forbidden", harness.status(try harness.serve(a, io, try scriptRequest(a, try std.fmt.allocPrint(a, "Authorization: Bearer {s}\r\n", .{debbie_key}), body))));
    // The second: the admin's key, with a script signed by another key.
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(4));
    const forged = try harness.serve(a, io, try scriptRequest(a, bearer, try script_route.envelope(a, (try other.sign(signed, null)).toBytes(), signed)));
    try testing.expectEqualStrings("403 Forbidden", harness.status(forged));
    try testing.expect(std.mem.indexOf(u8, forged, "refused (bad_signature)") != null);
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/messages?word=zebra", me), "\"matched\":1,") != null);

    // Both: it runs, the topic is gone, and so is it from search.
    const ran = try harness.serve(a, io, try scriptRequest(a, bearer, body));
    try testing.expectEqualStrings("200 OK", harness.status(ran));
    try testing.expect(std.mem.indexOf(u8, ran, "deleted\n── effects (1) ──\nremove chat/1_2/sessions/ChitChat.md: ok\n── finished (") != null);
    try testing.expect(std.mem.indexOf(u8, ran, "── memory rebuilt from the store in ") != null);
    try testing.expect(std.mem.indexOf(u8, try harness.UidSite.ask(a, io, "/chat/search/messages?word=zebra", me), "\"matched\":0,") != null);
    // Sent again: a replay.
    const again = try harness.serve(a, io, try scriptRequest(a, bearer, body));
    try testing.expectEqualStrings("409 Conflict", harness.status(again));
    try testing.expect(std.mem.indexOf(u8, again, "refused (replayed)") != null);
}

test "route: a background script is answered at once, stepped by the Site between requests to its end, read back on GET; a second is refused while one runs; kill ends one; an atomic one is answered as ever (metal-vmm QUEUE 222)" {
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
    const store = @import("webbox").store;
    const script_route = @import("shale").script_route;
    const Ed25519 = std.crypto.sign.Ed25519;
    store.durable_now = scriptDurable;
    defer store.durable_now = null;

    const me = try harness.memberSession(a, io, "1", "Steve");
    const key = try users.setUserAPIKey(io, a, "1");
    const bearer = try std.fmt.allocPrint(a, "Authorization: Bearer {s}\r\n", .{key});
    try harness.writeTranscript(a, io, "1_2", "ChitChat", &.{"the zebra crossing"});
    const kp = try Ed25519.KeyPair.generateDeterministic(@splat(5));
    const hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    const form = try std.fmt.allocPrint(a, "public_key={s}&target=test.example&password=pw", .{&hex});
    try testing.expectEqualStrings("200 OK", harness.status(try harness.serve(a, io, try std.fmt.allocPrint(a, "POST /admin/script-key HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ me, form.len, form }))));
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    var seq: u64 = @intCast(now + 60);
    const send = struct {
        fn f(al: std.mem.Allocator, i: std.Io, k: Ed25519.KeyPair, b: []const u8, n: *u64, mode: script_route.Mode, src: []const u8) ![]const u8 {
            n.* += 1;
            const at: i64 = @intCast(@divFloor(Io.Clock.now(.real, i).nanoseconds, std.time.ns_per_s));
            const signed = try script_route.signedBytesIn(al, "test.example", n.*, at + 300, mode, src);
            return harness.serve(al, i, try scriptRequest(al, b, try script_route.envelope(al, (try k.sign(signed, null)).toBytes(), signed)));
        }
    }.f;
    const reads = "for e in walk(\"chat\", {like = \"*.md\"}) do print(e.path) end\nprint(read(\"chat/1_2/sessions/ChitChat.md\", 0, 5))\n";
    const get_status = try std.fmt.allocPrint(a, "GET /admin/script HTTP/1.1\r\nHost: x\r\n{s}\r\n", .{bearer});

    // Before any host has stepped one, a background run is refused, not left unrun.
    const unstepped = try send(a, io, kp, bearer, &seq, .background, reads);
    try testing.expectEqualStrings("501 Not Implemented", harness.status(unstepped));
    try testing.expect(std.mem.indexOf(u8, unstepped, "refused (no_background)") != null);
    // A host steps: between, as webbox's hosts call it, with no run going.
    const at: webbox_site.Now = .{ .awake_ns = 0, .unix_s = now };
    try testing.expectEqual(webbox_site.Wake.idle, router.between(io, at));

    // Started: answered at once; a second while it runs is refused.
    const first = try send(a, io, kp, bearer, &seq, .background, reads);
    try testing.expectEqualStrings("202 Accepted", harness.status(first));
    const second = try send(a, io, kp, bearer, &seq, .background, reads);
    try testing.expectEqualStrings("503 Service Unavailable", harness.status(second));
    try testing.expect(std.mem.indexOf(u8, second, "refused (busy)") != null);
    try testing.expect(std.mem.indexOf(u8, try harness.serve(a, io, get_status), " running: ") != null);
    // Killed: its state says so, and a kill with none going is refused.
    try testing.expectEqualStrings("200 OK", harness.status(try send(a, io, kp, bearer, &seq, .kill, "")));
    try testing.expect(std.mem.indexOf(u8, try harness.serve(a, io, get_status), " running: ") == null);
    try testing.expectEqualStrings("409 Conflict", harness.status(try send(a, io, kp, bearer, &seq, .kill, "")));

    // Another, stepped between requests to its end, its output read back.
    try testing.expectEqualStrings("202 Accepted", harness.status(try send(a, io, kp, bearer, &seq, .background, reads)));
    var slices: usize = 0;
    while (router.between(io, at) == .more) : (slices += 1) try testing.expect(slices < 100);
    const done = try harness.serve(a, io, get_status);
    try testing.expectEqualStrings("200 OK", harness.status(done));
    try testing.expect(std.mem.indexOf(u8, done, " finished") != null);
    try testing.expect(std.mem.indexOf(u8, done, "chat/1_2/sessions/ChitChat.md\nMSG_C\n") != null);
    // The status is the admin's only.
    try testing.expectEqualStrings("401 Unauthorized", harness.status(try harness.serve(a, io, "GET /admin/script HTTP/1.1\r\nHost: x\r\n\r\n")));

    // An atomic run: answered whole, as ever.
    const atomic = try send(a, io, kp, bearer, &seq, .atomic, "print(\"hi\")\n");
    try testing.expectEqualStrings("200 OK", harness.status(atomic));
    try testing.expect(std.mem.indexOf(u8, atomic, "hi\n") != null);
}
