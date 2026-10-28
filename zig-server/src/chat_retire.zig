//! chat_retire: the offline tidy before — and after — the cutover, as logic the
//! admin screen drives (QUEUE.md item 104). The box did this once by hand on
//! prod; metal has no shell, so it lives in the app, where it runs on both
//! hosts and writes through the Store's own paths, keeping metal's FAT volume
//! consistent.
//!
//! **THE PLAN IS THE ROC'S** (roc-webbox chat/Retire.roc, metal-vmm QUEUE
//! 293): what goes, below, is decided there, over the chat root and the
//! accounts; this file carries out its steps (`Report`) behind the admin
//! page's password, and removes the accounts last. The old Zig plan is the
//! twin's oracle, test-only, in chat_retire_twin_test.zig.
//!
//! **A DRY RUN THAT LISTS, AND A CONFIRM THAT ACTS.** `plan(.., .dry_run)` reports
//! what would go — by kind and name, **never a message body** — and changes
//! nothing; `plan(.., .apply)` does the same report and removes as it goes. The
//! two agree: the dry run projects the post-removal state (a reference into a DM
//! that WOULD be removed reads as dangling), so what it lists is exactly what a
//! confirm removes, and a second confirm removes nothing.
//!
//! **WHAT IT REMOVES:**
//!   - **Old topics:** a topic whose newest message (`date:` lines) is older
//!     than `days` — its `.md`, and the `.count`, `.lastauthor`,
//!     `.reactions.jsonl` and `.uploads/` beside it. **A topic that holds no
//!     datable message is kept** (Steve, 2026-10-04): it may be one someone just
//!     made. A conversation left with no topics stays (the app offers to start
//!     one).
//!   - **Users not kept:** every account whose name is not in `keep`, everywhere
//!     it lives — `auth/<id>`, `players/<id>`, `users/<id>`, `chat/users/<id>`,
//!     `lynrummy/<id>`, every DM `a_b` that includes it, and its id's line in
//!     each `channels/*.channel`. `next-id.txt` is never touched (ids are never
//!     reused). Messages it wrote in a KEPT conversation stay — they carry the
//!     author's name, not a live reference.
//!   - **Dangling pointers:** after the above, a kept user's `last-conv`,
//!     `last-sessions/<conv>` or `pinned-sessions/<conv>` that names a
//!     conversation now gone is dropped, so no kept user's page lands on a 404.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const search_index = @import("search_index.zig");
const chat_store = @import("chat_store.zig");
const timefmt = @import("timefmt.zig");
const users = @import("users.zig");
const player = @import("player.zig");
const storage = @import("storage.zig");

/// The names kept when the admin does not name its own (Steve's five, as the
/// box kept them by hand on 2026-10-04).
pub const default_keep = [_][]const u8{
    "Steve",
    "apoorva",
    "damian",
    "Claude",
    "Debbie",
};
/// Topics quieter than this many days go, unless the admin picks another.
pub const default_days: u32 = 30;

/// What a removal is, for the report. A topic's sidecars go with the topic and
/// are not listed on their own; the kinds below are what the admin sees counted.
pub const Kind = enum {
    topic,
    user,
    dm,
    channel_member,
    ref_last_conv,
    ref_last_session,
    ref_pinned,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .topic => "old topic",
            .user => "user removed",
            .dm => "direct-message conversation",
            .channel_member => "channel membership",
            .ref_last_conv => "stale last-conversation pointer",
            .ref_last_session => "stale last-session pointer",
            .ref_pinned => "stale pinned-session pointer",
        };
    }
};

pub const Item = struct { kind: Kind, name: []const u8 };

/// A retire that lists what would go, or one that removes it as it lists.
pub const Mode = enum { dry_run, apply };

/// Params the admin sets: how old is old, and which names to keep.
pub const Params = struct {
    days: u32 = default_days,
    keep: []const []const u8 = &default_keep,
    /// Now, in unix seconds — the host's clock, passed in so a test can fix it.
    now: i64,
};

