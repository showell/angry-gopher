//! links: /chat/links — a per-user curated links page. Renders the viewer's
//! links.md (manually dropped at {chat_root}/users/<uid>/links.md) through the
//! chat markdown processor, so external links open in a new tab exactly like
//! chat. Deliberately minimal: a static server-rendered page, no stream, no JS.
//! The nav link always shows; the file is only consulted here, on click — a
//! missing file yields an "ask Steve to curate" stub, not a 404.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const store = @import("chat_store.zig");
const chat = @import("chat.zig");
const markdown = @import("markdown.zig");

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// handle serves /chat/links — `rest` must be empty (no sub-routes).
pub fn handle(req: *Request, io: Io, alloc: Alloc, uid: []const u8, rest: []const u8) !void {
    if (rest.len != 0) return http.notFound(req);
    const viewer = try users.getUserName(io, alloc, uid);
    const path = try std.fs.path.join(alloc, &.{ store.chat_root, "users", uid, "links.md" });
    const md: ?[]u8 = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch null;

    var b: std.ArrayList(u8) = .empty;
    try chat.writeChrome(&b, alloc, "Links", "Links", viewer, "links");
    try b.appendSlice(alloc, links_css ++ "<div class=\"links-page\">");
    if (md) |src| {
        // renderTrusted: links.md is server-curated (Steve scp's it), not request
        // input, so it's exempt from render()'s hostile-token cap — a links page
        // has far more than 256 link tokens. Same pipeline otherwise.
        try b.appendSlice(alloc, try markdown.renderTrusted(alloc, src));
    } else {
        try b.appendSlice(alloc, "<p>No links yet — ask Steve to curate links.</p>");
    }
    try b.appendSlice(alloc, "</div></div></body></html>"); // close .links-page + .app-body-wrap
    try req.respond(b.items, .{ .extra_headers = &.{http.html_ct} });
}

// A readable text column — .app-body-wrap is the full-width chat-layout shell,
// so this static page supplies its own narrow column. Tiny + scoped on purpose.
const links_css =
    \\<style>
    \\.links-page { max-width: 46rem; margin: 0 auto; line-height: 1.55; }
    \\.links-page h2 { margin-top: 1.6rem; }
    \\.links-page li { margin: 3px 0; }
    \\</style>
;
