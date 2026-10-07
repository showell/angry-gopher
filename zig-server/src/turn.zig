//! turn: **ONE HANDLER AT A TIME** (gopher-metal HOST.md; Steve, 2026-10-07).
//!
//! Linux accepts, reads and writes connections at once, but a handler runs
//! only inside the turn, so no two interleave: the route table runs as it
//! does on gopher-metal's single loop, and the application needs no locks of
//! its own. server.zig takes the turn around `route`; a test that stands in
//! for many handlers takes it as they would.

const std = @import("std");
const Io = std.Io;

var mu: Io.Mutex = .init;

/// Waits for the turn: no other handler is running once this returns.
pub fn enter(io: Io) void {
    mu.lockUncancelable(io);
}

/// Gives the turn to the next handler.
pub fn leave(io: Io) void {
    mu.unlock(io);
}
