//! chat_retire: the offline tidy before — and after — the cutover, as logic the
//! admin screen drives (QUEUE.md item 104). The box did this once by hand on
//! prod; metal has no shell, so it lives in the app, where it runs on both
//! hosts and writes through the Store's own paths, keeping metal's FAT volume
//! consistent.
//!
//! **A DRY RUN THAT LISTS, AND A CONFIRM THAT ACTS.** `plan(.., false)` reports
//! what would go — by kind and name, **never a message body** — and changes
//! nothing; `plan(.., true)` does the same report and removes as it goes. The
//! two agree: the dry run projects the post-removal state (a reference into a DM
//! that WOULD be removed reads as dangling), so what it lists is exactly what a
//! confirm removes, and a second confirm removes nothing.
//!
//! **WHAT IT REMOVES:**
//!   - **Old topics:** a session whose newest message (`date:` lines) is older
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
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("store.zig");
const chat_store = @import("chat_store.zig");
const timefmt = @import("timefmt.zig");
const users = @import("users.zig");
const player = @import("player.zig");
const storage = @import("storage.zig");

/// The names kept when the admin does not name its own (Steve's five, as the
/// box kept them by hand on 2026-10-04).
pub const default_keep = [_][]const u8{ "Steve", "apoorva", "damian", "Claude", "Debbie" };
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

/// The engine: what it would remove (always), and — when `apply` — the Io it
/// removes through. `members_removed` is the count of accounts not kept.
pub const Plan = struct {
    alloc: Alloc,
    io: Io,
    apply: bool,
    items: std.ArrayList(Item) = .empty,
    members_removed: usize = 0,

    fn record(self: *Plan, kind: Kind, name: []const u8) !void {
        try self.items.append(self.alloc, .{ .kind = kind, .name = name });
    }

    /// Record a file/dir removal, and carry it out when applying. A file not
    /// there is not an error — the caller wanted it gone. **ONE THAT FAILED
    /// IS** (metal-vmm QUEUE 129): it was `catch {}`, and a confirm on a
    /// store that refused reported everything removed. The error ends the
    /// confirm, and the admin's page is the router's 500.
    fn rmFile(self: *Plan, kind: Kind, name: []const u8, path: []const u8) !void {
        try self.record(kind, name);
        if (self.apply) try store.remove(self.io, self.alloc, path);
    }

    fn rmTree(self: *Plan, kind: Kind, name: []const u8, path: []const u8) !void {
        try self.record(kind, name);
        if (self.apply) try store.removeTree(self.io, self.alloc, path);
    }

    /// Count the items of each kind, for the summary line.
    pub fn countOf(self: *const Plan, kind: Kind) usize {
        var n: usize = 0;
        for (self.items.items) |it| {
            if (it.kind == kind) n += 1;
        }
        return n;
    }

    pub fn total(self: *const Plan) usize {
        return self.items.items.len;
    }
};

/// A tiny set of uid strings, for "is this user removed". The roster is small
/// (tens), so a list and a linear scan is the whole thing.
const UidSet = struct {
    ids: std.ArrayList([]const u8) = .empty,

    fn add(self: *UidSet, alloc: Alloc, id: []const u8) !void {
        if (self.has(id)) return;
        try self.ids.append(alloc, id);
    }
    fn has(self: *const UidSet, id: []const u8) bool {
        for (self.ids.items) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }
};

/// Params the admin sets: how old is old, and which names to keep.
pub const Params = struct {
    days: u32 = default_days,
    keep: []const []const u8 = &default_keep,
    /// Now, in unix seconds — the host's clock, passed in so a test can fix it.
    now: i64,
};

