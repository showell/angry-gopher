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
const Io = std.Io;
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
///
/// **THE SALT IS DRAWN HERE, NOT BY std.** std's `bcrypt.strHash` takes a real
/// `std.Io` and draws the salt through it — which is exactly
/// `io.random(&salt)` followed by `strHashWithSalt` (read it: CryptFormatHasher
/// .create). Doing those two steps here is the same bytes on Linux, and it lets
/// this module run on a machine whose `Io` is not std's: `io.random` is one of
/// the few things such a machine must provide, and `strHashWithSalt` needs no
/// `Io` at all. Passing our `io` straight to std compiled only where the alias
/// happened to BE std.Io.
pub fn hashPassword(password: []const u8, out: []u8, io: Io) ![]const u8 {
    var salt: [bcrypt.salt_length]u8 = undefined;
    io.random(&salt);
    return hashPasswordWithSalt(password, out, salt);
}

/// hashPasswordWithSalt is hashPassword with the salt supplied — deterministic,
/// and the half that carries the known-answer test below.
pub fn hashPasswordWithSalt(password: []const u8, out: []u8, salt: [bcrypt.salt_length]u8) ![]const u8 {
    return bcrypt.strHashWithSalt(password, .{
        .params = .{ .rounds_log = cost, .silently_truncate_password = false },
        .encoding = .crypt,
    }, out, salt);
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

// ── the hashing half ─────────────────────────────────────────────────────────
//
// The KNOWN ANSWER comes from outside this program: the frozen hash above was
// written by golang.org/x/crypto/bcrypt, the previous server. Its salt is the
// 22 characters after `$2a$10$`. Hash the same password with that salt at the
// same cost, and the only permitted difference is the version byte.

/// bcrypt's own base64: its own alphabet, no padding. A public fact of the
/// format — std keeps its codec private, so the test builds the same one.
const bcrypt_b64 = std.base64.Base64Decoder.init(
    "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".*,
    null,
);

const legacy_hash = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza";
const legacy_password = "correct horse battery staple";

fn saltOf(crypt: []const u8) ![bcrypt.salt_length]u8 {
    var salt: [bcrypt.salt_length]u8 = undefined;
    try bcrypt_b64.decode(&salt, crypt[7..29]);
    return salt;
}

test "hashPasswordWithSalt reproduces Go's hash byte for byte (known answer)" {
    var out: [crypt_len]u8 = undefined;
    const got = try hashPasswordWithSalt(legacy_password, &out, try saltOf(legacy_hash));
    // Same salt, same cost, same ciphertext: everything but the version tag.
    try std.testing.expectEqualStrings("$2b$" ++ legacy_hash[4..], got);
}

test "hashPasswordWithSalt: a different password under the same salt is a different hash" {
    var a: [crypt_len]u8 = undefined;
    var b: [crypt_len]u8 = undefined;
    const salt = try saltOf(legacy_hash);
    const ha = try hashPasswordWithSalt(legacy_password, &a, salt);
    const hb = try hashPasswordWithSalt(legacy_password ++ "X", &b, salt);
    try std.testing.expectEqualStrings(ha[0..29], hb[0..29]); // same tag, cost, salt
    try std.testing.expect(!std.mem.eql(u8, ha[29..], hb[29..])); // different ciphertext
}

test "hashPassword: the form, the cost, and it verifies" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [crypt_len]u8 = undefined;
    const h = try hashPassword("hunter2", &out, io);
    try std.testing.expectEqual(crypt_len, h.len);
    try std.testing.expect(std.mem.startsWith(u8, h, "$2b$10$"));
    try std.testing.expect(verifyPassword(h, "hunter2"));
    try std.testing.expect(!verifyPassword(h, "hunter3"));
    try std.testing.expect(!verifyPassword(h, ""));
}

test "hashPassword draws a fresh salt every time" {
    // If the salt were not drawn — left undefined, or zeroed — two hashes of one
    // password would share it. They must not.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a: [crypt_len]u8 = undefined;
    var b: [crypt_len]u8 = undefined;
    const ha = try hashPassword("same password", &a, io);
    const hb = try hashPassword("same password", &b, io);
    try std.testing.expect(!std.mem.eql(u8, ha[7..29], hb[7..29])); // the salts differ
    try std.testing.expect(!std.mem.eql(u8, ha, hb));
    try std.testing.expect(verifyPassword(ha, "same password"));
    try std.testing.expect(verifyPassword(hb, "same password"));
}

test "hashPassword: the salt it embeds is the salt it used" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a: [crypt_len]u8 = undefined;
    const h = try hashPassword("round trip", &a, io);
    var b: [crypt_len]u8 = undefined;
    const again = try hashPasswordWithSalt("round trip", &b, try saltOf(h));
    try std.testing.expectEqualStrings(h, again);
}

test "a password past 72 bytes is pre-hashed, not cut" {
    // bcrypt itself reads only 72 bytes. With silently_truncate_password=false,
    // std pre-hashes a longer password instead — so two passwords that differ
    // only AFTER byte 72 must not be interchangeable.
    const long_a = "a" ** 72 ++ "tail-one";
    const long_b = "a" ** 72 ++ "tail-two";
    var out: [crypt_len]u8 = undefined;
    const h = try hashPasswordWithSalt(long_a, &out, try saltOf(legacy_hash));
    try std.testing.expect(verifyPassword(h, long_a));
    try std.testing.expect(!verifyPassword(h, long_b));
}

test "verifyPassword refuses what is not a hash" {
    try std.testing.expect(!verifyPassword("", "x"));
    try std.testing.expect(!verifyPassword("not a hash at all", "not a hash at all"));
    try std.testing.expect(!verifyPassword(legacy_hash[0..59], legacy_password)); // truncated
    // The right length and prefix, but garbage inside.
    try std.testing.expect(!verifyPassword("$2a$10$" ++ "!" ** 53, legacy_password));
}
