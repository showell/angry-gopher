//! docs_store: the per-user docs collection.
//! One markdown file per doc at `{chat_root}/users/<uid>/docs/<slug>.md`; the
//! on-disk shape IS the whole model (filename = slugified title, body = file,
//! no index/metadata/rename — `ls` the dir and you have the doc list). Each
//! user only ever sees their own dir; docPath re-validates the slug so it's the
//! chokepoint against path traversal. Rides under chat's data root (chat_store.
//! chat_root), namespaced under `users/` so it can't collide with the `<a>_<b>`
//! DM pair-key dirs.
//!
//! This is pure storage. The live /chat/recent ping on save/create lives in
//! docs.zig's handlers (publishDocRecent), not here, so the store stays
//! UI-agnostic and has no dependency on the bus.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");
const disk = @import("webbox").store;

/// userDocsDir is one user's private docs directory ({chat_root}/users/<uid>/docs).
pub fn userDocsDir(alloc: Alloc, uid: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ store.chat_root, "users", uid, "docs" });
}

/// docPath resolves a (user, slug) pair to its on-disk file, re-validating the
/// slug — so this is also the path-traversal chokepoint. Returns error on a bad
/// slug.
pub fn docPath(alloc: Alloc, uid: []const u8, slug: []const u8) ![]u8 {
    if (!validDocSlug(slug)) return error.InvalidDocSlug;
    const file = try std.fmt.allocPrint(alloc, "{s}.md", .{slug});
    return std.fs.path.join(alloc, &.{ try userDocsDir(alloc, uid), file });
}

/// validDocSlug matches `^[a-z0-9]+(?:-[a-z0-9]+)*$` in 1..80
/// chars — lowercase alphanumerics joined by single hyphens, no leading/trailing/
/// double hyphen. Anything else can't come from slugifyTitle or a URL.
pub fn validDocSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 80) return false;
    if (slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    var prev_hyphen = false;
    for (slug) |c| {
        if (c == '-') {
            if (prev_hyphen) return false;
            prev_hyphen = true;
        } else if (isLowerAlnum(c)) {
            prev_hyphen = false;
        } else {
            return false;
        }
    }
    return true;
}

fn isLowerAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// reservedDocSlugs would collide with the literal /chat/docs/<verb> routes
/// (list, new, save, render, post). Creation steps over these; they're still
/// valid URL input (no such file exists, so a read just 404s).
fn isReservedSlug(slug: []const u8) bool {
    const reserved = [_][]const u8{ "list", "new", "save", "render", "post" };
    for (reserved) |r| {
        if (std.mem.eql(u8, r, slug)) return true;
    }
    return false;
}

/// slugifyTitle reduces a free-form title to a filename slug: lowercase,
/// non-alphanumerics collapsed to single hyphens, trimmed. "untitled" if the
/// title is empty or all-symbol; truncated to 80 (re-trimmed).
pub fn slugifyTitle(alloc: Alloc, title: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    var prev_hyphen = false;
    for (std.mem.trim(u8, title, " \t\r\n")) |raw| {
        const c = std.ascii.toLower(raw);
        if (isLowerAlnum(c)) {
            try b.append(alloc, c);
            prev_hyphen = false;
        } else if (!prev_hyphen and b.items.len > 0) {
            try b.append(alloc, '-');
            prev_hyphen = true;
        }
    }
    var out = std.mem.trimEnd(u8, b.items, "-");
    if (out.len == 0) return alloc.dupe(u8, "untitled");
    if (out.len > 80) out = std.mem.trimEnd(u8, out[0..80], "-");
    return alloc.dupe(u8, out);
}

/// uniqueDocSlug returns a slug not colliding with an existing file (and not a
/// reserved name), appending "-2", "-3", … as needed.
fn uniqueDocSlug(io: Io, alloc: Alloc, uid: []const u8, base: []const u8) ![]const u8 {
    if (!isReservedSlug(base) and !try docFileExists(io, alloc, uid, base)) return base;
    var n: usize = 2;
    while (n < 1000) : (n += 1) {
        const cand = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, n });
        if (!try docFileExists(io, alloc, uid, cand)) return cand; // suffixed → never reserved
    }
    return base; // give up; caller overwrites
}

fn docFileExists(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8) !bool {
    const file = try std.fmt.allocPrint(alloc, "{s}.md", .{slug});
    const path = try std.fs.path.join(alloc, &.{ try userDocsDir(alloc, uid), file });
    return disk.has(io, alloc, path);
}

/// titleFromSlug renders a slug back to a display title: hyphens to spaces,
/// first letter upper-cased. Presentational reverse of slugifyTitle (lossy —
/// the filename is the source of truth).
pub fn titleFromSlug(alloc: Alloc, slug: []const u8) ![]u8 {
    const t = try std.mem.replaceOwned(u8, alloc, slug, "-", " ");
    if (t.len == 0) return t;
    t[0] = std.ascii.toUpper(t[0]);
    return t;
}

/// readUserDoc returns a doc's raw markdown body. A missing file gives
/// (empty, ok) — the route distinguishes "not found". One that cannot be read
/// is an error: served as empty, the editor's next save would replace the
/// real doc with nothing.
pub fn readUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8) ![]const u8 {
    const path = try docPath(alloc, uid, slug);
    return disk.readOrEmpty(io, alloc, path, .unlimited);
}

