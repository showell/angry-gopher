//! llms_txt: `GET /llms.txt`, the site described for a language model
//! (the llmstxt.org convention: a `#` name, a `>` summary, `##` sections
//! of `- [name](url): notes` links). The third renderer of
//! `pages/home.txt`, beside the home page and /gallery: the apps, their
//! order and their words are that file's, so this page cannot go stale
//! apart from it. Links stay relative, as the home page's are, so the
//! file is right on every host that serves it.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("webbox").http;
const home = @import("home.zig");

const Request = std.http.Server.Request;

/// A home that cannot be parsed is a 500 naming the error, as the home
/// page's and the gallery's are: an empty list would read as "no apps".
pub fn handle(req: *Request, io: Io, alloc: Alloc) !void {
    // absent-ok: a 500 that names the error, never an empty list served.
    const parsed = home.parseHome(io, alloc) catch |err| {
        const body = try std.fmt.allocPrint(alloc, "pages/home.txt could not be parsed: {s}\n", .{@errorName(err)});
        return req.respond(body, .{ .status = .internal_server_error, .extra_headers = &.{http.plain_ct} });
    };
    try req.respond(try render(alloc, parsed), .{ .extra_headers = &.{http.plain_ct} });
}

/// The file, from the parsed home: one line an app, its links after.
pub fn render(alloc: Alloc, parsed: home.Parsed) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(alloc, "# {s}\n\n", .{parsed.headline});
    try out.appendSlice(alloc,
        \\> Small apps that Steve Howell and Claude built, each one a row of
        \\> the home page (/). Every app's code is public, under
        \\> https://github.com/showell/angry-gopher.
        \\
        \\## Apps
        \\
        \\
    );
    for (parsed.apps.items) |a| {
        try out.print(alloc, "- [{s}]({s}): {s} ({s}; {s})\n", .{ try linkText(alloc, a.title), a.href, a.desc, a.lang, a.tech });
        try out.print(alloc, "  - [Code]({s})\n", .{a.code});
        if (a.essay.len > 0) try out.print(alloc, "  - [Read more]({s})\n", .{a.essay});
        if (a.install.len > 0) try out.print(alloc, "  - [Install locally]({s})\n", .{a.install});
    }
    try out.appendSlice(alloc,
        \\
        \\## Optional
        \\
        \\- [Resume for Steve Howell](/steve-resume)
        \\
    );
    return out.toOwnedSlice(alloc);
}

/// A title as a link's text: `[`, `]` and `\` escaped, so none ends it.
fn linkText(alloc: Alloc, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '[' or c == ']' or c == '\\') try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

test "llms.txt: the headline, the summary, each app's line and its links, in the file's order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try home.parseHomeText(a,
        \\# Apps here
        \\
        \\## Lyn [Rummy] -> /game
        \\cta: Play
        \\lang: Elm
        \\tech: a solver
        \\code: https://example.org/code
        \\A card game,
        \\for two.
        \\essay: /essays/lyn
        \\
        \\## Chat -> /chat
        \\cta: Talk
        \\lang: Zig
        \\tech: SSE
        \\code: https://example.org/chat
        \\install: /downloads/chat
        \\Messages.
    );
    try std.testing.expectEqualStrings(
        \\# Apps here
        \\
        \\> Small apps that Steve Howell and Claude built, each one a row of
        \\> the home page (/). Every app's code is public, under
        \\> https://github.com/showell/angry-gopher.
        \\
        \\## Apps
        \\
        \\- [Lyn \[Rummy\]](/game): A card game, for two. (Elm; a solver)
        \\  - [Code](https://example.org/code)
        \\  - [Read more](/essays/lyn)
        \\- [Chat](/chat): Messages. (Zig; SSE)
        \\  - [Code](https://example.org/chat)
        \\  - [Install locally](/downloads/chat)
        \\
        \\## Optional
        \\
        \\- [Resume for Steve Howell](/steve-resume)
        \\
    , try render(a, p));
}
