//! request_time: the time a request is handled at, read once.
//!
//! **ONE READING PER REQUEST, INSIDE THE TURN**: a chat handler reads the
//! clocks once, as it starts (`Now.read`), and hands the reading to whatever
//! stamps or compares a time: a message's and a reaction's `date`, a new
//! DM's dated topic, a doc's entry in Recent, presence, the search rate
//! limit. So everything one request writes carries one time, a request
//! that waited for the turn is stamped after the one that went first, and a
//! test hands in the time it wants (`Now.at`) instead of waiting for it.
//!
//! The host's own `Bus.at_unix_ms` is not it: that is read before the turn
//! is taken, for the request's log line.

const std = @import("std");
const Io = @import("host_io").Io;

pub const Now = struct {
    /// The wall clock, nanoseconds since the epoch: what is stamped and shown.
    real_ns: i96,
    /// The awake clock, nanoseconds since some boot: for intervals (a rate
    /// limit), which a change of the wall clock must not stretch or shrink.
    awake_ns: i96,

    /// Both clocks, now. Called once per request, as its handler starts.
    pub fn read(io: Io) Now {
        return .{ .real_ns = Io.Clock.now(.real, io).nanoseconds, .awake_ns = Io.Clock.now(.awake, io).nanoseconds };
    }

    /// A fixed time, for a test: `unix_s` seconds since the epoch on both
    /// clocks.
    pub fn at(unix_s: i64) Now {
        const ns = @as(i96, unix_s) * std.time.ns_per_s;
        return .{ .real_ns = ns, .awake_ns = ns };
    }

    /// The same request time, `secs` later (a test's way to let time pass).
    pub fn plus(self: Now, secs: i64) Now {
        const d = @as(i96, secs) * std.time.ns_per_s;
        return .{ .real_ns = self.real_ns + d, .awake_ns = self.awake_ns + d };
    }

    /// The wall clock in whole seconds since the epoch, as dates are written.
    pub fn unixSecs(self: Now) i64 {
        return @intCast(@divFloor(self.real_ns, std.time.ns_per_s));
    }

    /// The awake clock in milliseconds.
    pub fn awakeMs(self: Now) i64 {
        return @intCast(@divFloor(self.awake_ns, std.time.ns_per_ms));
    }
};

test "a fixed time reads back as itself, and time passes when asked" {
    const t = Now.at(1_761_400_000);
    try std.testing.expectEqual(@as(i64, 1_761_400_000), t.unixSecs());
    try std.testing.expectEqual(@as(i64, 1_761_400_000_000), t.awakeMs());
    try std.testing.expectEqual(@as(i64, 1_761_400_031), t.plus(31).unixSecs());
}