/// Builds (and, when `apply`, carries out) the retirement. The returned Plan's
/// `items` and strings are allocated from `alloc`.
pub fn plan(io: Io, alloc: Alloc, p: Params, apply: bool) !Plan {
    var pl = Plan{ .alloc = alloc, .io = io, .apply = apply };
    const cutoff = p.now - @as(i64, p.days) * std.time.s_per_day;

    // Phase 1: old topics, in every conversation (DMs and channels alike).
    // absent-ok: a retire that cannot list the conversations retires none: it removes less, never more.
    const convs = chat_store.listConvDirs(io, alloc) catch &.{};
    for (convs) |dir| {
        const key = try convDisplayKey(alloc, dir);
        // absent-ok: the same, for one conversation's topics: kept.
        const sids = chat_store.listSessions(io, alloc, dir) catch continue;
        for (sids) |sid| {
            // **A TOPIC WE CANNOT DATE IS KEPT** (Steve, 2026-10-04): an empty
            // or hand-damaged transcript may be a fresh topic someone just
            // made, so only a topic with a datable message older than the
            // cutoff is retired.
            const newest = newestUnix(io, alloc, dir, sid) orelse continue;
            if (newest >= cutoff) continue; // recent enough to keep
            try retireTopic(&pl, dir, key, sid);
        }
    }

    // Phase 2: users not kept. Decide first (so the dry run can project the
    // DMs that would go), record, and remove.
    var removed = UidSet{};
    for (try allMembers(io, alloc)) |m| {
        if (inList(p.keep, m.name)) continue;
        try removed.add(alloc, m.id);
    }
    for (removed.ids.items) |id| try retireUser(&pl, id);
    pl.members_removed = removed.ids.items.len;

    // The DM directories a removed user was part of — removed whole, and the
    // keys noted so the sweep below treats them as already gone.
    var gone_dms = UidSet{}; // reuse the set: it holds conv keys here
    try retireDMs(&pl, &removed, &gone_dms);

    // Channel membership: a removed uid's line goes, the channel stays.
    try pruneChannels(&pl, &removed);

    // Phase 3: a kept user's pointers into a conversation now gone.
    try sweepReferences(&pl, &removed, &gone_dms, p.keep);

    // **AUTHORITY GOES LAST** (metal-vmm QUEUE 129): the roster is read from
    // auth_root, so a removed user's account goes only once everything else
    // of theirs did. A removal refused before it leaves the user listed, and
    // the next confirm finishes the job; refused here, the account stays,
    // still able to log in, and the confirm is an error, never "removed".
    if (pl.apply) for (removed.ids.items) |id| {
        // Its password last within it (`users.removeAccount`, QUEUE 138(f)).
        try users.removeAccount(io, alloc, id);
    };

    return pl;
}

// ── phase 1: topics ───────────────────────────────────────────────────────────

/// The newest `date:` across a session's messages, in unix seconds, or null
/// when it has no message that carries a parseable date (an empty or
/// hand-damaged transcript) — which the caller keeps, not retires.
fn newestUnix(io: Io, alloc: Alloc, conv_dir: []const u8, sid: []const u8) ?i64 {
    // absent-ok: a topic that cannot be dated is kept, not retired (Steve, 2026-10-04).
    const raw = (chat_store.rawSession(io, alloc, conv_dir, sid) catch return null) orelse return null;
    const msgs = chat_store.decodeChatFile(alloc, raw) catch return null;
    var newest: ?i64 = null;
    for (msgs) |m| {
        if (timefmt.unixFromRFC3339(m.date)) |t| {
            if (newest == null or t > newest.?) newest = t;
        }
    }
    return newest;
}

fn retireTopic(pl: *Plan, conv_dir: []const u8, key: []const u8, sid: []const u8) !void {
    const alloc = pl.alloc;
    const sess = try std.fs.path.join(alloc, &.{ conv_dir, "sessions" });
    try pl.rmFile(.topic, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ key, sid }), try std.fs.path.join(alloc, &.{ sess, try std.fmt.allocPrint(alloc, "{s}.md", .{sid}) }));
    // Sidecars go with the topic; they are not listed on their own. No server
    // writes `.lastauthor` now (gopher-metal 153(1)): one an older server
    // left goes too.
    for ([_][]const u8{ ".count", ".lastauthor", ".reactions.jsonl" }) |suf| {
        const f = try std.fs.path.join(alloc, &.{ sess, try std.fmt.allocPrint(alloc, "{s}{s}", .{ sid, suf }) });
        if (pl.apply) try store.remove(pl.io, alloc, f);
    }
    const up = try std.fs.path.join(alloc, &.{ sess, try std.fmt.allocPrint(alloc, "{s}.uploads", .{sid}) });
    if (pl.apply) try store.removeTree(pl.io, alloc, up);
}

