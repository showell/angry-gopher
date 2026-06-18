//! auth: the bcrypt password layer for the zig port, the zig counterpart to
//! Go's server/users password functions.
//!
//! The whole point of this module is one interop wrinkle that cost a probe to
//! find. zig's std bcrypt and Go's golang.org/x/crypto/bcrypt compute the SAME
//! KDF — for a given (password, salt, cost) the 31-char ciphertext is
//! bit-identical. But they disagree on the version tag: Go writes `$2a$`, zig
//! writes `$2b$`. And zig's std `strVerify` recomputes the full crypt string
//! (always with its own `$2b$` tag) and compares the ENTIRE string, prefix
//! included — so it rejects a Go `$2a$` hash on the version byte alone, even
//! though the ciphertext matches. (See check_bcrypt.zig; this was caught by the
//! gold harness, not by eye — bcrypt has no eyeball backstop.)
//!
//! Every stored password on the live site is a Go `$2a$` hash. So verifyPassword
//! normalizes the version byte to `b` before handing the string to std. That one
//! byte is the entire migration story: no re-hashing of existing users needed.
//! The reverse direction needs nothing — Go's bcrypt natively accepts zig's
//! `$2b$` output.

const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;

/// Cost factor. Matches Go's bcrypt.DefaultCost (== server/users.SetUserPassword).
pub const cost: u6 = 10;

const crypt_len: usize = 60; // a modular-crypt bcrypt string is exactly 60 bytes

/// verifyPassword reports whether `password` matches the stored bcrypt hash.
///
/// `stored` may carry any bcrypt version tag (`$2a$`, `$2b$`, `$2y$`); the tag
/// is normalized to `b` so std's strict full-string compare lines up with the
/// matching ciphertext. silently_truncate_password is false, matching Go (long
/// passwords are pre-hashed, not silently cut at 72 bytes).
pub fn verifyPassword(stored: []const u8, password: []const u8) bool {
    const opts = bcrypt.VerifyOptions{ .silently_truncate_password = false };

    // Normalize the version byte for crypt-format ($2x$) strings; pass anything
    // else (e.g. PHC) through untouched.
    if (stored.len == crypt_len and std.mem.startsWith(u8, stored, "$2")) {
        var buf: [crypt_len]u8 = undefined;
        @memcpy(&buf, stored);
        buf[2] = 'b';
        bcrypt.strVerify(&buf, password, opts) catch return false;
        return true;
    }

    bcrypt.strVerify(stored, password, opts) catch return false;
    return true;
}

/// hashPassword computes a fresh bcrypt hash (modular-crypt `$2b$` form) for a
/// new or changed password. The output lands in `out` (must be >= 60 bytes).
pub fn hashPassword(password: []const u8, out: []u8, io: std.Io) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = .{ .rounds_log = cost, .silently_truncate_password = false },
        .encoding = .crypt,
    }, out, io);
}
