//! router: WHAT THIS SITE SERVES. One function — `route` — from a request to a
//! response, over a path-prefix table with one arm per surface.
//!
//! It is separate from server.zig because that file is HOW THIS PROCESS STARTS:
//! a page allocator, a thread pool, an environment, a config file, a socket. A
//! route table needs none of those. It needs a request, an Io, an allocator and
//! the pub/sub bus, and every one of those can come from somewhere other than
//! Linux — which is the point. zig-metal-unikernel boots the same application on a
//! machine with no operating system, and until this split it had to skip the
//! routing entirely and call one page's handler by hand, because the table was
//! welded to the thing that owned the socket.
//!
//! The rule that keeps it that way: **nothing in this file may reach for the
//! host.** No std.process, no listener, no allocator policy, no clock it did not
//! receive. If a handler needs one of those it takes it as a parameter, the way
//! every handler here takes `io`.
//!
//! A second thing falls out: a route table you can call is a route table you can
//! test, without a socket.

const std = @import("std");
const Io = @import("host_io").Io;
const http = @import("webbox").http;
const driving = @import("driving.zig");
const delivery = @import("delivery.zig");
const chess = @import("chess.zig");
const puzzles = @import("puzzles.zig");
const game = @import("game.zig");
const chat = @import("chat.zig");
const settings = @import("settings.zig");
const admin = @import("admin.zig");
const admin_lynrummy = @import("admin_lynrummy.zig");
const home = @import("home.zig");
const llms_txt = @import("llms_txt.zig");
const gallery = @import("gallery.zig");
const downloads = @import("downloads.zig");
const resume_page = @import("resume_page.zig");
const safari_download = @import("safari_download.zig");
const shale_page = @import("shale_page.zig");
const login = @import("login.zig");
const player = @import("player.zig");
const brand = @import("brand.zig");
const users = @import("users.zig");
const uid_cookie = @import("uid_cookie.zig");
const client_address = @import("webbox").client_address;
const free_space = @import("webbox").free_space;
// ── THE HOST CONTRACT ────────────────────────────────────────────────────────
//
// webbox's site.zig says it, three calls (Steve, 2026-10-10: one call for the
// setup, not a list a host follows by hand): `mem_meter.init(base)`,
// `start(io, Host)`, then per request `route` and serve what it answered. A
// kernel that boots this table has no other contact with the application, so
// everything a host calls is exported from here, by the names both hosts use.
// server.zig does these for Linux, zig-metal-unikernel's kernel with its own heap
// and paths on its own volume.