// ── phase 2: users ──────────────────────────────────────────────────────────

const Member = struct { id: []const u8, name: []const u8 };

/// Every account with a numeric dir under auth_root, by id and name. Not
/// `userIsAuthorized`-filtered (an account without a password is still an
/// account to keep or remove); `next-id.txt` and other non-numeric names are
/// skipped.
fn allMembers(io: Io, alloc: Alloc) ![]Member {
    const entries = try store.list(io, alloc, users.auth_root);
    var out: std.ArrayList(Member) = .empty;
    for (entries) |e| {
        if (e.kind != .directory) continue;
        _ = std.fmt.parseInt(u64, e.name, 10) catch continue;
        const id = try alloc.dupe(u8, e.name);
        try out.append(alloc, .{ .id = id, .name = try users.getUserName(io, alloc, id) });
    }
    return out.toOwnedSlice(alloc);
}

/// A removed user, everywhere it lives but the DMs (those are retireDMs, so a
/// DM shared by two removed users is listed once) and its account (auth_root,
/// removed last, by `plan`).
fn retireUser(pl: *Plan, id: []const u8) !void {
    const alloc = pl.alloc;
    // absent-ok: the name only labels the plan's line; the removal goes by uid.
    const name = users.getUserName(pl.io, alloc, id) catch "";
    try pl.record(.user, try std.fmt.allocPrint(alloc, "{s} (uid {s})", .{ name, id }));
    const locations = [_][]const u8{
        player.player_root,
        users.users_root,
        storage.data_root,
        try std.fs.path.join(alloc, &.{ chat_store.chat_root, "users" }),
    };
    for (locations) |root| {
        const path = try std.fs.path.join(alloc, &.{ root, id });
        if (pl.apply) try store.removeTree(pl.io, alloc, path);
    }
}

/// Every DM directory `a_b` that includes a removed uid: removed whole (its
/// messages too — the other party is gone), the key noted in `gone`.
fn retireDMs(pl: *Plan, removed: *const UidSet, gone: *UidSet) !void {
    const alloc = pl.alloc;
    const entries = try store.list(pl.io, alloc, chat_store.chat_root);
    for (entries) |e| {
        if (e.kind != .directory) continue;
        const pair = dmPair(e.name) orelse continue;
        if (!removed.has(pair.a) and !removed.has(pair.b)) continue;
        try pl.record(.dm, e.name);
        try gone.add(alloc, try alloc.dupe(u8, e.name));
        if (pl.apply) try store.removeTree(pl.io, alloc, try std.fs.path.join(alloc, &.{ chat_store.chat_root, e.name }));
    }
}

const Pair = struct { a: []const u8, b: []const u8 };

/// `a_b` split into two canonical uids, or null when the name is not a DM key.
fn dmPair(name: []const u8) ?Pair {
    const us = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    const a = name[0..us];
    const b = name[us + 1 ..];
    if (!canonicalUid(a) or !canonicalUid(b)) return null;
    return .{ .a = a, .b = b };
}

fn canonicalUid(s: []const u8) bool {
    if (s.len == 0 or s[0] == '0') return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Drop a removed uid's line from each `channels/*.channel`, rewriting the file
/// through the Store; the channel itself stays.
fn pruneChannels(pl: *Plan, removed: *const UidSet) !void {
    const alloc = pl.alloc;
    const chan_dir = try std.fs.path.join(alloc, &.{ chat_store.chat_root, "channels" });
    const entries = try store.list(pl.io, alloc, chan_dir);
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.name, ".channel")) continue;
        const path = try std.fs.path.join(alloc, &.{ chan_dir, e.name });
        const body = (try store.readOrNull(pl.io, alloc, path, .unlimited)) orelse continue;
        var kept: std.ArrayList(u8) = .empty;
        var dropped: usize = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            // A real member line (uid) that is removed goes; blanks, comments
            // and surviving lines are copied verbatim.
            if (line.len != 0 and line[0] != '#' and removed.has(line)) {
                dropped += 1;
                continue;
            }
            try kept.appendSlice(alloc, raw);
            try kept.append(alloc, '\n');
        }
        if (dropped == 0) continue;
        const chan = e.name[0 .. e.name.len - ".channel".len];
        try pl.record(.channel_member, try std.fmt.allocPrint(alloc, "{s} ({d} dropped)", .{ chan, dropped }));
        if (pl.apply) try store.replace(pl.io, alloc, path, kept.items, .{});
    }
}