/// **THE ROC'S PLAN, CARRIED OUT** (roc-webbox chat/Retire.roc, metal-vmm
/// QUEUE 293): each step the Roc hands over (Host.retire_note!,
/// retire_remove!, retire_replace!, retire_user!) recorded for the report
/// and, its mode `apply`, done through the Store; `finish` removes the
/// accounts retired, last. Every name is the Roc's; every path is under
/// the chat root (the seam has checked it), but a retired member's, which
/// are fixed here.
pub const Report = struct {
    alloc: Alloc,
    io: Io,
    mode: Mode,
    items: std.ArrayList(Item) = .empty,
    /// The accounts the plan retires, in its order.
    retired: std.ArrayList([]const u8) = .empty,

    pub fn note(self: *Report, kind: Kind, name: []const u8) !void {
        try self.items.append(self.alloc, .{ .kind = kind, .name = try self.alloc.dupe(u8, name) });
    }

    /// The file, or the folder and all in it, at `path` under the chat root,
    /// removed when applying. One not there is gone already. **ONE THAT
    /// FAILED IS AN ERROR** (metal-vmm QUEUE 129): it ends the confirm, and
    /// the admin's page is the router's 500.
    pub fn remove(self: *Report, path: []const u8, what: enum { file, tree }) !void {
        if (self.mode != .apply) return;
        const p = try std.fs.path.join(self.alloc, &.{ chat_store.chat_root, path });
        switch (what) {
            .file => try store.remove(self.io, self.alloc, p),
            .tree => try store.removeTree(self.io, self.alloc, p),
        }
    }

    /// The file at `path` under the chat root written whole, when applying.
    pub fn replace(self: *Report, path: []const u8, bytes: []const u8) !void {
        if (self.mode != .apply) return;
        try store.replace(
            self.io,
            self.alloc,
            try std.fs.path.join(self.alloc, &.{ chat_store.chat_root, path }),
            bytes,
            .{},
        );
    }

    /// A retired member, everywhere it lives outside its DMs (the Roc's
    /// steps) and its account (`finish`): its game, its user data, its saved
    /// games and its chat state, when applying.
    pub fn retireUser(self: *Report, id: []const u8) !void {
        try self.retired.append(self.alloc, try self.alloc.dupe(u8, id));
        if (self.mode != .apply) return;
        for ([_][]const u8{
            player.player_root,
            users.users_root,
            storage.data_root,
            try std.fs.path.join(self.alloc, &.{ chat_store.chat_root, "users" }),
        }) |root| try store.removeTree(
            self.io,
            self.alloc,
            try std.fs.path.join(self.alloc, &.{ root, id }),
        );
    }

    /// **AUTHORITY GOES LAST** (metal-vmm QUEUE 129): the roster is read from
    /// auth_root, so a retired member's account goes only once every step
    /// of the plan did. A removal refused before it leaves the member
    /// listed, and the next confirm finishes the job; refused here, the
    /// account stays, still able to log in, and the confirm is an error.
    pub fn finish(self: *Report) !void {
        if (self.mode != .apply) return;
        // Its password last within it (`users.removeAccount`, QUEUE 138(f)).
        for (self.retired.items) |id| try users.removeAccount(
            self.io,
            self.alloc,
            id,
        );
    }

    /// Count the items of each kind, for the summary line.
    pub fn countOf(self: *const Report, kind: Kind) usize {
        var n: usize = 0;
        for (self.items.items) |it| {
            if (it.kind == kind) n += 1;
        }
        return n;
    }

    pub fn total(self: *const Report) usize {
        return self.items.items.len;
    }

    /// The accounts not kept.
    pub fn membersRemoved(self: *const Report) usize {
        return self.retired.items.len;
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const roots = @import("roots.zig");

/// The plan as the admin page runs it: the Roc's (chat_router.retire),
/// carried out by a Report; a keep list refused is error.BadKeepList, its
/// words kept in `refusal`.
fn plan(io: Io, a: Alloc, p: Params, mode: Mode) !Report {
    var r: Report = .{ .alloc = a, .io = io, .mode = mode };
    if (try @import("chat_router.zig").retire(io, a, &r, p)) |why| {
        refusal = why;
        return error.BadKeepList;
    }
    return r;
}
var refusal: []const u8 = "";

/// The keep list's refusal, as `plan` finds it on a dry run, or null.
fn keepProblem(io: Io, a: Alloc, keep: []const []const u8) !?[]const u8 {
    _ = plan(io, a, .{ .keep = keep, .now = now }, .dry_run) catch |e| switch (e) {
        error.BadKeepList => return refusal,
        else => return e,
    };
    return null;
}

/// A transcript of one message dated `at`, in the on-disk form the decoder reads.
fn tx(
    a: Alloc,
    sid: []const u8,
    at: i64,
) ![]u8 {
    const date = try timefmt.formatRFC3339UTC(a, at);
    return std.fmt.allocPrint(
        a,
        "MSG_{s}_1\nfrom: Tester\ndate: {s}\n\nhello there",
        .{ sid, date },
    );
}

const now: i64 = 1_700_000_000; // a fixed "now" for the fixture
pub const fixture_now = now;
const old_at: i64 = now - 100 * std.time.s_per_day; // retire
const new_at: i64 = now - 5 * std.time.s_per_day; // keep

/// Stages a tree: members Steve(1), apoorva(2), Spammer(9 — not kept); a DM 1_2
/// with an old and a new topic; a DM 1_9 (with the removed user) with a topic; a
/// channel `general` with members 1,2,9 and an old topic; the removed user's
/// state everywhere; and kept user 1's pointers, one into the DM that will go
/// (last-conv, last-sessions/1_9) and one into a surviving DM (pinned 1_2).
pub fn stage(io: Io, a: Alloc) !void {
    // Accounts.
    for ([_][2][]const u8{
        .{ "1", "Steve" },
        .{ "2", "apoorva" },
        .{ "9", "Spammer" },
    }) |m| {
        try store.write(
            io,
            a,
            try std.fs.path.join(a, &.{
                users.auth_root,
                m[0],
                "name",
            }),
            m[1],
            .{},
        );
        try store.write(
            io,
            a,
            try std.fs.path.join(a, &.{
                users.auth_root,
                m[0],
                "password",
            }),
            "x",
            .{},
        );
    }
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{ users.auth_root, "next-id.txt" }),
        "10\n",
        .{},
    );

    // DM 1_2: an old topic and a new one.
    const dm12 = try chat_paths.dmConvDir(a, "1_2");
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm12,
            "oldtopic",
        ),
        try tx(
            a,
            "oldtopic",
            old_at,
        ),
        .{},
    );
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{
            dm12,
            "sessions",
            "oldtopic.count",
        }),
        "1 0\n",
        .{},
    );
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{
            dm12,
            "sessions",
            "oldtopic.uploads",
            "pic.png",
        }),
        "img",
        .{},
    );
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm12,
            "freshtopic",
        ),
        try tx(
            a,
            "freshtopic",
            new_at,
        ),
        .{},
    );

    // DM 1_9: a topic, the whole conv goes when 9 does.
    const dm19 = try chat_paths.dmConvDir(a, "1_9");
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm19,
            "chat",
        ),
        try tx(
            a,
            "chat",
            new_at,
        ),
        .{},
    );

    // Channel general: members 1,2,9; an old topic.
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{
            chat_store.chat_root,
            "channels",
            "general.channel",
        }),
        "1\n2\n9\n",
        .{},
    );
    const gen = try chat_paths.channelConvDir(a, "general");
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            gen,
            "oldchan",
        ),
        try tx(
            a,
            "oldchan",
            old_at,
        ),
        .{},
    );

    // The removed user's state everywhere it lives.
    for ([_][]const u8{
        users.users_root,
        player.player_root,
        storage.data_root,
    }) |r|
        try store.write(
            io,
            a,
            try std.fs.path.join(a, &.{
                r,
                "9",
                "marker",
            }),
            "x",
            .{},
        );
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{
            chat_store.chat_root,
            "users",
            "9",
            "last-conv",
        }),
        "1_9",
        .{},
    );

    // Kept user 1's pointers: into the DM that will go, and into one that stays.
    const user1 = try std.fs.path.join(a, &.{
        chat_store.chat_root,
        "users",
        "1",
    });
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{ user1, "last-conv" }),
        "1_9",
        .{},
    );
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{
            user1,
            "last-sessions",
            "1_9",
        }),
        "chat",
        .{},
    );
    try store.write(
        io,
        a,
        try std.fs.path.join(a, &.{
            user1,
            "pinned-sessions",
            "1_2",
        }),
        "freshtopic",
        .{},
    );
}

