//! markdown_text: the shared text primitives of the markdown subsystem — HTML
//! escaping plus the small character-class predicates. A pure leaf (imports
//! nothing but std), so every other markdown module can depend on it without a
//! cycle. Nothing here knows anything about blocks, inlines, or the dialect; it's
//! just "escape this text" and "what kind of byte is this".

const std = @import("std");

/// Budget bounds the REAL work a single render may do, replacing the old
/// superficial markup-density cap. The parser charges one unit per scan-step
/// (each byte a scanner examines, each delimiter the emphasis stack revisits);
/// the driving loops abort with error.Hostile once `spent` passes `ceiling`.
///
/// The ceiling is proportional to input size (`per_byte * len + base`) because
/// the parser is linear BY CONTRACT — the monotonic cursors (rb/rp/email_dead)
/// guarantee each position is touched O(1) times. So legit content stays far
/// under the ceiling no matter how dense, while a re-parse regression (a broken
/// cursor revisiting the same token) goes super-linear and trips it. That's the
/// point: this is the earned-knowledge guard, not a formatting-taste limit.
pub const Budget = struct {
    spent: usize = 0,
    ceiling: usize,

    /// per_byte is the allowed work-units per input byte; base covers fixed
    /// per-message overhead so tiny inputs aren't starved. Tuned from real data
    /// (markdown_hostile_probe over the prod corpus): the densest LINEAR work is
    /// ~4.5 units/byte (a string of `a_b_…`, all emphasis-delimiter runs); every
    /// real message and every documented adversarial shape sits at or below that,
    /// flat across input size. 16 is ~3.5× that worst linear case — unreachable
    /// by linear content, trivially blown by anything super-linear (a re-parse
    /// regression's units/byte climbs with N, e.g. ~N/2 for an O(n²) cursor).
    pub const per_byte: usize = 16;
    pub const base: usize = 256;

    pub fn forInput(md: []const u8) Budget {
        return .{ .ceiling = per_byte * md.len + base };
    }

    /// unlimited never blows — for trusted server content (blog, Links page) and
    /// for measurement runs that want the raw `spent` count.
    pub fn unlimited() Budget {
        return .{ .ceiling = std.math.maxInt(usize) };
    }

    pub fn charge(self: *Budget, n: usize) void {
        self.spent += n;
    }

    pub fn blown(self: *const Budget) bool {
        return self.spent > self.ceiling;
    }
};

/// RenderError is what the block + inline render layer can fail with: an OOM, or
/// error.Hostile when a Budget is blown mid-parse (caught at the entry points,
/// which substitute malformed_html). Shared so every layer threads one type.
pub const RenderError = std.mem.Allocator.Error || error{Hostile};

/// escapeInto appends `text` to `out` with the five HTML-significant bytes
/// turned into entities (& < > "), so caller-supplied text can never break out
/// of the surrounding markup. THE escaping primitive — every rendered string of
/// untrusted text passes through here.
pub fn escapeInto(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, ch),
        }
    }
}

pub fn isWordChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '_';
}

pub fn isSlugChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-';
}

pub fn isAttrNameChar(c: u8) bool {
    return isAsciiAlnum(c) or c == '-' or c == '_' or c == ':';
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isAsciiAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

pub fn isAsciiAlnum(c: u8) bool {
    return isAsciiAlpha(c) or isDigit(c);
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

/// isPunct reports whether c is an ASCII punctuation char (CommonMark's
/// definition), used by the emphasis flanking rules.
pub fn isPunct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
        (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

pub fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

pub fn eqlCI(s: []const u8, lower_lit: []const u8) bool {
    if (s.len != lower_lit.len) return false;
    for (s, lower_lit) |c, l| {
        if (lower(c) != l) return false;
    }
    return true;
}

pub fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (prefix, 0..) |p, n| {
        if (lower(haystack[n]) != lower(p)) return false;
    }
    return true;
}

pub fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