// ── phase 3: the reference sweep ──────────────────────────────────────────────

/// A kept user's last-conv / last-sessions / pinned-sessions that points at a
/// conversation now gone. "Gone" is projected: a DM in `gone_dms`, or a conv
/// whose directory is not on disk. Channels are never removed, so a channel
/// pointer is gone only if the channel itself already was.
fn sweepReferences(pl: *Plan, removed: *const UidSet, gone_dms: *const UidSet, keep: []const []const u8) !void {
    const alloc = pl.alloc;
    const users_dir = try std.fs.path.join(alloc, &.{ chat_store.chat_root, "users" });
    const entries = try store.list(pl.io, alloc, users_dir);
    for (entries) |e| {
        if (e.kind != .directory) continue;
        const uid = e.name;
        // A removed user's whole state dir is (or will be) gone; only kept
        // users are swept. In a dry run the removed dirs are still on disk, so
        // skip them explicitly rather than trusting the disk.
        if (removed.has(uid)) continue;
        if (!keptUser(pl.io, alloc, uid, keep)) continue;
        const udir = try std.fs.path.join(alloc, &.{ users_dir, uid });

        // last-conv: a single conv key.
        const lc = try std.fs.path.join(alloc, &.{ udir, "last-conv" });
        if (try store.readOrNull(pl.io, alloc, lc, .unlimited)) |raw| {
            const conv = std.mem.trim(u8, raw, " \t\r\n");
            if (conv.len != 0 and convGone(pl.io, alloc, conv, gone_dms))
                try pl.rmFile(.ref_last_conv, try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ uid, conv }), lc);
        }

        // last-sessions/<conv>, pinned-sessions/<conv>: a file named by conv.
        try sweepDir(pl, udir, "last-sessions", .ref_last_session, uid, gone_dms);
        try sweepDir(pl, udir, "pinned-sessions", .ref_pinned, uid, gone_dms);
    }
}

fn sweepDir(pl: *Plan, udir: []const u8, sub: []const u8, kind: Kind, uid: []const u8, gone_dms: *const UidSet) !void {
    const alloc = pl.alloc;
    const dir = try std.fs.path.join(alloc, &.{ udir, sub });
    const entries = try store.list(pl.io, alloc, dir);
    for (entries) |e| {
        if (e.kind == .directory) continue;
        if (!convGone(pl.io, alloc, e.name, gone_dms)) continue;
        try pl.rmFile(kind, try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ uid, sub, e.name }), try std.fs.path.join(alloc, &.{ dir, e.name }));
    }
}

/// Whether the conversation named by `conv` is gone — projecting the removals.
/// A DM key in `gone_dms` is gone; otherwise the conv's directory decides (a
/// DM under chat_root, a channel under chat_root/channels).
fn convGone(io: Io, alloc: Alloc, conv: []const u8, gone_dms: *const UidSet) bool {
    if (gone_dms.has(conv)) return true;
    const is_dm = std.mem.indexOfScalar(u8, conv, '_') != null;
    const dir = if (is_dm)
        std.fs.path.join(alloc, &.{ chat_store.chat_root, conv }) catch return false
    else
        std.fs.path.join(alloc, &.{ chat_store.chat_root, "channels", conv }) catch return false;
    // A folder that will not say whether it is there is not gone: nothing is
    // swept on an error.
    // absent-ok: not kept here is only not swept (sweepReferences): the failure does less, never more.
    return !(store.has(io, alloc, dir) catch return false);
}