test "fs: the dry run lists exactly what a confirm removes, and a second confirm is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    const saved = try roots.pointForTest(a, base);
    defer saved.restore();
    try stage(io, a);

    const p = Params{
        .days = 30,
        .keep = &.{ "Steve", "apoorva" },
        .now = now,
    };

    // Dry run: it changes nothing and names the removals.
    var dry = try plan(
        io,
        a,
        p,
        .dry_run,
    );
    try testing.expectEqual(@as(usize, 1), dry.membersRemoved()); // uid 9
    try testing.expectEqual(@as(usize, 2), dry.countOf(.topic)); // oldtopic, oldchan
    try testing.expectEqual(@as(usize, 1), dry.countOf(.dm)); // 1_9
    try testing.expectEqual(@as(usize, 1), dry.countOf(.channel_member)); // general drops 9
    try testing.expectEqual(@as(usize, 1), dry.countOf(.ref_last_conv)); // 1 -> 1_9
    try testing.expectEqual(@as(usize, 1), dry.countOf(.ref_last_session)); // 1/last-sessions/1_9
    try testing.expectEqual(@as(usize, 0), dry.countOf(.ref_pinned)); // 1_2 survives
    // The dry run touched nothing.
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            users.auth_root,
            "9",
            "name",
        }),
    ));
    try testing.expect(try store.has(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            try chat_paths.dmConvDir(a, "1_2"),
            "oldtopic",
        ),
    ));

    // Search's index, built before the confirm (metal-vmm 155(b)).
    const mem_meter = @import("webbox").mem_meter;
    const meter = mem_meter.useForTest(testing.allocator);
    defer meter.restore();
    const emptied = search_index.emptyForTest();
    defer emptied.end();
    _ = search_index.buildAll(io, a).?;
    const dm12_reach = [_][]const u8{try chat_paths.dmConvDir(a, "1_2")};
    const dm19_reach = [_][]const u8{try chat_paths.dmConvDir(a, "1_9")};
    try testing.expectEqual(@as(usize, 2), (try search_index.indexOrBuild(io, a).?.messagesFor(
        a,
        &dm12_reach,
        "hello",
        10,
        .{},
    )).matched);
    try testing.expectEqual(@as(usize, 1), (try search_index.indexOrBuild(io, a).?.messagesFor(
        a,
        &dm19_reach,
        "hello",
        10,
        .{},
    )).matched);

    // Confirm: the same report, carried out.
    var done = try plan(
        io,
        a,
        p,
        .apply,
    );
    try testing.expectEqual(dry.total(), done.total());

    // **SEARCH IS BUILT AGAIN AFTER IT**: the old topic and the gone DM are
    // found no more; the fresh topic still is.
    try testing.expectEqual(@as(usize, 1), (try search_index.indexOrBuild(io, a).?.messagesFor(
        a,
        &dm12_reach,
        "hello",
        10,
        .{},
    )).matched);
    try testing.expectEqual(@as(usize, 0), (try search_index.indexOrBuild(io, a).?.messagesFor(
        a,
        &dm19_reach,
        "hello",
        10,
        .{},
    )).matched);

    // The removed user is gone everywhere.
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ users.auth_root, "9" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ player.player_root, "9" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ users.users_root, "9" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ storage.data_root, "9" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            chat_store.chat_root,
            "users",
            "9",
        }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try chat_paths.dmConvDir(a, "1_9"),
    ));

    // The old topic and its sidecars are gone; the fresh topic stays.
    const dm12 = try chat_paths.dmConvDir(a, "1_2");
    try testing.expect(!try store.has(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm12,
            "oldtopic",
        ),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            dm12,
            "sessions",
            "oldtopic.count",
        }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            dm12,
            "sessions",
            "oldtopic.uploads",
        }),
    ));
    try testing.expect(try store.has(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm12,
            "freshtopic",
        ),
    ));

    // The channel stays, without uid 9; members 1 and 2 remain.
    const chan = try store.read(
        io,
        a,
        try std.fs.path.join(a, &.{
            chat_store.chat_root,
            "channels",
            "general.channel",
        }),
        .unlimited,
    );
    try testing.expect(std.mem.indexOf(
        u8,
        chan,
        "9",
    ) == null);
    try testing.expect(std.mem.indexOf(
        u8,
        chan,
        "1",
    ) != null and std.mem.indexOf(
        u8,
        chan,
        "2",
    ) != null);

    // Kept user 1: the pointer into the gone DM is cleared; the surviving pin stays.
    const user1 = try std.fs.path.join(a, &.{
        chat_store.chat_root,
        "users",
        "1",
    });
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ user1, "last-conv" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            user1,
            "last-sessions",
            "1_9",
        }),
    ));
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            user1,
            "pinned-sessions",
            "1_2",
        }),
    ));

    // A second confirm finds nothing left to do.
    var again = try plan(
        io,
        a,
        p,
        .apply,
    );
    try testing.expectEqual(@as(usize, 0), again.total());
    try testing.expectEqual(@as(usize, 0), again.membersRemoved());
}