/// The streaming seam: Hub, Bus (part of `route`'s signature), Kept, and the
/// two ways to serve a kept stream.
pub const streams = @import("webbox").bus;
pub const Bus = streams.Bus;
pub const Hub = streams.Hub;
pub const mem_meter = @import("webbox").mem_meter;
/// The setup as one call (site.zig's `start`, around this application's own:
/// app_start.zig): contract step 2.
pub const start = site.start;
pub const Started = site.Started;
pub const Host = webbox_site.Host;
/// **ONLY WHAT A HOST NEEDS IS EXPORTED**: the types `Host` is made of and a
/// host's facts are written in. The setup's modules (roots, the stores, the
/// search index, the game limits) are not, so nothing but `start` sets them.
pub const Roots = webbox_site.Roots;
pub const Space = free_space.Space;
/// Where the game store is, for a host to read the free space of its volume
/// (read only).
pub const dataRoot = game_limits.dataRoot;
/// /admin/host's host half (host_facts.zig): what a host's facts are made of,
/// and the two ways it writes a time; `start` hands its report over.
pub const host_facts = struct {
    pub const Fact = facts.Fact;
    pub const utc = facts.utc;
    pub const duration = facts.duration;
    const facts = @import("webbox").host_facts;
};
const webbox_site = @import("webbox").site;
const app_start = @import("app_start.zig");
/// Every bound on what a request may bring (limits.zig): a host sizes its
/// request-head buffer from `request_limits.head_bytes`.
pub const request_limits = @import("limits.zig");
/// The game store's bounds (zig-metal-unikernel QUEUE item 52), and where the game
/// store is (`dataRoot`).
const game_limits = @import("game_limits.zig");
/// The edge's refusal counts, which /version reports: a host counts what it
/// refuses before the route table sees a request (`edge.count(.header_too_large)`
/// for a head past its read buffer), in the same counters the routes use.
pub const edge = @import("webbox").edge;
/// **THIS APPLICATION, AS A HOST TAKES IT** (Phase B step 1): `site`, the
/// library's `Site(App)` around this application (start, route, the body
/// rule's two questions), and `hosting`, what only the application can say
/// to a host about itself. A host imports the application's root as a module
/// and the library as `webbox`, and reaches nothing else of either.
///
/// **WHAT ELSE THE SITE SERVES** (webbox's combo): Codex Chat and Damian's UO
/// town (cobble-webbox), public and ungated, each under its own prefix with
/// its own files under it in the data and auth roots. Neither passes through
/// this application's cookies or refusals, and each is counted under its own
/// name.
pub const site = combined.site;
pub const hosting = combined.hosting;
const combined = @import("webbox").combo.Mount(gopher, &.{
    .{ .prefix = "/codex-chat", .root = @import("codex_chat") },
    .{ .prefix = "/uo", .root = @import("uo_town") },
});
/// This application alone, as `Mount` takes its primary.
const gopher = struct {
    pub const site = webbox_site.Site(App);
    pub const hosting = gopher_hosting;
};
const gopher_hosting = struct {
    /// What its data is called, where a host names it (zig-metal-unikernel's
    /// console and /admin/host).
    pub const data_name = "chat's data";
    /// The largest upload a plain GET reads whole; a bigger one is streamed.
    /// A host with a page cache keeps files up to this by default, so what it
    /// keeps and what is read whole are one line.
    pub const whole_read_max = @import("chat_upload.zig").whole_read_max;
    /// The largest file worth keeping whole in a page cache: its largest
    /// picture. A cache told to keep bigger ones keeps nothing more.
    pub const cache_largest_most = request_limits.body.upload_image;
    /// Its setup's report, a line each, for the host's log. It fits a host's
    /// 1 KiB buffer; past it is a bug here, and a host stops on it.
    pub fn describeStart(r: app_start.StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return app_start.describeStart(r, w);
    }
};

/// **THIS APPLICATION, AS THE LIBRARY SERVES IT** (webbox's site.zig): its
/// route table is `dispatch`, private, so no host calls the table without the
/// serving around it. A malformed form is the client's mistake, a 400, on
/// every form (metal-vmm QUEUE 156(i)): one decoder (http.formField), where
/// chat's own took a bad escape as text and the first of two fields, while
/// players' refused the escape as a 500.
const App = struct {
    pub const routes = dispatch;
    pub const family = familyOf;
    pub const setup = app_start.setup;
    pub const StartReport = app_start.StartReport;
    pub const bodyLimit = routeBodyLimit;
    pub const uploader = uploaderOf;
    pub const between = betweenRequests;
};

/// **WHICH PART OF THE SITE A REQUEST IS FOR** (metal-vmm QUEUE 189.5), as
/// /admin/host counts them: an upload (posted or fetched), a live stream,
/// docs, the rest of chat, the games, the admin pages, or the site around
/// them (the home page, sign-in, assets).
pub const Family = enum { uploads, streams, docs, chat, games, admin, site };

/// **BETWEEN REQUESTS**: a slice of the operator's background script
/// (admin_script.zig, metal-vmm QUEUE 222), while it has more.
fn betweenRequests(io: Io, unix_s: i64) bool {
    return @import("admin_script.zig").between(io, unix_s);
}

