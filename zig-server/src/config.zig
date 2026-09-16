//! config: how a LINUX process learns where its data is. Reads GOPHER_CONFIG
//! (a flat `key = value` file, path from the env var) for `data_dir` and
//! `auth_dir`, then hands both to roots.point — which owns the mapping from two
//! directories to every store's root. `auth_dir` defaults to ~/Auth.
//!
//! This file is host-side: it reads the environment, which a machine with no
//! operating system does not have. roots.zig is the half that crosses.
//!
//! When GOPHER_CONFIG is unset we leave each module's repo-relative default in
//! place, so a standalone `/driving` run still works with no config.

const std = @import("std");
const Io = std.Io;
const roots = @import("roots.zig");
const users = @import("users.zig");

/// load reads GOPHER_CONFIG (if set in `env`) and points storage + identity at
/// the live tree. Strings are allocated from `alloc` (expected to be a
/// long-lived allocator — the roots live for the whole process). No-op when the
/// var is unset, so a standalone /driving run needs no config.
pub fn load(io: Io, alloc: std.mem.Allocator, env: std.process.Environ.Map) !void {
    const path = env.get("GOPHER_CONFIG") orelse {
        std.debug.print("config: GOPHER_CONFIG unset — using repo-relative defaults\n", .{});
        return;
    };

    const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
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
        // the config's port key is ignored; the server hardcodes PORT in server.zig.
    }

    const dd = data_dir orelse {
        std.debug.print("config: {s} has no data_dir — using defaults\n", .{path});
        return;
    };

    try roots.point(alloc, .{
        .data_dir = dd,
        .auth_dir = auth_dir orelse try expandHome(alloc, env, "~/Auth"),
    });

    std.debug.print("config: data_dir={s}  auth_root={s}\n", .{ dd, users.auth_root });
}

/// expandHome turns a leading `~/` into $HOME. Other
/// forms pass through unchanged.
fn expandHome(alloc: std.mem.Allocator, env: std.process.Environ.Map, p: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "~/")) {
        const home = env.get("HOME") orelse return alloc.dupe(u8, p);
        return std.fs.path.join(alloc, &.{ home, p[2..] });
    }
    return alloc.dupe(u8, p);
}
