//! auth: the bcrypt password layer.
//!
//! The whole point of this module is one interop wrinkle that cost a probe to
//! find. zig's std bcrypt and the bcrypt that wrote the existing hashes
//! (golang.org/x/crypto/bcrypt, the previous server) compute the SAME KDF — for a
//! given (password, salt, cost) the 31-char ciphertext is bit-identical. But they
//! disagree on the version tag: the existing hashes are tagged `$2a$`, zig writes
//! `$2b$`. And zig's std `strVerify` recomputes the full crypt string (always with
//! its own `$2b$` tag) and compares the ENTIRE string, prefix included — so it
//! rejects a `$2a$` hash on the version byte alone, even though the ciphertext
//! matches. The frozen `$2a$` vector in the test below guards this — bcrypt has
//! no eyeball backstop, so a regression in the normalization is invisible
//! without it.
//!
//! Every stored password on the live site is a `$2a$` hash. So verifyPassword
//! normalizes the version byte to `b` before handing the string to std. That one
//! byte is the entire migration story: no re-hashing of existing users needed.

const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;

/// Cost factor — bcrypt's common default. Must match whatever cost set the
/// existing hashes (it does: those were also written at cost 10).
pub const cost: u6 = 10;

const crypt_len: usize = 60; // a modular-crypt bcrypt string is exactly 60 bytes

/// verifyPassword reports whether `password` matches the stored bcrypt hash.
///
/// `stored` may carry any bcrypt version tag (`$2a$`, `$2b$`, `$2y$`); the tag
/// is normalized to `b` so std's strict full-string compare lines up with the
/// matching ciphertext. silently_truncate_password is false (long passwords are
/// pre-hashed, not silently cut at 72 bytes).
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

test "verifyPassword reads legacy $2a$ hashes" {
    // A real bcrypt `$2a$` hash (cost 10) of "correct horse battery staple" — the
    // tag every password on the live site is stored under. This frozen vector
    // guards the `$2a$`→`$2b$` normalization above: if it regressed, no existing
    // member could log in. No Go, no oracle — just the durable read-the-legacy-
    // data property.
    const hash = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza";
    try std.testing.expect(verifyPassword(hash, "correct horse battery staple"));
    try std.testing.expect(!verifyPassword(hash, "correct horse battery stapleX"));
}
