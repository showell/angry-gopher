//! THE OLD ZIG'S ADMIN RETIRE PLAN, KEPT AS THE TWIN'S ORACLE (metal-vmm
//! QUEUE 293): chat_retire.zig's `plan` and `keepProblem` as they were
//! before the plan moved to the Roc (roc-webbox chat/Retire.roc), held
//! here so chat_actions_twin_test.zig's `retireRun` can run the retire
//! tests' trees through both and compare: the Roc's retire must never
//! remove more than this did. Test-only; nothing in the server reaches it.

const std = @import("std");
const chat_paths = @import("chat_paths.zig");
const chat_codec = @import("chat_codec.zig");
const decimal = @import("decimal.zig");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const store = @import("webbox").store;
const search_index = @import("search_index.zig");
const chat_store = @import("chat_store.zig");
const timefmt = @import("timefmt.zig");
const users = @import("users.zig");
const player = @import("player.zig");
const storage = @import("storage.zig");
const retire = @import("chat_retire.zig");
const Kind = retire.Kind;
const Item = retire.Item;
const Mode = retire.Mode;
const Params = retire.Params;

/// The engine: what it would remove (always), and — when its mode is
/// `apply` — the Io it removes through. `members_removed` is the count of
/// accounts not kept.
pub const Plan = struct {
    alloc: Alloc,
    io: Io,
    mode: Mode,
    items: std.ArrayList(Item) = .empty,
    members_removed: usize = 0,

    fn record(
        self: *Plan,
        kind: Kind,
        name: []const u8,
    ) !void {
        try self.items.append(self.alloc, .{ .kind = kind, .name = name });
    }

    /// Record a file/dir removal, and carry it out when applying. A file not
    /// there is not an error — the caller wanted it gone. **ONE THAT FAILED
    /// IS** (metal-vmm QUEUE 129): it was `catch {}`, and a confirm on a
    /// store that refused reported everything removed. The error ends the
    /// confirm, and the admin's page is the router's 500.
    fn rmFile(
        self: *Plan,
        kind: Kind,
        name: []const u8,
        path: []const u8,
    ) !void {
        try self.record(kind, name);
        if (self.mode == .apply) try store.remove(
            self.io,
            self.alloc,
            path,
        );
    }

    fn rmTree(
        self: *Plan,
        kind: Kind,
        name: []const u8,
        path: []const u8,
    ) !void {
        try self.record(kind, name);
        if (self.mode == .apply) try store.removeTree(
            self.io,
            self.alloc,
            path,
        );
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

    fn add(
        self: *UidSet,
        alloc: Alloc,
        id: []const u8,
    ) !void {
        if (self.has(id)) return;
        try self.ids.append(alloc, id);
    }
    fn has(self: *const UidSet, id: []const u8) bool {
        for (self.ids.items) |x| if (std.mem.eql(
            u8,
            x,
            id,
        )) return true;
        return false;
    }
};

/// **THE KEEP LIST NAMES REAL ACCOUNTS, AND EVERY ACCOUNT HAS A NAME** (the
/// normalization hunt, 2026-10-10): every account not kept is removed, so a
/// keep name that matches no account (a typo) would keep no one by it, and an
/// account with no name could not be kept at all. Either is said, and the
/// whole plan is refused, the dry run too, before anything is touched.
/// Answers what is wrong, or null.
pub fn keepProblem(
    io: Io,
    alloc: Alloc,
    keep: []const []const u8,
) !?[]const u8 {
    const members = try allMembers(io, alloc);
    for (members) |m| {
        if (m.name.len == 0) return try std.fmt.allocPrint(
            alloc,
            "Account {s} has no name; give it one before retiring.",
            .{m.id},
        );
    }
    for (keep) |k| {
        for (members) |m| {
            if (std.mem.eql(
                u8,
                m.name,
                k,
            )) break;
        } else return try std.fmt.allocPrint(
            alloc,
            "The keep list names \"{s}\", which is no account's name.",
            .{k},
        );
    }
    return null;
}

/// Builds (and, its mode `apply`, carries out) the retirement. The returned Plan's
/// `items` and strings are allocated from `alloc`.
pub fn plan(
    io: Io,
    alloc: Alloc,
    p: Params,
    mode: Mode,
) !Plan {
    if (try keepProblem(
        io,
        alloc,
        p.keep,
    ) != null) return error.BadKeepList;
    var pl = Plan{
        .alloc = alloc,
        .io = io,
        .mode = mode,
    };
    // **AFTER A RETIRE APPLIES, SEARCH IS BUILT AGAIN WHOLE** (metal-vmm
    // 155(b)): rare, and always right, a failure part way included.
    defer if (mode == .apply) search_index.rebuild(io, alloc);
    const cutoff = p.now - @as(i64, p.days) * std.time.s_per_day;

    // Phase 1: old topics, in every conversation (DMs and channels alike).
    // absent-ok: a retire that cannot list the conversations retires none: it removes less, never more.
    const convs = chat_paths.listConvDirs(io, alloc) catch &.{};
    for (convs) |dir| {
        const key = try convDisplayKey(alloc, dir);
        // absent-ok: the same, for one conversation's topics: kept.
        const sids = chat_paths.listTopics(
            io,
            alloc,
            dir,
        ) catch continue;
        for (sids) |sid| {
            // **A TOPIC WE CANNOT DATE IS KEPT** (Steve, 2026-10-04): an empty
            // or hand-damaged transcript may be a fresh topic someone just
            // made, so only a topic with a datable message older than the
            // cutoff is retired.
            const newest = newestUnix(
                io,
                alloc,
                dir,
                sid,
            ) orelse continue;
            if (newest >= cutoff) continue; // recent enough to keep
            try retireTopic(
                &pl,
                dir,
                key,
                sid,
            );
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
    try retireDMs(
        &pl,
        &removed,
        &gone_dms,
    );

    // Channel membership: a removed uid's line goes, the channel stays.
    try pruneChannels(&pl, &removed);

    // Phase 3: a kept user's pointers into a conversation now gone.
    try sweepReferences(
        &pl,
        &removed,
        &gone_dms,
        p.keep,
    );

    // **AUTHORITY GOES LAST** (metal-vmm QUEUE 129): the roster is read from
    // auth_root, so a removed user's account goes only once everything else
    // of theirs did. A removal refused before it leaves the user listed, and
    // the next confirm finishes the job; refused here, the account stays,
    // still able to log in, and the confirm is an error, never "removed".
    if (pl.mode == .apply) for (removed.ids.items) |id| {
        // Its password last within it (`users.removeAccount`, QUEUE 138(f)).
        try users.removeAccount(
            io,
            alloc,
            id,
        );
    };

    return pl;
}

// ── phase 1: topics ───────────────────────────────────────────────────────────

/// The newest `date:` across a topic's messages, in unix seconds, or null
/// when it has no message that carries a parseable date (an empty or
/// hand-damaged transcript) — which the caller keeps, not retires.
fn newestUnix(
    io: Io,
    alloc: Alloc,
    conv_dir: []const u8,
    sid: []const u8,
) ?i64 {
    // absent-ok: a topic that cannot be dated is kept, not retired (Steve, 2026-10-04).
    const raw = (chat_paths.readTranscript(
        io,
        alloc,
        conv_dir,
        sid,
    ) catch return null) orelse return null;
    const msgs = chat_codec.decodeChatFile(alloc, raw) catch return null;
    var newest: ?i64 = null;
    for (msgs) |m| {
        if (timefmt.unixFromRFC3339(m.at)) |t| {
            if (newest == null or t > newest.?) newest = t;
        }
    }
    return newest;
}

fn retireTopic(
    pl: *Plan,
    conv_dir: []const u8,
    key: []const u8,
    sid: []const u8,
) !void {
    const alloc = pl.alloc;
    const sess = try std.fs.path.join(alloc, &.{ conv_dir, "sessions" });
    try pl.rmFile(
        .topic,
        try std.fmt.allocPrint(
            alloc,
            "{s}/{s}",
            .{ key, sid },
        ),
        try std.fs.path.join(alloc, &.{ sess, try std.fmt.allocPrint(
            alloc,
            "{s}.md",
            .{sid},
        ) }),
    );
    // Sidecars go with the topic; they are not listed on their own. No server
    // writes `.lastauthor` now (zig-metal-unikernel 153(1)): one an older server
    // left goes too.
    for ([_][]const u8{
        ".count",
        ".lastauthor",
        ".reactions.jsonl",
    }) |suf| {
        const f = try std.fs.path.join(alloc, &.{ sess, try std.fmt.allocPrint(
            alloc,
            "{s}{s}",
            .{ sid, suf },
        ) });
        if (pl.mode == .apply) try store.remove(
            pl.io,
            alloc,
            f,
        );
    }
    const up = try std.fs.path.join(alloc, &.{ sess, try std.fmt.allocPrint(
        alloc,
        "{s}.uploads",
        .{sid},
    ) });
    if (pl.mode == .apply) try store.removeTree(
        pl.io,
        alloc,
        up,
    );
}

// ── phase 2: users ──────────────────────────────────────────────────────────

const Member = struct { id: []const u8, name: []const u8 };

/// Every account with a numeric dir under auth_root, by id and name. Not
/// `userIsAuthorized`-filtered (an account without a password is still an
/// account to keep or remove); `next-id.txt` and other non-numeric names are
/// skipped.
fn allMembers(io: Io, alloc: Alloc) ![]Member {
    const entries = try store.list(
        io,
        alloc,
        users.auth_root,
    );
    var out: std.ArrayList(Member) = .empty;
    for (entries) |e| {
        if (e.kind != .directory) continue;
        _ = decimal.parseInt(u64, e.name) orelse continue;
        const id = try alloc.dupe(u8, e.name);
        try out.append(alloc, .{ .id = id, .name = try users.getUserName(
            io,
            alloc,
            id,
        ) });
    }
    return out.toOwnedSlice(alloc);
}

/// A removed user, everywhere it lives but the DMs (those are retireDMs, so a
/// DM shared by two removed users is listed once) and its account (auth_root,
/// removed last, by `plan`).
fn retireUser(pl: *Plan, id: []const u8) !void {
    const alloc = pl.alloc;
    // absent-ok: the name only labels the plan's line; the removal goes by uid.
    const name = users.getUserName(
        pl.io,
        alloc,
        id,
    ) catch "";
    try pl.record(.user, try std.fmt.allocPrint(
        alloc,
        "{s} (uid {s})",
        .{ name, id },
    ));
    const locations = [_][]const u8{
        player.player_root,
        users.users_root,
        storage.data_root,
        try std.fs.path.join(alloc, &.{ chat_store.chat_root, "users" }),
    };
    for (locations) |root| {
        const path = try std.fs.path.join(alloc, &.{ root, id });
        if (pl.mode == .apply) try store.removeTree(
            pl.io,
            alloc,
            path,
        );
    }
}

/// Every DM directory `a_b` that includes a removed uid: removed whole (its
/// messages too — the other party is gone), the key noted in `gone`.
fn retireDMs(
    pl: *Plan,
    removed: *const UidSet,
    gone: *UidSet,
) !void {
    const alloc = pl.alloc;
    const entries = try store.list(
        pl.io,
        alloc,
        chat_store.chat_root,
    );
    for (entries) |e| {
        if (e.kind != .directory) continue;
        const pair = dmPair(e.name) orelse continue;
        if (!removed.has(pair.a) and !removed.has(pair.b)) continue;
        try pl.record(.dm, e.name);
        try gone.add(alloc, try alloc.dupe(u8, e.name));
        if (pl.mode == .apply) try store.removeTree(
            pl.io,
            alloc,
            try std.fs.path.join(alloc, &.{ chat_store.chat_root, e.name }),
        );
    }
}

const Pair = struct { a: []const u8, b: []const u8 };

/// `a_b` split into two canonical uids, or null when the name is not a DM key.
fn dmPair(name: []const u8) ?Pair {
    const us = std.mem.indexOfScalar(
        u8,
        name,
        '_',
    ) orelse return null;
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
    const entries = try store.list(
        pl.io,
        alloc,
        chan_dir,
    );
    for (entries) |e| {
        if (!std.mem.endsWith(
            u8,
            e.name,
            ".channel",
        )) continue;
        const path = try std.fs.path.join(alloc, &.{ chan_dir, e.name });
        const body = (try store.readOrNull(
            pl.io,
            alloc,
            path,
            .unlimited,
        )) orelse continue;
        var kept: std.ArrayList(u8) = .empty;
        var dropped: usize = 0;
        var it = std.mem.splitScalar(
            u8,
            body,
            '\n',
        );
        while (it.next()) |raw| {
            const line = std.mem.trim(
                u8,
                raw,
                " \t\r",
            );
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
        try pl.record(.channel_member, try std.fmt.allocPrint(
            alloc,
            "{s} ({d} dropped)",
            .{ chan, dropped },
        ));
        if (pl.mode == .apply) try store.replace(
            pl.io,
            alloc,
            path,
            kept.items,
            .{},
        );
    }
}

// ── phase 3: the reference sweep ──────────────────────────────────────────────

/// A kept user's last-conv / last-sessions / pinned-sessions that points at a
/// conversation now gone. "Gone" is projected: a DM in `gone_dms`, or a conv
/// whose directory is not on disk. Channels are never removed, so a channel
/// pointer is gone only if the channel itself already was.
fn sweepReferences(
    pl: *Plan,
    removed: *const UidSet,
    gone_dms: *const UidSet,
    keep: []const []const u8,
) !void {
    const alloc = pl.alloc;
    const users_dir = try std.fs.path.join(alloc, &.{ chat_store.chat_root, "users" });
    const entries = try store.list(
        pl.io,
        alloc,
        users_dir,
    );
    for (entries) |e| {
        if (e.kind != .directory) continue;
        const uid = e.name;
        // A removed user's whole state dir is (or will be) gone; only kept
        // users are swept. In a dry run the removed dirs are still on disk, so
        // skip them explicitly rather than trusting the disk.
        if (removed.has(uid)) continue;
        if (!keptUser(
            pl.io,
            alloc,
            uid,
            keep,
        )) continue;
        const udir = try std.fs.path.join(alloc, &.{ users_dir, uid });

        // last-conv: a single conv key.
        const lc = try std.fs.path.join(alloc, &.{ udir, "last-conv" });
        if (try store.readOrNull(
            pl.io,
            alloc,
            lc,
            .unlimited,
        )) |raw| {
            const conv = std.mem.trim(
                u8,
                raw,
                " \t\r\n",
            );
            if (conv.len != 0 and convGone(
                pl.io,
                alloc,
                conv,
                gone_dms,
            ))
                try pl.rmFile(
                    .ref_last_conv,
                    try std.fmt.allocPrint(
                        alloc,
                        "{s} -> {s}",
                        .{ uid, conv },
                    ),
                    lc,
                );
        }

        // last-sessions/<conv>, pinned-sessions/<conv>: a file named by conv.
        try sweepDir(
            pl,
            udir,
            "last-sessions",
            .ref_last_session,
            uid,
            gone_dms,
        );
        try sweepDir(
            pl,
            udir,
            "pinned-sessions",
            .ref_pinned,
            uid,
            gone_dms,
        );
    }
}

fn sweepDir(
    pl: *Plan,
    udir: []const u8,
    sub: []const u8,
    kind: Kind,
    uid: []const u8,
    gone_dms: *const UidSet,
) !void {
    const alloc = pl.alloc;
    const dir = try std.fs.path.join(alloc, &.{ udir, sub });
    const entries = try store.list(
        pl.io,
        alloc,
        dir,
    );
    for (entries) |e| {
        if (e.kind == .directory) continue;
        if (!convGone(
            pl.io,
            alloc,
            e.name,
            gone_dms,
        )) continue;
        try pl.rmFile(
            kind,
            try std.fmt.allocPrint(
                alloc,
                "{s}/{s}/{s}",
                .{
                    uid,
                    sub,
                    e.name,
                },
            ),
            try std.fs.path.join(alloc, &.{ dir, e.name }),
        );
    }
}

/// Whether the conversation named by `conv` is gone — projecting the removals.
/// A DM key in `gone_dms` is gone; otherwise the conv's directory decides (a
/// DM under chat_root, a channel under chat_root/channels).
fn convGone(
    io: Io,
    alloc: Alloc,
    conv: []const u8,
    gone_dms: *const UidSet,
) bool {
    if (gone_dms.has(conv)) return true;
    const is_dm = std.mem.indexOfScalar(
        u8,
        conv,
        '_',
    ) != null;
    const dir = if (is_dm)
        std.fs.path.join(alloc, &.{ chat_store.chat_root, conv }) catch return false
    else
        std.fs.path.join(alloc, &.{
            chat_store.chat_root,
            "channels",
            conv,
        }) catch return false;
    // A folder that will not say whether it is there is not gone: nothing is
    // swept on an error.
    // absent-ok: not kept here is only not swept (sweepReferences): the failure does less, never more.
    return !(store.has(
        io,
        alloc,
        dir,
    ) catch return false);
}

/// Whether `uid` is an account being kept: its auth dir is present and its name
/// is in the keep list. (A state dir can outlive its account; such an orphan is
/// not swept here — it is nobody's live pointer.)
fn keptUser(
    io: Io,
    alloc: Alloc,
    uid: []const u8,
    keep: []const []const u8,
) bool {
    const namef = std.fs.path.join(alloc, &.{
        users.auth_root,
        uid,
        "name",
    }) catch return false;
    // absent-ok: not kept here is only not swept (sweepReferences): the failure does less, never more.
    const raw = store.read(
        io,
        alloc,
        namef,
        .unlimited,
    ) catch return false;
    return inList(keep, std.mem.trimEnd(
        u8,
        raw,
        "\r\n",
    ));
}

fn convDisplayKey(alloc: Alloc, dir: []const u8) ![]const u8 {
    const base = std.fs.path.basename(dir);
    const parent = std.fs.path.dirname(dir) orelse "";
    if (std.mem.eql(
        u8,
        std.fs.path.basename(parent),
        "channels",
    ))
        return std.fmt.allocPrint(
            alloc,
            "channel/{s}",
            .{base},
        );
    return base;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(
        u8,
        x,
        name,
    )) return true;
    return false;
}