/// Whether `uid` is an account being kept: its auth dir is present and its name
/// is in the keep list. (A state dir can outlive its account; such an orphan is
/// not swept here — it is nobody's live pointer.)
fn keptUser(io: Io, alloc: Alloc, uid: []const u8, keep: []const []const u8) bool {
    const namef = std.fs.path.join(alloc, &.{ users.auth_root, uid, "name" }) catch return false;
    // absent-ok: not kept here is only not swept (sweepReferences): the failure does less, never more.
    const raw = store.read(io, alloc, namef, .unlimited) catch return false;
    return inList(keep, std.mem.trimEnd(u8, raw, "\r\n"));
}

fn convDisplayKey(alloc: Alloc, dir: []const u8) ![]const u8 {
    const base = std.fs.path.basename(dir);
    const parent = std.fs.path.dirname(dir) orelse "";
    if (std.mem.eql(u8, std.fs.path.basename(parent), "channels"))
        return std.fmt.allocPrint(alloc, "channel/{s}", .{base});
    return base;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const roots = @import("roots.zig");

/// Roots the test moved, restored so the rest of the binary sees the defaults.
const Saved = struct {
    data: []const u8,
    users_r: []const u8,
    players: []const u8,
    secret: []const u8,
    chat: []const u8,
    auth: []const u8,
    sd: ?[]const u8,
    sa: ?[]const u8,
    fn take() Saved {
        return .{
            .data = storage.data_root,
            .users_r = users.users_root,
            .players = player.player_root,
            .secret = users.session_secret_dir,
            .chat = chat_store.chat_root,
            .auth = users.auth_root,
            .sd = store.data_base,
            .sa = store.auth_base,
        };
    }
    fn restore(s: Saved) void {
        storage.data_root = s.data;
        users.users_root = s.users_r;
        player.player_root = s.players;
        users.session_secret_dir = s.secret;
        chat_store.chat_root = s.chat;
        users.auth_root = s.auth;
        store.data_base = s.sd;
        store.auth_base = s.sa;
    }
};

/// A transcript of one message dated `at`, in the on-disk form the decoder reads.
fn tx(a: Alloc, sid: []const u8, at: i64) ![]u8 {
    const date = try timefmt.formatRFC3339UTC(a, at);
    return std.fmt.allocPrint(a, "MSG_{s}_1\nfrom: Tester\ndate: {s}\n\nhello there", .{ sid, date });
}

fn sessionPath(a: Alloc, conv_dir: []const u8, sid: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ conv_dir, "sessions", try std.fmt.allocPrint(a, "{s}.md", .{sid}) });
}

const now: i64 = 1_700_000_000; // a fixed "now" for the fixture
const old_at: i64 = now - 100 * std.time.s_per_day; // retire
const new_at: i64 = now - 5 * std.time.s_per_day; // keep

