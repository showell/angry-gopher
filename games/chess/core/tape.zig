//! tape — the shared substrate every chess toy is built on: an EVENT TAPE
//! (place piece / remove piece, one byte per event) plus the display that
//! replays it. The tape is what makes the animations scrubbable: the search
//! MACHINE (owned by the toy — knight.zig, queens.zig) only ever appends
//! events at the tape's end; the DISPLAY walks a cursor over the tape,
//! applying events forward or inverting them backward. Events are
//! self-inverting because a remove always pulls the most recent piece.
//!
//! A toy instantiates `Substrate(@This())` and provides:
//!   target_count: u32          — pieces on board that mean SOLVED
//!   genOne() void              — run the machine one transition, appending
//!                                exactly one event (or setting `exhausted`)
//!   resetMachine() void        — clear the machine's own state
//!   computeImpossible() void   — refresh the toy's "no piece can live here
//!                                right now" overlay (its own mask + export)
//! then emits the shared wasm ABI with `exportAbi` — the single authority
//! for the export list, so the two toys can't drift apart.
//!
//! The dead-end overlay is substrate: dead_end[sq] = a piece was placed
//! there, found doomed, and pulled off — and none has come back. Because a
//! square's events strictly alternate place/remove, that is exactly "empty
//! AND touched by any event", so it falls out of the per-square `tried`
//! counter and stays correct under scrubbing in either direction.

pub fn Substrate(comptime Toy: type) type {
    return struct {
        // ---------- the event tape ----------

        // One byte per event: bit 7 set = place, clear = remove; low 6 bits
        // = square.
        pub const PLACE_BIT: u8 = 0x80;
        pub const TAPE_CAP: u32 = 1 << 22;
        pub var tape: [TAPE_CAP]u8 = undefined;
        pub var tape_len: u32 = 0;

        // ---------- the display (what the board shows) ----------

        pub var cur: u32 = 0; // events [0..cur) are applied to the board
        pub var board: [64]i8 = [_]i8{-1} ** 64; // move number per square, -1 = empty
        pub var on_board: u32 = 0; // pieces currently shown (= next move number)
        pub var tried: [64]u32 = [_]u32{0} ** 64; // events touching each square in [0..cur)

        // ---------- machine-facing state (lives at the tape's end) ----------

        pub var started = false;
        pub var solved = false;
        pub var exhausted = false; // the machine sets this when its search space is spent
        var gen_pieces: u32 = 0; // pieces at the tape's END (the machine's board depth)
        var best_depth: u32 = 0; // deepest the SEARCH has ever been

        /// appendPlace / appendRemove are the machine's only way to speak:
        /// each appends one event at the tape's end and keeps the
        /// generation-side piece count (and the solved flag) true. The
        /// machine's own bookkeeping — stacks, attack masks — stays in the toy.
        pub fn appendPlace(sq: u8) void {
            tape[tape_len] = PLACE_BIT | sq;
            tape_len += 1;
            gen_pieces += 1;
            if (gen_pieces > best_depth) best_depth = gen_pieces;
            if (gen_pieces == Toy.target_count) solved = true;
        }
        pub fn appendRemove(sq: u8) void {
            tape[tape_len] = sq;
            tape_len += 1;
            gen_pieces -= 1;
        }

        // ---------- the shared wasm ABI (emitted by exportAbi) ----------

        /// reset returns to the no-search state (the hover-the-graph warmup
        /// screen).
        pub fn reset() callconv(.c) void {
            tape_len = 0;
            cur = 0;
            board = [_]i8{-1} ** 64;
            tried = [_]u32{0} ** 64;
            on_board = 0;
            started = false;
            solved = false;
            exhausted = false;
            gen_pieces = 0;
            best_depth = 0;
            Toy.resetMachine();
        }

        /// stepForward advances the display one event, asking the machine to
        /// generate it first when the cursor is at the tape's end. Returns 1
        /// if it moved.
        pub fn stepForward() callconv(.c) u32 {
            if (!started) return 0;
            if (cur == tape_len and !solved and !exhausted and tape_len < TAPE_CAP) Toy.genOne();
            if (cur == tape_len) return 0; // solved / exhausted: nothing more to show
            const ev = tape[cur];
            cur += 1;
            const sq = ev & 63;
            tried[sq] += 1;
            if (ev & PLACE_BIT != 0) {
                board[sq] = @intCast(on_board);
                on_board += 1;
            } else {
                on_board -= 1;
                board[sq] = -1;
            }
            return 1;
        }

        /// stepBack rewinds the display one event (inverting it). Returns 1
        /// if it moved.
        pub fn stepBack() callconv(.c) u32 {
            if (cur == 0) return 0;
            cur -= 1;
            const ev = tape[cur];
            const sq = ev & 63;
            tried[sq] -= 1;
            if (ev & PLACE_BIT != 0) {
                on_board -= 1;
                board[sq] = -1;
            } else {
                board[sq] = @intCast(on_board);
                on_board += 1;
            }
            return 1;
        }

        /// boardPtr is the display board in linear memory: 64 bytes of i8,
        /// the move number per square (0 = the first piece) or -1 for empty.
        /// (usize = u32 on wasm32; this also compiles natively for tests.)
        pub fn boardPtr() callconv(.c) usize {
            return @intFromPtr(&board);
        }

        // dead_end[sq] = 1 when a piece was placed there, its continuations
        // were explored and found barren, and it was pulled off — and no
        // piece has come back since. Marked only at retraction (discovery),
        // never predictively; removal cascades accumulate marks.
        pub var dead_end: [64]u8 = [_]u8{0} ** 64;

        /// computeOverlays refreshes both display overlays — the substrate's
        /// dead_end mask and the toy's "impossible right now" mask. Both are
        /// pure functions of the displayed position, so they are exactly as
        /// scrubbed as the pieces are. The host calls it once per drawn frame.
        pub fn computeOverlays() callconv(.c) void {
            for (0..64) |sq| {
                dead_end[sq] = @intFromBool(board[sq] < 0 and tried[sq] > 0);
            }
            Toy.computeImpossible();
        }

        pub fn deadEndPtr() callconv(.c) usize {
            return @intFromPtr(&dead_end);
        }

        pub fn piecesOnBoard() callconv(.c) u32 {
            return on_board;
        }
        pub fn targetCount() callconv(.c) u32 {
            return Toy.target_count;
        }
        pub fn cursor() callconv(.c) u32 {
            return cur;
        }
        pub fn tapeLen() callconv(.c) u32 {
            return tape_len;
        }
        /// bestDepth is the deepest partial solution the SEARCH has reached
        /// so far (not the display) — the "closest it's gotten" HUD stat.
        pub fn bestDepth() callconv(.c) u32 {
            return best_depth;
        }
        pub fn isStarted() callconv(.c) u32 {
            return @intFromBool(started);
        }
        pub fn isSolved() callconv(.c) u32 {
            return @intFromBool(solved);
        }
        pub fn isExhausted() callconv(.c) u32 {
            return @intFromBool(exhausted);
        }
    };
}

/// exportAbi emits the shared wasm exports from an instantiated substrate.
/// Called once from a `comptime` block in each toy root, so there is exactly
/// one list of what the JS host may call.
pub fn exportAbi(comptime S: type) void {
    inline for (.{
        "reset",         "stepForward", "stepBack",  "boardPtr",
        "computeOverlays", "deadEndPtr", "piecesOnBoard", "targetCount",
        "cursor",        "tapeLen",     "bestDepth", "isStarted",
        "isSolved",      "isExhausted",
    }) |name| {
        @export(&@field(S, name), .{ .name = name });
    }
}