/// Stages DM 1_2's topics with no accounts at all: one empty, one undated,
/// one recent and one datably old.
pub fn stageUndated(io: Io, a: Alloc) !void {
    const dm = try chat_paths.dmConvDir(a, "1_2");
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm,
            "empty",
        ),
        "",
        .{},
    );
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm,
            "undated",
        ),
        "MSG_undated_1\nfrom: X\n\nbody",
        .{},
    );
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm,
            "recent",
        ),
        try tx(
            a,
            "recent",
            new_at,
        ),
        .{},
    );
    try store.write(
        io,
        a,
        try chat_paths.transcriptPath(
            a,
            dm,
            "stale",
        ),
        try tx(
            a,
            "stale",
            old_at,
        ),
        .{},
    );
}

test "an empty or undated topic is kept (it may be fresh); only a datably-old topic is retired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    const saved = try roots.pointForTest(a, base);
    defer saved.restore();
    try stageUndated(io, a);

    var dry = try plan(
        io,
        a,
        .{
            .days = 30,
            .keep = &.{},
            .now = now,
        },
        .dry_run,
    );
    // Only the datably-old topic retires; empty, undated and recent all stay.
    // (No accounts, so no user removals.)
    try testing.expectEqual(@as(usize, 1), dry.countOf(.topic));
    try testing.expectEqual(@as(usize, 0), dry.membersRemoved());
    try testing.expectEqualStrings("1_2/stale", dry.items.items[0].name);
}

