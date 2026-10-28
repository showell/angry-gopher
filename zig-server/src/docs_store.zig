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

/// readUserDoc returns a doc's raw markdown body. A missing file gives
/// (empty, ok) — the route distinguishes "not found". One that cannot be read
/// is an error: served as empty, the editor's next save would replace the
/// real doc with nothing.
pub fn readUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8) ![]const u8 {
    const path = try docPath(alloc, uid, slug);
    return disk.readOrEmpty(io, alloc, path, .unlimited);
}

const testing = std.testing;
const roots = @import("roots.zig");

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
