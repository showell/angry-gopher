//! config: reads GOPHER_CONFIG (the same env-var + flat `key = value` file the
//! Go server reads) and points the storage + identity layers at Go's LIVE data
//! tree. This is how the zig port shares the live data dir (the fork-2 decision):
//! both binaries resolve their roots from one config file.
//!
//! Go (main.go + config.go) wires four roots from data_dir + auth_dir:
//!   lynrummy   = {data_dir}/lynrummy   -> storage.data_root
//!   chat       = {data_dir}/chat       -> users.session_secret_dir (the secret)
//!                                       + chat_store.chat_root (conversations)
//!   users      = {data_dir}/users      -> users.users_root
//!   auth       = {auth_dir} or ~/Auth  -> users.auth_root  (shared account store)
//!
//! When GOPHER_CONFIG is unset we leave each module's repo-relative default in
//! place, so a standalone `/driving` run still works with no config.

const std = @import("std");
const storage = @import("storage.zig");
const users = @import("users.zig");
const chat_store = @import("chat_store.zig");

/// load reads GOPHER_CONFIG (if set in `env`) and points storage + identity at
/// the live tree. Strings are allocated from `alloc` (expected to be a
/// long-lived allocator — the roots live for the whole process). No-op when the
/// var is unset, so a standalone /driving run needs no config.
pub fn load(io: std.Io, alloc: std.mem.Allocator, env: std.process.Environ.Map) !void {
    const path = env.get("GOPHER_CONFIG") orelse {
        std.debug.print("config: GOPHER_CONFIG unset — using repo-relative defaults\n", .{});
        return;
    };

    const body = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
        std.debug.print("config: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };

    var data_dir: ?[]const u8 = null;
    var auth_dir: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "data_dir")) {
            data_dir = try expandHome(alloc, env, val);
        } else if (std.mem.eql(u8, key, "auth_dir")) {
            auth_dir = try expandHome(alloc, env, val);
        }
        // port is Go's concern; the zig port owns PORT in server.zig.
    }

    const dd = data_dir orelse {
        std.debug.print("config: {s} has no data_dir — using defaults\n", .{path});
        return;
    };

    storage.data_root = try std.fs.path.join(alloc, &.{ dd, "lynrummy" });
    users.users_root = try std.fs.path.join(alloc, &.{ dd, "users" });
    users.session_secret_dir = try std.fs.path.join(alloc, &.{ dd, "chat" });
    chat_store.chat_root = try std.fs.path.join(alloc, &.{ dd, "chat" });
    users.auth_root = auth_dir orelse try expandHome(alloc, env, "~/Auth");

    std.debug.print("config: data_dir={s}  auth_root={s}\n", .{ dd, users.auth_root });
}

/// expandHome turns a leading `~/` into $HOME, mirroring Go's expandHome. Other
/// forms pass through unchanged.
fn expandHome(alloc: std.mem.Allocator, env: std.process.Environ.Map, p: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "~/")) {
        const home = env.get("HOME") orelse return alloc.dupe(u8, p);
        return std.fs.path.join(alloc, &.{ home, p[2..] });
    }
    return alloc.dupe(u8, p);
}
