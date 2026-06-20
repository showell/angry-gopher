//! session_meta: the full-game `meta` DSL — the typed scalars (created_at,
//! label) the server owns at the top of the file, with the Elm-authored
//! game-state DSL preserved verbatim below a blank-line separator.
//!
//! The server never edits or parses the game-state DSL beyond pass-through; on
//! resume it ships meta + "---" + actions back and Elm reconstructs state.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// SessionMeta is the typed shape parsed out of a session's `meta` DSL file.
/// game_state_dsl is the raw Elm-authored remainder, kept verbatim.
pub const SessionMeta = struct {
    created_at: i64 = 0,
    label: []const u8 = "",
    game_state_dsl: []const u8 = "",
};

/// formatSessionMeta renders the on-disk shape: server-owned scalars, a blank
/// line, then the game-state DSL (with a trailing newline ensured).
pub fn formatSessionMeta(alloc: Alloc, m: SessionMeta) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc, "created_at: {d}\n", .{m.created_at});
    try b.print(alloc, "label: {s}\n", .{m.label});
    try b.append(alloc, '\n');
    try b.appendSlice(alloc, m.game_state_dsl);
    if (!std.mem.endsWith(u8, m.game_state_dsl, "\n")) try b.append(alloc, '\n');
    return b.toOwnedSlice(alloc);
}

/// parseSessionMeta fills SessionMeta.{created_at, label} from the leading
/// `key: value` lines up to (and including) the first blank line; everything
/// after is game_state_dsl, preserved verbatim. Slices borrow from `src`.
/// A faithful port of Go's ParseSessionMeta, including its `scanned` byte
/// accounting (sum of CR/LF-stripped line length + 1 per line).
pub fn parseSessionMeta(src: []const u8) SessionMeta {
    var m: SessionMeta = .{};
    var body_start: usize = 0;
    var scanned: usize = 0;
    var consumed_header = false;

    var lines = LineScanner{ .src = src };
    while (lines.next()) |line| {
        scanned += line.len + 1; // +1 for the consumed newline
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            body_start = scanned;
            consumed_header = true;
            break;
        }
        if (splitColon(trimmed)) |kv| {
            applyMetaScalar(&m, kv.key, kv.val);
        } else {
            // Non-scalar content (a section header like `board:`) without a
            // blank-line separator — body starts at this line.
            body_start = scanned - line.len - 1;
            consumed_header = true;
            break;
        }
    }
    if (!consumed_header) body_start = src.len;
    m.game_state_dsl = src[body_start..];
    return m;
}

/// createdAt returns the meta's created_at (0 if absent).
pub fn createdAt(m: SessionMeta) i64 {
    return m.created_at;
}

/// label returns meta.label.
pub fn label(m: SessionMeta) []const u8 {
    return m.label;
}

// ── internals ────────────────────────────────────────────────────────────────

/// LineScanner mimics bufio.Scanner with ScanLines: each next() yields the next
/// line with its trailing '\n' and a single trailing '\r' stripped (dropCR), and
/// no trailing empty token after a final newline.
const LineScanner = struct {
    src: []const u8,
    i: usize = 0,
    done: bool = false,

    fn next(self: *LineScanner) ?[]const u8 {
        if (self.done or self.i >= self.src.len) {
            self.done = true;
            return null;
        }
        const nl = std.mem.indexOfScalarPos(u8, self.src, self.i, '\n');
        if (nl) |end| {
            var line = self.src[self.i..end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1]; // dropCR
            self.i = end + 1;
            return line;
        }
        // Last line, no trailing newline.
        var line = self.src[self.i..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        self.i = self.src.len;
        self.done = true;
        return line;
    }
};

const KV = struct { key: []const u8, val: []const u8 };

/// splitColon splits `line` at the first ':'. Returns null when there's no
/// colon, or when it's a section header (`board:` / `... Hand:` with empty
/// value), matching Go's splitColon.
fn splitColon(line: []const u8) ?KV {
    const i = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..i], " \t");
    const val = std.mem.trim(u8, line[i + 1 ..], " \t");
    if (val.len == 0 and (std.mem.eql(u8, key, "board") or std.mem.endsWith(u8, key, "Hand"))) {
        return null;
    }
    return .{ .key = key, .val = val };
}

/// applyMetaScalar sets a recognized scalar; unknown keys are accepted-and-
/// ignored (forward-compat).
fn applyMetaScalar(m: *SessionMeta, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "created_at")) {
        if (std.fmt.parseInt(i64, val, 10)) |n| {
            m.created_at = n;
        } else |_| {}
    } else if (std.mem.eql(u8, key, "label")) {
        m.label = val;
    }
}