/// Stages a tree: members Steve(1), apoorva(2), Spammer(9 — not kept); a DM 1_2
/// with an old and a new topic; a DM 1_9 (with the removed user) with a topic; a
/// channel `general` with members 1,2,9 and an old topic; the removed user's
/// state everywhere; and kept user 1's pointers, one into the DM that will go
/// (last-conv, last-sessions/1_9) and one into a surviving DM (pinned 1_2).
fn stage(io: Io, a: Alloc) !void {
    // Accounts.
    for ([_][2][]const u8{ .{ "1", "Steve" }, .{ "2", "apoorva" }, .{ "9", "Spammer" } }) |m| {
        try store.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, m[0], "name" }), m[1], .{});
        try store.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, m[0], "password" }), "x", .{});
    }
    try store.write(io, a, try std.fs.path.join(a, &.{ users.auth_root, "next-id.txt" }), "10\n", .{});

    // DM 1_2: an old topic and a new one.
    const dm12 = try chat_store.dmConvDir(a, "1_2");
    try store.write(io, a, try sessionPath(a, dm12, "oldtopic"), try tx(a, "oldtopic", old_at), .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ dm12, "sessions", "oldtopic.count" }), "1 0\n", .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ dm12, "sessions", "oldtopic.uploads", "pic.png" }), "img", .{});
    try store.write(io, a, try sessionPath(a, dm12, "freshtopic"), try tx(a, "freshtopic", new_at), .{});

    // DM 1_9: a topic, the whole conv goes when 9 does.
    const dm19 = try chat_store.dmConvDir(a, "1_9");
    try store.write(io, a, try sessionPath(a, dm19, "chat"), try tx(a, "chat", new_at), .{});

    // Channel general: members 1,2,9; an old topic.
    try store.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), "1\n2\n9\n", .{});
    const gen = try chat_store.channelConvDir(a, "general");
    try store.write(io, a, try sessionPath(a, gen, "oldchan"), try tx(a, "oldchan", old_at), .{});

    // The removed user's state everywhere it lives.
    for ([_][]const u8{ users.users_root, player.player_root, storage.data_root }) |r|
        try store.write(io, a, try std.fs.path.join(a, &.{ r, "9", "marker" }), "x", .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "9", "last-conv" }), "1_9", .{});

    // Kept user 1's pointers: into the DM that will go, and into one that stays.
    const user1 = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1" });
    try store.write(io, a, try std.fs.path.join(a, &.{ user1, "last-conv" }), "1_9", .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ user1, "last-sessions", "1_9" }), "chat", .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ user1, "pinned-sessions", "1_2" }), "freshtopic", .{});
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

    const saved = Saved.take();
    defer saved.restore();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try roots.point(a, .{
        .data_dir = try std.fs.path.join(a, &.{ base, "data" }),
        .auth_dir = try std.fs.path.join(a, &.{ base, "auth" }),
    });
    try stage(io, a);

    const p = Params{ .days = 30, .keep = &.{ "Steve", "apoorva" }, .now = now };

    // Dry run: it changes nothing and names the removals.
    var dry = try plan(io, a, p, false);
    try testing.expectEqual(@as(usize, 1), dry.members_removed); // uid 9
    try testing.expectEqual(@as(usize, 2), dry.countOf(.topic)); // oldtopic, oldchan
    try testing.expectEqual(@as(usize, 1), dry.countOf(.dm)); // 1_9
    try testing.expectEqual(@as(usize, 1), dry.countOf(.channel_member)); // general drops 9
    try testing.expectEqual(@as(usize, 1), dry.countOf(.ref_last_conv)); // 1 -> 1_9
    try testing.expectEqual(@as(usize, 1), dry.countOf(.ref_last_session)); // 1/last-sessions/1_9
    try testing.expectEqual(@as(usize, 0), dry.countOf(.ref_pinned)); // 1_2 survives
    // The dry run touched nothing.
    try testing.expect(try store.has(io, a, try std.fs.path.join(a, &.{ users.auth_root, "9", "name" })));
    try testing.expect(try store.has(io, a, try sessionPath(a, try chat_store.dmConvDir(a, "1_2"), "oldtopic")));

    // Confirm: the same report, carried out.
    var done = try plan(io, a, p, true);
    try testing.expectEqual(dry.total(), done.total());

    // The removed user is gone everywhere.
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ users.auth_root, "9" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ player.player_root, "9" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ users.users_root, "9" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ storage.data_root, "9" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "9" })));
    try testing.expect(!try store.has(io, a, try chat_store.dmConvDir(a, "1_9")));

    // The old topic and its sidecars are gone; the fresh topic stays.
    const dm12 = try chat_store.dmConvDir(a, "1_2");
    try testing.expect(!try store.has(io, a, try sessionPath(a, dm12, "oldtopic")));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ dm12, "sessions", "oldtopic.count" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ dm12, "sessions", "oldtopic.uploads" })));
    try testing.expect(try store.has(io, a, try sessionPath(a, dm12, "freshtopic")));

    // The channel stays, without uid 9; members 1 and 2 remain.
    const chan = try store.read(io, a, try std.fs.path.join(a, &.{ chat_store.chat_root, "channels", "general.channel" }), .unlimited);
    try testing.expect(std.mem.indexOf(u8, chan, "9") == null);
    try testing.expect(std.mem.indexOf(u8, chan, "1") != null and std.mem.indexOf(u8, chan, "2") != null);

    // Kept user 1: the pointer into the gone DM is cleared; the surviving pin stays.
    const user1 = try std.fs.path.join(a, &.{ chat_store.chat_root, "users", "1" });
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ user1, "last-conv" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ user1, "last-sessions", "1_9" })));
    try testing.expect(try store.has(io, a, try std.fs.path.join(a, &.{ user1, "pinned-sessions", "1_2" })));

    // A second confirm finds nothing left to do.
    var again = try plan(io, a, p, true);
    try testing.expectEqual(@as(usize, 0), again.total());
    try testing.expectEqual(@as(usize, 0), again.members_removed);
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

    const saved = Saved.take();
    defer saved.restore();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try roots.point(a, .{
        .data_dir = try std.fs.path.join(a, &.{ base, "data" }),
        .auth_dir = try std.fs.path.join(a, &.{ base, "auth" }),
    });
    const dm = try chat_store.dmConvDir(a, "1_2");
    try store.write(io, a, try sessionPath(a, dm, "empty"), "", .{});
    try store.write(io, a, try sessionPath(a, dm, "undated"), "MSG_undated_1\nfrom: X\n\nbody", .{});
    try store.write(io, a, try sessionPath(a, dm, "recent"), try tx(a, "recent", new_at), .{});
    try store.write(io, a, try sessionPath(a, dm, "stale"), try tx(a, "stale", old_at), .{});

    var dry = try plan(io, a, .{ .days = 30, .keep = &.{}, .now = now }, false);
    // Only the datably-old topic retires; empty, undated and recent all stay.
    // (No accounts, so no user removals.)
    try testing.expectEqual(@as(usize, 1), dry.countOf(.topic));
    try testing.expectEqual(@as(usize, 0), dry.members_removed);
    try testing.expectEqualStrings("1_2/stale", dry.items.items[0].name);
}