fn familyOf(path: []const u8) Family {
    if (http.pathUnder(path, "/admin") != null) return .admin;
    const in_chat = http.pathUnder(path, "/chat") orelse http.pathUnder(path, "/channel");
    if (in_chat) |sub| {
        // As routeBodyLimit reads an upload: `.../upload/` is the upload.
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, sub, "/"), "/upload") or std.mem.indexOf(u8, sub, "/uploads/") != null) return .uploads;
        if (std.mem.endsWith(u8, sub, "/stream") or std.mem.eql(u8, sub, "/notifications")) return .streams;
        if (http.pathUnder(sub, "/docs") != null) return .docs;
        return .chat;
    }
    for ([_][]const u8{ "/game", "/puzzles", "/driving", "/chess", "/delivery", "/play" }) |g|
        if (http.pathUnder(path, g) != null) return .games;
    return .site;
}

/// **WHO MAY HOLD AN UPLOAD SLOT** (metal-vmm QUEUE 169): whom the upload's
/// routes take, by the same gate (chat and channels: a member or an agent,
/// `principalAuthorized`), from the head alone, so the sign-in is checked
/// before a byte of the upload is read. Anyone else (a stranger, a guest)
/// is null, never holds a slot, and the route refuses them unread.
fn uploaderOf(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !?[]const u8 {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len == 0 or !try users.principalAuthorized(io, alloc, uid)) return null;
    return uid;
}

/// **EACH ROUTE'S CAP ON A BODY, FROM ITS PATH** (metal-vmm QUEUE 167.2): the
/// most any handler under the path reads, which the host reads the body by
/// (webbox's body.zig: before the turn, or in it under its deadline). Every
/// handler checks its own cap again (`http.readLimitedBody`), so a path's
/// is the largest of its handlers', and the test below holds each handler's
/// within its path's. Only the upload's is past `body_rule.before_turn_most`.
fn routeBodyLimit(path: []const u8) u64 {
    const caps = request_limits.body;
    const in_chat = http.pathUnder(path, "/chat") orelse http.pathUnder(path, "/channel");
    if (in_chat) |sub| {
        // chat.zig's segments skip empty ones: `.../upload/` is the upload.
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, sub, "/"), "/upload")) return caps.upload_any;
        if (http.pathUnder(sub, "/docs") != null) return caps.doc;
        return caps.chat_message;
    }
    if (http.pathUnder(path, "/game") != null) return caps.game_new_session;
    if (std.mem.eql(u8, path, "/admin/script")) return caps.script;
    return caps.largest_form;
}

/// When a request's body is read, and how long it may take (webbox's
/// body.zig): the rule a host reads `bodyLimit` by.
pub const body_rule = @import("webbox").body;
/// The route's cap on a body, from the head's target: contract step 3's
/// first half, before the body is read.
pub const bodyLimit = site.bodyLimit;
/// Who is asking to upload, from the head (null: a stranger).
pub const uploader = site.uploader;
/// The work between requests (a background script's slices, metal-vmm QUEUE
/// 222): the Linux host takes this module as its site and steps a site that
/// declares it; the kernel calls it as `site.between`.
pub const between = site.between;

/// route picks the handler by path prefix, passing the remainder (the path with
/// the prefix stripped, e.g. "/app.js" or "/sessions/3/..."). The table below IS
/// the site: every surface appears exactly once, and the comment on each arm
/// says who may reach it. The serving around it (the 500 for a failure, the
/// 400 for a malformed form, the kept stream as the answer) is site.zig's.
pub const route = site.route;