/// An Io whose file removals are refused under one path (all of them when
/// it is ""), as a store that will not delete (metal-vmm QUEUE 129).
pub var refuse_under: []const u8 = "";
pub fn refusingRemovals(io: Io, vt: *Io.VTable) Io {
    const refused = struct {
        fn deleteFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
        ) Io.Dir.DeleteFileError!void {
            if (std.mem.indexOf(
                u8,
                sub_path,
                refuse_under,
            ) != null) return error.AccessDenied;
            return real.?.dirDeleteFile(
                userdata,
                dir,
                sub_path,
            );
        }
        var real: ?*const Io.VTable = null;
    };
    refused.real = io.vtable;
    vt.* = io.vtable.*;
    vt.dirDeleteFile = refused.deleteFile;
    return .{ .userdata = io.userdata, .vtable = vt };
}

test "fs: a confirm whose removals fail is an error, not a report of what went (metal-vmm QUEUE 129)" {
    // Every removal was `catch {}`: a confirm on a store that refused them
    // reported each user, DM and topic as removed, and the users went on
    // logging in.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    const saved = try roots.pointForTest(a, base);
    defer saved.restore();
    try stage(io, a);
    const p = Params{
        .days = 30,
        .keep = &.{ "Steve", "apoorva" },
        .now = now,
    };

    var vt: Io.VTable = undefined;
    refuse_under = "";
    defer refuse_under = ""; // the test's own global, never left pointing into its arena
    try testing.expect(std.meta.isError(plan(
        refusingRemovals(io, &vt),
        a,
        p,
        .apply,
    )));
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            users.auth_root,
            "9",
            "name",
        }),
    ));

    // **AUTHORITY GOES LAST**: a removal refused under the user's game data
    // leaves the account, so it is still listed, and the next confirm
    // finishes the job.
    refuse_under = try std.fs.path.join(a, &.{ storage.data_root, "9" });
    try testing.expect(std.meta.isError(plan(
        refusingRemovals(io, &vt),
        a,
        p,
        .apply,
    )));
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{
            users.auth_root,
            "9",
            "name",
        }),
    ));
    _ = try plan(
        io,
        a,
        p,
        .apply,
    );
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ users.auth_root, "9" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ storage.data_root, "9" }),
    ));
    try testing.expect(!try store.has(
        io,
        a,
        try chat_paths.dmConvDir(a, "1_9"),
    ));
}