/// An Io whose file removals are refused under one path (all of them when
/// it is ""), as a store that will not delete (metal-vmm QUEUE 129).
var refuse_under: []const u8 = "";
fn refusingRemovals(io: Io, vt: *Io.VTable) Io {
    const refused = struct {
        fn deleteFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
            if (std.mem.indexOf(u8, sub_path, refuse_under) != null) return error.AccessDenied;
            return real.?.dirDeleteFile(userdata, dir, sub_path);
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

    const saved = Saved.take();
    defer saved.restore();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try roots.point(a, .{
        .data_dir = try std.fs.path.join(a, &.{ base, "data" }),
        .auth_dir = try std.fs.path.join(a, &.{ base, "auth" }),
    });
    try stage(io, a);
    const p = Params{ .days = 30, .keep = &.{ "Steve", "apoorva" }, .now = now };

    var vt: Io.VTable = undefined;
    refuse_under = "";
    try testing.expect(std.meta.isError(plan(refusingRemovals(io, &vt), a, p, true)));
    try testing.expect(try store.has(io, a, try std.fs.path.join(a, &.{ users.auth_root, "9", "name" })));

    // **AUTHORITY GOES LAST**: a removal refused under the user's game data
    // leaves the account, so it is still listed, and the next confirm
    // finishes the job.
    refuse_under = try std.fs.path.join(a, &.{ storage.data_root, "9" });
    try testing.expect(std.meta.isError(plan(refusingRemovals(io, &vt), a, p, true)));
    try testing.expect(try store.has(io, a, try std.fs.path.join(a, &.{ users.auth_root, "9", "name" })));
    _ = try plan(io, a, p, true);
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ users.auth_root, "9" })));
    try testing.expect(!try store.has(io, a, try std.fs.path.join(a, &.{ storage.data_root, "9" })));
    try testing.expect(!try store.has(io, a, try chat_store.dmConvDir(a, "1_9")));
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

    const saved = Saved.take();
    defer saved.restore();
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try roots.point(a, .{
        .data_dir = try std.fs.path.join(a, &.{ base, "data" }),
        .auth_dir = try std.fs.path.join(a, &.{ base, "auth" }),
    });
    try stage(io, a);
    // apoorva's name: there, and unreadable.
    const name = try std.fs.path.join(a, &.{ users.auth_root, "2", "name" });
    try store.remove(io, a, name);
    try store.makeDir(io, a, name);

    const p = Params{ .days = 30, .keep = &.{ "Steve", "apoorva" }, .now = now };
    _ = plan(io, a, p, true) catch {}; // refusing is right; removing her is not
    try testing.expect(try store.has(io, a, try std.fs.path.join(a, &.{ users.auth_root, "2" })));
}
