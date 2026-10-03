#!/usr/bin/env python3
"""Breaks zig-server's security rules one at a time and reports every break
that `zig build test` does not notice.

    tools/mutate.py                 every mutant
    tools/mutate.py NAME...         just these (a file's name, as uid_cookie,
                                    runs all of that file's)
    tools/mutate.py --list          their names and what each breaks

The oracle is zig-server's `zig build test`: every unit test, the router's
included. A mutant is **killed** when that fails (a test failed, or one
panicked), and it **survives** when it passes: then the rule it broke is
one nothing checks. A mutant that does not compile says nothing about the
tests and is reported apart; so is one whose text is no longer in its file,
which means the list here has fallen behind the code.

The rules are the ones an attacker would want broken: the signed cookie
(uid_cookie), the Store's names and paths (store), the game store's limits
and whose address counts (game_limits), the admin's gate and the password
asked again (admin_ui, admin_secret, admin_backup), and the member session
(users). gopher-metal's tools/mutate_tcp.py is the same idea for its TCP.

Each mutant is applied to the committed file, and the file is put back with
`git checkout -- FILE` after every one, interrupted or not. It refuses to
start if a file it would touch has uncommitted changes, which it would
otherwise throw away.

Not part of ops/check: each mutant is one `zig build test`, in a cache
folder of its own that is removed after it (sharing zig-server's, fifty of
them filled a 25 GB disk), so the whole list takes most of an hour. Run it after
changing one of these rules, and add a mutant for a new one. Exit 0 when
every mutant is killed, 1 when any survives or is stale.

Known equivalent, so not listed: store.fatName's "." and ".." check, which
the trailing-dot rule after it refuses anyway.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, "zig-server")
SRC = "zig-server/src"

# (file, name, what it breaks, old text, new text). The old text must occur
# exactly once in the file.
MUTANTS = [
    # ── the signed gopher_uid ──
    ("uid_cookie", "mac-not-compared", "any MAC verifies",
     "if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, want, got)) return null;", "_ = &want;\n    _ = &got;"),
    ("uid_cookie", "id-not-validated", "a signed value over a bad id verifies",
     "if (it.next() != null or !validId(id)) return null;", "if (it.next() != null) return null;"),
    ("uid_cookie", "id-over-20-digits", "validId takes 21 digits",
     "if (digits.len == 0 or digits.len > 20) return false;", "if (digits.len == 0) return false;"),
    ("uid_cookie", "member-re-signed", "a member's unsigned cookie is re-signed",
     "if (users.principalAuthorized(io, alloc, id)) return false;", ""),
    ("uid_cookie", "marker-ignored", "an id already signed is re-signed again",
     "if (isMarked(io, alloc, id)) return false;", ""),
    ("uid_cookie", "no-grace", "a lost re-sign answer cannot be asked again",
     "return now - at >= grace_seconds;", "_ = now - at;\n    return true;"),
    ("uid_cookie", "window-never-shuts", "unsigned cookies honoured for ever",
     "return now < ends;", "_ = now < ends;\n    return true;"),
    ("uid_cookie", "unknown-id-re-signed", "an id no one has is re-signed",
     "if (!store.has(io, alloc, row) and !users.principalExists(io, alloc, id)) return false;", "_ = row;"),
    ("uid_cookie", "previous-secret-refused", "after a change of secret, players are lost",
     "if (try users.previousSecret(io, alloc)) |prev| return verify(prev, value);", ""),
    ("uid_cookie", "post-re-signed", "a POST is re-signed",
     "if (req.head.method != .GET) return null;", ""),
    ("uid_cookie", "re-signs-not-counted", "re-signs per address unbounded",
     "if (try game_limits.admitResign(io, client)) |r| return .{ .refused = r };", "_ = client;"),
    # ── the Store's names and paths ──
    ("store", "name-too-long", "a name past max_name",
     "if (name.len == 0 or name.len > max_name) return false;", "if (name.len == 0) return false;"),
    ("store", "control-character", "a control character in a name",
     "if (c < 0x20 or c > 0x7E) return false;", "if (c > 0x7E) return false;"),
    ("store", "past-ascii", "a byte past ASCII in a name",
     "if (c < 0x20 or c > 0x7E) return false;", "if (c < 0x20) return false;"),
    ("store", "colon", "a colon in a name",
     "'\"', '*', '/', ':', '<', '>', '?', '\\\\', '|' => return false,",
     "'\"', '*', '/', '<', '>', '?', '\\\\', '|' => return false,"),
    ("store", "trailing-dot-or-space", "a name ending in a dot or a space",
     "return last != '.' and last != ' ';", "_ = last;\n    return true;"),
    ("store", "trailing-space", "a name ending in a space",
     "return last != '.' and last != ' ';", "return last != '.';"),
    ("store", "no-length-limit", "a path metal could not hold, too long",
     "if (shape.len > max_path) return error.PathTooLong;", ""),
    ("store", "no-depth-limit", "a path metal could not hold, too deep",
     "if (shape.depth > max_depth) return error.PathTooDeep;", ""),
    ("store", "write-no-name-check", "a write makes a name FAT refuses",
     "fn forWrite(io: Io, alloc: Alloc, path: []const u8) ![]const u8 {\n    if (!fatName(std.fs.path.basename(path))) return error.BadName;",
     "fn forWrite(io: Io, alloc: Alloc, path: []const u8) ![]const u8 {"),
    ("store", "makedir-no-name-check", "a folder FAT refuses is made",
     "        if (!fatName(std.fs.path.basename(rest))) return error.BadName;\n        rest = std.fs.path.dirname(rest) orelse break;",
     "        rest = std.fs.path.dirname(rest) orelse break;"),
    ("store", "removetree-no-name-check", "removeTree takes a name FAT refuses",
     "pub fn removeTree(io: Io, alloc: Alloc, path: []const u8) !void {\n    if (!fatName(std.fs.path.basename(path))) return error.BadName;",
     "pub fn removeTree(io: Io, alloc: Alloc, path: []const u8) !void {"),
    ("store", "data2-under-data", "data2/ measured as under data/",
     "if (rest.len != 0 and rest[0] != '/') continue;", ""),
    ("store", "case-not-folded", "a name in another case is a new file",
     "if (std.ascii.eqlIgnoreCase(entry.name, name))", "if (std.mem.eql(u8, entry.name, name))"),
    # ── the game store's limits ──
    ("game_limits", "xff-from-anyone", "anyone's X-Forwarded-For believed",
     "if (!std.mem.eql(u8, p, proxy)) return try alloc.dupe(u8, p);", "_ = proxy;"),
    ("game_limits", "xff-first-entry", "the client's own first entry believed",
     "var parts = std.mem.splitBackwardsScalar(u8, xff, ',');", "var parts = std.mem.splitScalar(u8, xff, ',');"),
    ("game_limits", "xff-garbage", "a forwarded entry that is no address believed",
     "if (plausibleAddress(last)) return last;", "return last;"),
    ("game_limits", "address-any-length", "an address of any length",
     "if (s.len == 0 or s.len > addr_max) return false;", "if (s.len == 0) return false;"),
    ("game_limits", "address-any-character", "an address of any characters",
     "for (s) |c| if (!(std.ascii.isHex(c) or c == '.' or c == ':')) return false;", ""),
    ("game_limits", "no-floor", "game writes below a quarter free",
     "if (free_space) |f| if (f()) |s| if (s.free < s.total / 4) return .floor;", ""),
    ("game_limits", "floor-at-a-tenth", "the floor moved",
     "if (s.free < s.total / 4) return .floor;", "if (s.free < s.total / 10) return .floor;"),
    ("game_limits", "bad-id-counted", "an empty or overlong id admitted",
     "if (id.len == 0 or id.len > id_max) return .bytes;", ""),
    ("game_limits", "one-session-too-many", "the session bound one too loose",
     "if (new_session and u.sessions >= max_sessions) return .sessions;",
     "if (new_session and u.sessions > max_sessions) return .sessions;"),
    ("game_limits", "bytes-past-cap", "a write that crosses the byte cap",
     "if (u.bytes + bytes > max_bytes) return .bytes;", "if (u.bytes > max_bytes) return .bytes;"),
    ("game_limits", "address-bytes-unbounded", "an address's bytes an hour unbounded",
     "if (a) |s| if (s.bytes + bytes > bytes_per_hour) return .address_bytes;", ""),
    ("game_limits", "sessions-not-counted", "sessions never counted",
     "if (new_session) u.sessions += 1;", "if (new_session) u.sessions += 0;"),
    ("game_limits", "address-bytes-not-counted", "an address's bytes never counted",
     "if (a) |s| s.bytes += bytes;", ""),
    ("game_limits", "one-resign-too-many", "the re-sign bound one too loose",
     "if (s.resigns >= resigns_per_hour) return .address_resigns;",
     "if (s.resigns > resigns_per_hour) return .address_resigns;"),
    ("game_limits", "one-player-too-many", "the new-player bound one too loose",
     "if (s.players >= players_per_hour) return .address_players;",
     "if (s.players > players_per_hour) return .address_players;"),
    ("game_limits", "hour-never-restarts", "an address's hour never starts again",
     "if (t - s.since >= hour) s.* = fresh(addr, t);", ""),
    ("game_limits", "full-table-stuck", "a full table never gives up its oldest",
     "const s = free orelse oldest.?;", "const s = free orelse return &seen[0];"),
    # ── the admin, and the password asked again ──
    ("admin_ui", "any-member-is-admin", "any member reaches /admin",
     "if (!std.mem.eql(u8, uid, admin_uid)) {", "if (false) {"),
    ("admin_secret", "secret-no-password", "the secret changed without the password",
     "if (!users.checkUserPassword(io, alloc, ui.admin_uid, password))\n        return form(req, alloc, \"That is not the password.\", .forbidden);",
     "_ = password;"),
    ("admin_secret", "negative-days", "negative days taken",
     "if (days < 0 or days > max_days)", "if (days > max_days)"),
    ("admin_secret", "days-past-90", "more than 90 days taken",
     "if (days < 0 or days > max_days)", "if (days < 0)"),
    ("admin_backup", "backup-no-password", "the backup without the password",
     "if (!users.checkUserPassword(io, alloc, ui.admin_uid, password))\n        return form(req, alloc, \"That is not the password.\", .forbidden);",
     "_ = password;"),
    ("admin_backup", "head-walks-data", "a HEAD reads the whole backup",
     "if (req.head.method != .POST) return form(req, alloc, \"\", .ok);",
     "if (req.head.method == .GET) return form(req, alloc, \"\", .ok);"),
    # ── the member session ──
    ("users", "session-mac-not-compared", "any session MAC verifies",
     "if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, computed, presented)) return null;", "_ = &computed;"),
    ("users", "session-lasts-longer", "a session outlives its year",
     "if (now_unix - n > session_max_age_secs) return null;",
     "if (now_unix - n > session_max_age_secs * 1000) return null;"),
    ("users", "session-extra-parts", "a session with a fourth part",
     "if (it.next() != null) return null; // exactly 3 parts", ""),
    ("users", "non-member-session", "a session for an id that is not a member",
     "if (!try userIsMember(io, alloc, id)) return null;", ""),
    ("users", "uid-names-a-member", "a gopher_uid acts as a full member",
     "!try userIsAuthorized(io, alloc, uid)) {", "true) {"),
]


def path_of(file: str) -> str:
    return f"{SRC}/{file}.zig"


def run(mutants) -> int:
    files = sorted({m[0] for m in mutants})
    dirty = subprocess.run(["git", "status", "--porcelain", "--", *map(path_of, files)],
                           cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if dirty:
        print(f"mutate: uncommitted changes in a file it would touch; commit or stash them first:\n{dirty}")
        return 2
    counts = {"killed": 0, "SURVIVED": 0, "did not compile": 0, "STALE": 0}
    try:
        for file, name, what, old, new in mutants:
            p = os.path.join(ROOT, path_of(file))
            text = open(p).read()
            if text.count(old) != 1:
                verdict = "STALE"
            else:
                open(p, "w").write(text.replace(old, new))
                # **A CACHE OF ITS OWN, REMOVED AFTER.** Every mutant builds every
                # test binary anew, and in zig-server's .zig-cache fifty of
                # them filled a 25 GB disk. zig's global cache still holds std.
                cache = tempfile.mkdtemp(prefix="mutate-cache-")
                try:
                    r = subprocess.run(["zig", "build", "test", "--cache-dir", cache], cwd=SERVER,
                                       capture_output=True, text=True, timeout=1200)
                finally:
                    subprocess.run(["git", "checkout", "--", path_of(file)], cwd=ROOT, check=True)
                    shutil.rmtree(cache, ignore_errors=True)
                out = r.stdout + r.stderr
                if r.returncode == 0:
                    verdict = "SURVIVED"
                elif "failed:" in out or "terminated with signal" in out:
                    verdict = "killed"
                else:
                    verdict = "did not compile"
            counts[verdict] += 1
            print(f"{verdict:16} {file}:{name}  ({what})", flush=True)
    finally:
        subprocess.run(["git", "checkout", "--", *map(path_of, files)], cwd=ROOT)
    print("mutate: " + ", ".join(f"{n} {k}" for k, n in counts.items()))
    return 0 if counts["SURVIVED"] == 0 and counts["STALE"] == 0 else 1


def main(argv) -> int:
    if argv[1:] == ["--list"]:
        for file, name, what, _, _ in MUTANTS:
            print(f"{file}:{name}  {what}")
        return 0
    asked = argv[1:]
    chosen = [m for m in MUTANTS if not asked or m[0] in asked or m[1] in asked or f"{m[0]}:{m[1]}" in asked]
    if asked and not chosen:
        print(f"mutate: no mutant or file named {' '.join(asked)}; --list names them")
        return 2
    return run(chosen)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