fn dispatch(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *Bus) !void {
    // **AN UNSIGNED gopher_uid IS RE-IDENTIFIED ONCE** (uid_cookie.zig): its
    // first GET inside the window comes back to the same page with the
    // signed cookie set, and the unsigned spelling is refused from then on.
    // Who is asking, for the bounds on what one address may make and write
    // (game_limits.zig). Read with the head, which a body read invalidates.
    const client = try client_address.resolve(alloc, req, bus.peer);
    if (try uid_cookie.reissue(io, alloc, req, client)) |re| switch (re) {
        .cookie => |c| {
            // **BACK TO THE SAME PAGE, ON THIS SITE ONLY** (http.Target):
            // the target as it came, `GET //evil.example/x` or
            // `GET http://evil.example/`, named another host.
            const set: std.http.Header = .{ .name = "set-cookie", .value = c.set };
            const clear: std.http.Header = .{ .name = "set-cookie", .value = http.clearCookie(uid_cookie.legacy_cookie_name) };
            return http.redirectWith(req, .of(try http.target(req, alloc)), .{ .headers = if (c.clear_legacy) &.{ set, clear } else &.{set} });
        },
        .refused => |r| return game_limits.refuse(req, r),
    };
    // **A SESSION UNDER ITS LEGACY NAME MOVES ON ITS NEXT GET** (metal-vmm
    // QUEUE 170.8), back to the same page, the legacy one cleared.
    if (try users.sessionToMove(io, alloc, req)) |value| return http.redirectWith(req, .of(try http.target(req, alloc)), .{ .headers = &.{
        .{ .name = "set-cookie", .value = try login.authCookie(alloc, value) },
        .{ .name = "set-cookie", .value = http.clearCookie(users.session_cookie_legacy) },
    } });
    const path = http.pathOf(try http.target(req, alloc));

    if (http.pathUnder(path, "/driving")) |sub| {
        try driving.handle(req, alloc, sub);
    } else if (http.pathUnder(path, "/delivery")) |sub| {
        try delivery.handle(req, alloc, sub);
    } else if (http.pathUnder(path, "/chess")) |sub| {
        // Public + ungated like /driving: little chess toys (Knight's Tour,
        // Eight Queens) + /chess/code, the sources-as-exhibit page. The viewer
        // is resolved for the index's top-bar chip, never gated.
        try chess.handle(req, alloc, (try viewer(io, alloc, req)).name, sub);
    } else if (http.pathUnder(path, "/shale")) |sub| {
        // Public + ungated: Shale's landing page and its in-browser tutorial
        // (shale_page.zig), static files from the shale checkout's build.
        try shale_page.handle(req, sub);
    } else if (http.pathUnder(path, "/puzzles")) |sub| {
        try puzzles.handle(req, io, alloc, sub, client);
    } else if (http.pathUnder(path, "/game")) |sub| {
        try game.handle(req, io, alloc, sub, client);
    } else if (http.pathUnder(path, "/chat")) |sub| {
        try chat.handle(req, io, alloc, bus, sub);
    } else if (http.pathUnder(path, "/channel")) |sub| {
        try chat.handleChannel(req, io, alloc, bus, sub);
    } else if (http.pathUnder(path, "/settings")) |sub| {
        try settings.handle(req, io, alloc, bus, sub);
    } else if (http.pathUnder(path, "/gallery")) |sub| {
        // Hidden-for-now: unlinked but public + ungated. Serves the stylized app
        // images (free-standing content read from gallery/) for the home page.
        try gallery.handle(req, io, alloc, sub);
    } else if (http.pathUnder(path, "/downloads")) |sub| {
        // Public + ungated: downloadable artifacts (the native Linux Safari
        // executable) read from downloads/, rsync'd on deploy — see downloads.zig.
        try downloads.handle(req, io, alloc, sub);
    } else if (http.pathUnder(path, "/admin/lynrummy")) |sub| {
        // The GAME roster. Checked before /admin, which would otherwise swallow
        // it: http.pathUnder takes the first arm that matches.
        try admin_lynrummy.handle(req, io, alloc, sub);
    } else if (http.pathUnder(path, "/admin")) |sub| {
        try admin.handle(req, io, alloc, client, sub);
    } else if (std.mem.eql(u8, path, "/play") or std.mem.eql(u8, path, "/play/")) {
        // The LOCAL identity: a name, no password, for /game and /puzzles. It
        // reads its own small store and never touches the chat account store —
        // see player.zig.
        try player.handle(req, io, alloc, client);
    } else if (http.pathUnder(path, "/login")) |sub| {
        try login.handle(req, io, alloc, bus, sub);
    } else if (std.mem.eql(u8, path, "/logout")) {
        try login.handleLogout(req, io, alloc);
    } else if (http.pathUnder(path, "/images")) |sub| {
        try brand.handle(req, sub);
    } else if (std.mem.eql(u8, path, "/safari_download") or std.mem.eql(u8, path, "/safari_download/")) {
        // Public, read-only. The "Install locally" landing page for the Safari
        // screensaver (server-owned markdown → download links) — see safari_download.zig.
        try safari_download.handle(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/steve-resume")) {
        // Public, read-only. A single server-owned markdown page (pages/steve-resume.md)
        // rendered through the trusted markdown pipeline — no viewer resolution, no gate.
        try resume_page.handle(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/steve-resume.pdf")) {
        // The pre-generated static PDF of the same page (ops/build_resume_pdf).
        try resume_page.handlePdf(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/llms.txt")) {
        // The apps described for a language model, from pages/home.txt.
        try llms_txt.handle(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/version")) {
        try home.handleVersion(req, io, alloc);
    } else if (std.mem.eql(u8, path, "/debug/mem")) {
        // The leak smoke detector: live bytes/allocs on the base allocator. The
        // stress harness hammers an endpoint and watches this climb (leak) or
        // plateau (legit cache). Public + ungated on purpose — it leaks no data,
        // only aggregate counts.
        try home.handleDebugMem(req, alloc);
    } else if (std.mem.eql(u8, path, "/")) {
        // The site root: the launch pad. TOTALLY_PUBLIC, so resolve the viewer
        // for the top bar but never gate. The explicit-"/" check plus the
        // notFound fallthrough below means any non-"/" path 404s.
        const v = try viewer(io, alloc, req);
        try home.handleHome(req, io, alloc, v.name, v.is_admin, path);
    } else {
        try http.notFound(req);
    }
}

/// Viewer is what a PUBLIC page needs for its top bar: a name to print, and
/// whether this is the host. EITHER identity can supply the name — a chat member
/// through the account store, a Lyn Rummy player through the local one — and a
/// page that only prints a chip should not have to know which it got. Anonymous
/// is the empty name, which those pages already render as a Log in link.
const Viewer = struct { name: []const u8, is_admin: bool };

fn viewer(io: Io, alloc: std.mem.Allocator, req: *std.http.Server.Request) !Viewer {
    const uid = try users.currentUserID(io, alloc, req);
    if (uid.len != 0) return .{
        .name = try users.getUserName(io, alloc, uid),
        // The host is uid "1" (see admin.zig), so this does too.
        .is_admin = std.mem.eql(u8, uid, "1"),
    };
    return .{ .name = (try player.current(io, alloc, req)).name, .is_admin = false };
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// The tests are router_*_test.zig's, their harness router_harness.zig's.

const testing = std.testing;

// Every file of router.zig's tests, so they run (build.zig's root is this file).
test {
    _ = @import("router_edges_test.zig");
    _ = @import("router_script_test.zig");
    _ = @import("router_failures_test.zig");
    _ = @import("router_chat_test.zig");
    _ = @import("router_search_test.zig");
    _ = @import("router_admin_test.zig");
    _ = @import("router_games_test.zig");
    _ = @import("router_legacy_cookies_test.zig");
    _ = @import("router_identity_test.zig");
    _ = @import("router_pages_test.zig");
}

test "routeBodyLimit: every handler's cap is within its path's, and only the upload's is read in the turn on Linux (metal-vmm QUEUE 167.2)" {
    const caps = request_limits.body;
    const Case = struct { path: []const u8, cap: u64 };
    for ([_]Case{
        .{ .path = "/settings", .cap = caps.form },
        .{ .path = "/login", .cap = caps.form },
        .{ .path = "/play", .cap = caps.form },
        .{ .path = "/admin", .cap = caps.form },
        .{ .path = "/admin/lynrummy/x", .cap = caps.form },
        .{ .path = "/admin/retire", .cap = caps.retire_form },
        .{ .path = "/admin/backup", .cap = caps.secret_form },
        .{ .path = "/admin/secret", .cap = caps.secret_form },
        .{ .path = "/admin/script", .cap = caps.script },
        .{ .path = "/admin/script-key", .cap = caps.secret_form },
        .{ .path = "/puzzles/sessions/1/puzzles/0/actions", .cap = caps.game_append },
        .{ .path = "/game/new-session", .cap = caps.game_new_session },
        .{ .path = "/game/sessions/1/actions", .cap = caps.game_append },
        .{ .path = "/chat/c/ada_bo/main/send", .cap = caps.chat_message },
        .{ .path = "/channel/general/main/send", .cap = caps.chat_message },
        .{ .path = "/chat/c/ada_bo/main/react", .cap = caps.reaction },
        .{ .path = "/chat/docs/new", .cap = caps.doc },
        .{ .path = "/chat/c/ada_bo/main/upload", .cap = caps.upload_any },
        .{ .path = "/channel/general/main/upload", .cap = caps.upload_any },
        .{ .path = "/chat/c/ada_bo/main/upload/", .cap = caps.upload_any },
        .{ .path = "/chat/c/ada_bo/main/upload//", .cap = caps.upload_any },
    }) |c| {
        const limit = bodyLimit(c.path);
        if (limit < c.cap) {
            std.debug.print("{s}: its handler reads {d}, its path allows {d}\n", .{ c.path, c.cap, limit });
            return error.TestExpectedEqual;
        }
        const uploads = std.mem.endsWith(u8, std.mem.trimEnd(u8, c.path, "/"), "/upload");
        try testing.expectEqual(!uploads, limit <= body_rule.before_turn_most);
    }
    // The query is no part of the path.
    try testing.expectEqual(@as(u64, caps.upload_any), bodyLimit("/chat/c/ada_bo/main/upload?x=1"));
    try testing.expectEqual(@as(u64, caps.largest_form), bodyLimit("/nope"));
}

test "route families: each request counted under its part of the site (metal-vmm QUEUE 189.5)" {
    for ([_]struct { []const u8, Family }{
        .{ "/chat/c/1_2/ChitChat/upload", .uploads },
        .{ "/chat/c/1_2/ChitChat/upload/", .uploads },
        .{ "/chat/c/1_2/ChitChat/uploads/0123abcd.png", .uploads },
        .{ "/chat/c/1_2/ChitChat/stream", .streams },
        .{ "/chat/recent/stream", .streams },
        .{ "/chat/notifications", .streams },
        .{ "/chat/docs/new", .docs },
        .{ "/chat/c/1_2/ChitChat/send", .chat },
        .{ "/chat", .chat },
        .{ "/channel/x", .chat },
        .{ "/game/sessions/1/actions", .games },
        .{ "/puzzles", .games },
        .{ "/driving", .games },
        .{ "/chess/knight", .games },
        .{ "/delivery", .games },
        .{ "/play", .games },
        .{ "/admin/host", .admin },
        .{ "/admin/lynrummy", .admin },
        .{ "/admin", .admin },
        .{ "/", .site },
        .{ "/login", .site },
        .{ "/chatter", .site }, // not under /chat
    }) |c| {
        if (familyOf(c[0]) != c[1]) {
            std.debug.print("{s}: {t}, not {t}\n", .{ c[0], familyOf(c[0]), c[1] });
            return error.TestExpectedEqual;
        }
    }
}