/// writeUserDoc overwrites a doc's body. Refuses to CREATE a doc that doesn't
/// already exist (autosave must never spawn a file from a stale slug — use
/// createUserDoc).
pub fn writeUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8, body: []const u8) !void {
    const path = try docPath(alloc, uid, slug);
    if (!try disk.has(io, alloc, path)) return error.DocDoesNotExist;
    try disk.write(io, alloc, path, body, .{});
}

/// createUserDoc creates a new empty doc with a title-derived, collision-suffixed
/// slug, and returns the chosen slug.
pub fn createUserDoc(io: Io, alloc: Alloc, uid: []const u8, title: []const u8) ![]const u8 {
    const slug = try uniqueDocSlug(io, alloc, uid, try slugifyTitle(alloc, title));
    const path = try docPath(alloc, uid, slug);
    try disk.write(io, alloc, path, "", .{});
    return slug;
}

// No lock: appendToUserDoc's read-modify-write is one step because one
// handler runs at a time (the host's turn, zig-metal-unikernel HOST.md), so two
// appends (the same user saving from two tabs) never drop one writer's bytes.

/// appendToUserDoc appends `addition` to a doc, CREATING it at the exact slug
/// (never collision-suffixed, unlike createUserDoc) when it doesn't exist yet —
/// so the first save to a fixed-slug doc like "reading-list" just works. Refuses
/// to grow the doc past `max_bytes` (0 = unlimited) with error.DocTooLarge: a
/// cheap bound on a client that hammers an append endpoint. The bytes are the
/// user's own private doc, but they're still ours to host.
pub fn appendToUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8, addition: []const u8, max_bytes: usize) !void {
    const path = try docPath(alloc, uid, slug); // re-validates the slug (traversal chokepoint)

    // **A DOCUMENT THAT WILL NOT READ IS NOT AN EMPTY DOCUMENT.** The write
    // below replaces the file with what was read plus this addition, so a
    // failed read here used to hand the user back their newest paragraph and
    // nothing else. store.zig draws the line.
    const existing = try disk.readOrEmpty(io, alloc, path, .unlimited);
    if (max_bytes != 0 and existing.len + addition.len > max_bytes) return error.DocTooLarge;
    const combined = try std.mem.concat(alloc, u8, &.{ existing, addition });
    try disk.write(io, alloc, path, combined, .{});
}

const testing = std.testing;
const roots = @import("roots.zig");

test "appendToUserDoc creates on first call, appends after, and caps at max_bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved_root = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved_root.restore();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // first call creates the doc — no createUserDoc needed
    try appendToUserDoc(io, a, "1", "reading-list", "AAA\n", 0);
    try testing.expectEqualStrings("AAA\n", try readUserDoc(io, a, "1", "reading-list"));

    // second call appends, preserving prior content
    try appendToUserDoc(io, a, "1", "reading-list", "BBB\n", 0);
    try testing.expectEqualStrings("AAA\nBBB\n", try readUserDoc(io, a, "1", "reading-list"));

    // over-cap append refuses WITHOUT mutating (existing 8 + "CCCC\n" 5 = 13 > 12)
    try testing.expectError(error.DocTooLarge, appendToUserDoc(io, a, "1", "reading-list", "CCCC\n", 12));
    try testing.expectEqualStrings("AAA\nBBB\n", try readUserDoc(io, a, "1", "reading-list"));
}

test "a doc that cannot be read is an error, never an empty doc for the editor to save over" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved_root = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved_root.restore();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqualStrings("", try readUserDoc(io, a, "1", "notes")); // not there: empty
    try disk.makeDir(io, a, try docPath(a, "1", "notes")); // there, and unreadable
    try testing.expect(std.meta.isError(readUserDoc(io, a, "1", "notes")));
}

/// The host's turn, as the writers below take it: a handler runs only inside
/// it (webbox's linux_host `turn`; the bare-metal host's one loop), and
/// this file keeps no lock of its own.
var test_turn: Io.Mutex = .init;

/// One writer of the concurrent-append test, each append in a turn of its
/// own, as a handler's would be. `parent` must be thread-safe: the test
/// passes the page allocator.
fn appendMany(io: Io, parent: Alloc, writer: usize, n: usize) void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [64]u8 = undefined;
    for (0..n) |i| {
        const line = std.fmt.bufPrint(&buf, "{d}-{d}\n", .{ writer, i }) catch return;
        test_turn.lockUncancelable(io);
        defer test_turn.unlock(io);
        appendToUserDoc(io, alloc, "1", "reading-list", line, 0) catch return;
    }
}

test "appends to one doc from many writers at once, each in the host's turn, all land" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved_root = try roots.pointForTest(a, try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path }));
    defer saved_root.restore();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const writers = 8;
    const each = 50;
    var group: Io.Group = .init;
    for (0..writers) |w| {
        group.concurrent(io, appendMany, .{ io, std.heap.page_allocator, w, each }) catch
            group.async(io, appendMany, .{ io, std.heap.page_allocator, w, each });
    }
    try group.await(io);

    const body = try readUserDoc(io, a, "1", "reading-list");
    try testing.expectEqual(@as(usize, writers * each), std.mem.count(u8, body, "\n"));
}
