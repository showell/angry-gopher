//! wasm — the board bridge compiled for the browser (the puzzle Hint
//! button). Built by ops/build_lynrummy_wasm into solver.wasm, served
//! by zig-server/src/puzzles.zig, driven by engine_glue.js.
//!
//! ABI (same style as the chess toys — one static buffer, no
//! allocator, no imports): the caller writes an arrangement line into
//! the io buffer and calls puzzleHint(len); the plan text is written
//! back into the same buffer. Non-negative return = plan length in
//! bytes (0 = the board is already clean); negative = no plan:
//!   -1  the input didn't parse (bad stack / bad card / bad multiset)
//!   -2  FUTILE — a proof that no clean cover exists
//!   -3  the solver gave up (give-up line): no verdict
//!   -4  internal distiller failure (a bug; fail loud, never invent)

const solver = @import("solver.zig");
const arrangement = @import("arrangement.zig");
const moves = @import("moves.zig");

var io_buf: [65536]u8 = undefined;

export fn ioPtr() [*]u8 {
    return &io_buf;
}

export fn ioCap() u32 {
    return io_buf.len;
}

export fn puzzleHint(len: u32) i32 {
    if (len > io_buf.len) return -1;
    const arr = arrangement.parse(io_buf[0..len]) catch return -1;
    const out = solver.solveArrangement(&arr) catch return -1;
    switch (out) {
        .solved => |sol| {
            var plan: moves.Plan = undefined;
            moves.distill(&arr, &sol.next, &plan) catch return -4;
            return @intCast(moves.formatPlan(&plan, &io_buf).len);
        },
        .futile => return -2,
        .unknown => return -3,
    }
}
