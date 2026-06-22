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
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("chat_store.zig");

/// DocSummary is one sidebar entry: the slug + a display title derived from it.
pub const DocSummary = struct { slug: []const u8, title: []const u8 };

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
    return fileExists(io, path);
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// listUserDocs enumerates a user's docs, alphabetically by slug. A missing dir
/// means "no docs yet," not an error.
pub fn listUserDocs(io: Io, alloc: Alloc, uid: []const u8) ![]DocSummary {
    const dir_path = try userDocsDir(alloc, uid);
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList(DocSummary) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const slug = entry.name[0 .. entry.name.len - ".md".len];
        if (!validDocSlug(slug)) continue;
        const owned = try alloc.dupe(u8, slug);
        const title = try titleFromSlug(alloc, owned);
        try out.append(alloc, .{ .slug = owned, .title = title });
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(DocSummary, slice, {}, lessThanSlug);
    return slice;
}

fn lessThanSlug(_: void, a: DocSummary, b: DocSummary) bool {
    return std.mem.lessThan(u8, a.slug, b.slug);
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
/// (empty, ok) — the route distinguishes "not found".
pub fn readUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8) ![]const u8 {
    const path = try docPath(alloc, uid, slug);
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
}

/// docExists reports whether the doc's file is present (the route uses this to
/// 404 an unknown slug; readUserDoc can't tell missing from empty).
pub fn docExists(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8) !bool {
    const path = try docPath(alloc, uid, slug);
    return fileExists(io, path);
}

/// writeUserDoc overwrites a doc's body. Refuses to CREATE a doc that doesn't
/// already exist (autosave must never spawn a file from a stale slug — use
/// createUserDoc).
pub fn writeUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8, body: []const u8) !void {
    const path = try docPath(alloc, uid, slug);
    if (!fileExists(io, path)) return error.DocDoesNotExist;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

/// createUserDoc creates a new empty doc with a title-derived, collision-suffixed
/// slug, and returns the chosen slug.
pub fn createUserDoc(io: Io, alloc: Alloc, uid: []const u8, title: []const u8) ![]const u8 {
    const dir = try userDocsDir(alloc, uid);
    try Io.Dir.cwd().createDirPath(io, dir);
    const slug = try uniqueDocSlug(io, alloc, uid, try slugifyTitle(alloc, title));
    const path = try docPath(alloc, uid, slug);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    return slug;
}

/// append_mu guards the read-modify-write in appendToUserDoc. An overwrite
/// (writeUserDoc / autosave) is last-writer-wins and needs no lock, but an APPEND
/// reads-then-writes, so two concurrent appends (the same user saving from two
/// tabs) could otherwise drop one writer's bytes.
var append_mu: Io.Mutex = .init;

/// appendToUserDoc appends `addition` to a doc, CREATING it at the exact slug
/// (never collision-suffixed, unlike createUserDoc) when it doesn't exist yet —
/// so the first save to a fixed-slug doc like "reading-list" just works. Refuses
/// to grow the doc past `max_bytes` (0 = unlimited) with error.DocTooLarge: a
/// cheap bound on a client that hammers an append endpoint. The bytes are the
/// user's own private doc, but they're still ours to host.
pub fn appendToUserDoc(io: Io, alloc: Alloc, uid: []const u8, slug: []const u8, addition: []const u8, max_bytes: usize) !void {
    const path = try docPath(alloc, uid, slug); // re-validates the slug (traversal chokepoint)

    append_mu.lockUncancelable(io);
    defer append_mu.unlock(io);

    try Io.Dir.cwd().createDirPath(io, try userDocsDir(alloc, uid));
    const existing = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch "";
    if (max_bytes != 0 and existing.len + addition.len > max_bytes) return error.DocTooLarge;
    const combined = try std.mem.concat(alloc, u8, &.{ existing, addition });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = combined });
}

const testing = std.testing;

test "appendToUserDoc creates on first call, appends after, and caps at max_bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved_root = store.chat_root;
    defer store.chat_root = saved_root;
    store.chat_root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
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
