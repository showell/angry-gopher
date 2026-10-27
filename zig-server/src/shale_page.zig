//! shale_page: serves /shale — Shale's landing page and its tutorial, fifteen
//! lessons that run the language in the browser (Shale compiled to WebAssembly
//! over an in-memory tree). Public, no state. The pages are the shale
//! checkout's `zig build web`, copied by ops/build_shale_web; their links are
//! relative, so the landing page is served at /shale/ and /shale redirects
//! there.
//!
//!   GET /shale/                the landing page
//!   GET /shale/<file>          the tutorial and what the pages load

const std = @import("std");
const http = @import("webbox").http;

const Request = std.http.Server.Request;

const File = struct { name: []const u8, body: []const u8, ct: std.http.Header };

/// Everything /shale serves: a name not here is a 404.
const files = [_]File{
    .{ .name = "learn.html", .body = @embedFile("shale_learn_html"), .ct = http.html_ct },
    .{ .name = "tutorial.html", .body = @embedFile("shale_tutorial_html"), .ct = http.html_ct },
    .{ .name = "lessons.js", .body = @embedFile("shale_lessons_js"), .ct = http.js_ct },
    .{ .name = "run_view.js", .body = @embedFile("shale_run_view_js"), .ct = http.js_ct },
    .{ .name = "highlight.js", .body = @embedFile("shale_highlight_js"), .ct = http.js_ct },
    .{ .name = "shale.js", .body = @embedFile("shale_js"), .ct = http.js_ct },
    .{ .name = "shale.wasm", .body = @embedFile("shale_wasm"), .ct = http.wasm_ct },
    .{ .name = "card.svg", .body = @embedFile("shale_card_svg"), .ct = http.svg_ct },
};

/// handle dispatches /shale* — `sub` is the path after "/shale".
pub fn handle(req: *Request, sub: []const u8) !void {
    if (sub.len == 0) return req.respond("", .{ .status = .moved_permanently, .extra_headers = &.{.{ .name = "location", .value = http.Target.literal("/shale/").path }} });
    const name = if (std.mem.eql(u8, sub, "/")) "learn.html" else sub[1..];
    for (files) |f| {
        if (std.mem.eql(u8, f.name, name)) return http.serveEmbedded(req, f.body, f.ct);
    }
    return http.notFound(req);
}

fn served(name: []const u8) bool {
    for (files) |f| if (std.mem.eql(u8, f.name, name)) return true;
    return false;
}

/// The relative names `text` loads or links: `href="x"`, `src="x"`, and the
/// `"./x"` of an import or a fetch. A name with a `/`, a `:` or a `#` is
/// another page's or another site's.
fn eachRelative(text: []const u8, out: *std.ArrayList([]const u8), alloc: std.mem.Allocator) !void {
    for ([_][]const u8{ "href=\"", "src=\"", "\"./" }) |opener| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, opener)) |i| {
            const start = i + opener.len;
            const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse break;
            at = end;
            const name = text[start..end];
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "/:#") != null) continue;
            try out.append(alloc, name);
        }
    }
}

test "every file a /shale page loads or links is one /shale serves" {
    const a = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    for (files) |f| {
        if (std.mem.endsWith(u8, f.name, ".html") or std.mem.endsWith(u8, f.name, ".js")) try eachRelative(f.body, &names, a);
    }
    // The landing page's button, its picture, and the tutorial's module.
    try std.testing.expect(names.items.len >= 3);
    for (names.items) |n| {
        if (!served(n)) {
            std.debug.print("/shale's pages load {s}, which /shale does not serve\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
}
