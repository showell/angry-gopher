//! **BACKLOG XOR LIVE, ON LINUX** (the pure-Roc chat plan, item 1): a
//! topic's stream reads its transcript, then subscribes to the topic's bus
//! key. A message sent between the two would be in neither: past the read,
//! and published before anyone heard. Nothing holds the two together but
//! webbox's Linux host, which runs one handler at a time (`turn`,
//! zig-webbox linux_host.zig). Here the real host serves real connections,
//! and a send arrives while the stream's handler stands in that window
//! (`chat_store.test_window`): it waits for the turn, and lands live, once.
//! The control lets the turn go across the window: the send lands inside
//! it and the stream never sees it, so the check can see the race it
//! guards against.

const std = @import("std");
const Io = @import("host_io").Io;
const net = std.Io.net;
const webbox = @import("webbox");
const linux_host = @import("webbox_linux").linux_host;
const router = @import("router.zig");
const harness = @import("router_harness.zig");
const chat_store = @import("chat_store.zig");
const chat_codec = @import("chat_codec.zig");
const testing = std.testing;

const Host = linux_host.Server(router);

fn sleep(io: Io, ms: i64) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
}

/// A connection's bytes as they arrive, read on a thread of its own.
const Received = struct {
    buf: [64 * 1024]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn read(self: *Received, io: Io, stream: net.Stream) void {
        defer self.done.store(true, .release);
        var rbuf: [4096]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        while (true) {
            r.interface.fillMore() catch return;
            const got = r.interface.buffered();
            const at = self.len.load(.monotonic);
            const n = @min(got.len, self.buf.len - at);
            @memcpy(self.buf[at..][0..n], got[0..n]);
            r.interface.tossBuffered();
            self.len.store(at + n, .release);
            if (n < got.len) return;
        }
    }

    fn bytes(self: *Received) []const u8 {
        return self.buf[0..self.len.load(.acquire)];
    }

    /// Whether `want` has arrived, waiting at most `ms` for it.
    fn holds(self: *Received, io: Io, want: []const u8, ms: i64) bool {
        var waited: i64 = 0;
        while (waited < ms) : (waited += 10) {
            if (std.mem.indexOf(u8, self.bytes(), want) != null) return true;
            if (self.done.load(.acquire)) break;
            sleep(io, 10);
        }
        return std.mem.indexOf(u8, self.bytes(), want) != null;
    }
};

fn serve(io: Io, hub: *webbox.bus.Hub, stream: net.Stream) void {
    Host.for_tests.serveConn(io, std.heap.page_allocator, hub, stream);
}

/// A client: its connection served by the host on a thread of its own, the
/// request sent, and what comes back read on another.
const Client = struct {
    stream: net.Stream,
    served: std.Thread,
    reading: std.Thread,

    fn open(io: Io, listener: *net.Server, hub: *webbox.bus.Hub, raw: []const u8, got: *Received) !Client {
        const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
        const served = try std.Thread.spawn(.{}, serve, .{ io, hub, try listener.accept(io) });
        var w = stream.writer(io, &.{});
        try w.interface.writeAll(raw);
        const reading = try std.Thread.spawn(.{}, Received.read, .{ got, io, stream });
        return .{ .stream = stream, .served = served, .reading = reading };
    }

    /// The client hangs up; the host's task and the reader end.
    fn end(self: *Client, io: Io) void {
        self.stream.shutdown(io, .both) catch {};
        self.served.join();
        self.reading.join();
        self.stream.close(io);
    }
};

/// The send, made from inside the stream's window: connected, sent, and
/// whether its answer came while the window was open.
const Window = struct {
    listener: *net.Server,
    hub: *webbox.bus.Hub,
    send: []const u8,
    /// The control: the turn let go across the window.
    let_go: bool,
    sender: ?Client = null,
    answer: Received = .{},
    answered_inside: bool = false,
};

var window: ?*Window = null;

fn inWindow(io: Io) void {
    const w = window orelse return;
    window = null;
    w.sender = Client.open(io, w.listener, w.hub, w.send, &w.answer) catch |e|
        std.debug.panic("the send could not connect: {t}", .{e});
    if (w.let_go) linux_host.for_tests.turn.unlock(io);
    // A host that let the send in would answer it well inside a second;
    // with the turn let go, it is waited for.
    w.answered_inside = w.answer.holds(io, "HTTP/1.1 ", if (w.let_go) 10_000 else 1_000);
    if (w.let_go) linux_host.for_tests.turn.lockUncancelable(io);
}

/// Each `id:` a stream's frames carry, in order.
fn idsIn(a: std.mem.Allocator, bytes: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "id: ")) continue;
        try out.append(a, try std.fmt.parseInt(usize, line["id: ".len..], 10));
    }
    return out.items;
}

/// One race: a topic of two messages; Steve opens its stream; inside the
/// window, Debbie sends a third. What the stream carried, whether the send
/// was answered inside the window, and how many messages the transcript
/// holds after.
fn race(a: std.mem.Allocator, io: Io, let_go: bool) !struct { ids: []const usize, answered_inside: bool, stored: usize } {
    var site = try harness.UidSite.init(a, io);
    defer site.deinit();
    const steve = try harness.memberSession(a, io, "1", "Steve");
    const debbie = try harness.memberSession(a, io, "2", "Debbie");
    try harness.writeTranscript(a, io, "1_2", "Plans", &.{ "one", "two" });
    @import("presence.zig").forgetForTest();
    var hub = webbox.bus.Hub.init(io, std.heap.page_allocator);
    defer hub.entries.deinit(std.heap.page_allocator);
    const any: net.IpAddress = try .parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const body = "markdown=three";
    var w: Window = .{
        .listener = &listener,
        .hub = &hub,
        .send = try std.fmt.allocPrint(a, "POST /chat/c/1_2/Plans/send HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ debbie, body.len, body }),
        .let_go = let_go,
    };
    window = &w;
    chat_store.test_window = inWindow;
    defer {
        chat_store.test_window = null;
        window = null;
    }

    var got: Received = .{};
    var stream = try Client.open(io, &listener, &hub, try std.fmt.allocPrint(a, "GET /chat/c/1_2/Plans/stream HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\n\r\n", .{steve}), &got);
    // The send is answered once the stream's handler has let the turn go,
    // and its frame then reaches a stream that heard it.
    if (!got.holds(io, "id: 1\n", 10_000)) return error.NoBacklog;
    while (w.sender == null) sleep(io, 10);
    if (!w.answer.holds(io, "HTTP/1.1 ", 10_000)) return error.SendNeverAnswered;
    _ = got.holds(io, "id: 2\n", 2_000);
    const ids = try a.dupe(usize, try idsIn(a, got.bytes()));
    stream.end(io);
    w.sender.?.end(io);

    const raw = try webbox.store.read(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "1_2", "sessions", "Plans.md" }), .unlimited);
    return .{ .ids = ids, .answered_inside = w.answered_inside, .stored = (try chat_codec.decodeChatFile(a, raw)).len };
}

test "a topic's stream on Linux: a message sent while the stream stands between its read and its subscribe waits for the turn and lands live, once; with the turn let go across that window it lands in neither, so the check sees the race" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const meter = webbox.mem_meter.useForTest(std.heap.page_allocator);
    defer meter.restore();

    const held = try race(a, io, false);
    try testing.expect(!held.answered_inside);
    try testing.expectEqual(@as(usize, 3), held.stored);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, held.ids);

    const let_go = try race(a, io, true);
    try testing.expect(let_go.answered_inside);
    try testing.expectEqual(@as(usize, 3), let_go.stored);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, let_go.ids);
}