test "fs: a member whose name cannot be read is not retired as nobody (metal-vmm QUEUE 105)" {
    // users.getUserName read an unreadable name file as "", no name is on
    // the keep list, and a kept member was removed everywhere.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    const saved = try roots.pointForTest(a, base);
    defer saved.restore();
    try stage(io, a);
    // apoorva's name: there, and unreadable.
    const name = try std.fs.path.join(a, &.{
        users.auth_root,
        "2",
        "name",
    });
    try store.remove(
        io,
        a,
        name,
    );
    try store.makeDir(
        io,
        a,
        name,
    );

    const p = Params{
        .days = 30,
        .keep = &.{ "Steve", "apoorva" },
        .now = now,
    };
    _ = plan(
        io,
        a,
        p,
        .apply,
    ) catch {}; // refusing is right; removing her is not
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ users.auth_root, "2" }),
    ));
}

test "fs: a keep name that matches no account refuses the whole plan, the dry run too, and nothing goes (the normalization hunt)" {
    // A typo in a keep name ("Stve") matched nothing, silently, and Steve was
    // removed everywhere as one of the accounts not kept.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    const saved = try roots.pointForTest(a, base);
    defer saved.restore();
    try stage(io, a);
    const typo = Params{
        .days = 30,
        .keep = &.{ "Stve", "apoorva" },
        .now = now,
    };
    try testing.expectEqualStrings("The keep list names \"Stve\", which is no account's name.", (try keepProblem(
        io,
        a,
        typo.keep,
    )).?);
    try testing.expectError(error.BadKeepList, plan(
        io,
        a,
        typo,
        .dry_run,
    ));
    try testing.expectError(error.BadKeepList, plan(
        io,
        a,
        typo,
        .apply,
    ));
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ users.auth_root, "1" }),
    ));
    // The names as they are pass.
    try testing.expectEqual(@as(?[]const u8, null), try keepProblem(
        io,
        a,
        &.{ "Steve", "apoorva" },
    ));
}

test "fs: an account with no name refuses the whole plan, and nothing goes (the normalization hunt)" {
    // A missing name file read as "", which no keep list holds: the account
    // was removed as one not kept.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(a, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    const saved = try roots.pointForTest(a, base);
    defer saved.restore();
    try stage(io, a);
    try store.remove(
        io,
        a,
        try std.fs.path.join(a, &.{
            users.auth_root,
            "2",
            "name",
        }),
    );
    const p = Params{
        .days = 30,
        .keep = &.{"Steve"},
        .now = now,
    };
    try testing.expectEqualStrings("Account 2 has no name; give it one before retiring.", (try keepProblem(
        io,
        a,
        p.keep,
    )).?);
    try testing.expectError(error.BadKeepList, plan(
        io,
        a,
        p,
        .apply,
    ));
    try testing.expect(try store.has(
        io,
        a,
        try std.fs.path.join(a, &.{ users.auth_root, "2" }),
    ));
}
