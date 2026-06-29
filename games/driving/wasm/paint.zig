//! paint — the seam to JS. A fixed, pre-sized draw-command buffer in linear memory:
//! a flat list of filled polygons in paint order. zig writes; the JS blitter reads
//! the SAME bytes and fills. Pre-sized so the module never grows memory mid-frame
//! (the determinism caveat). Layout per polygon:
//!
//!   [tag u32][color u32][nPoints u32][x0 f32][y0 f32][x1 f32][y1 f32] ...
//!
//! tag 0 = solid fill; tag 1 = horizontal round gradient (dark edge → bright centre
//! → dark edge, across the polygon's x-extent) — the cylinder/cone shading the near
//! trees want. coords are the f32 bit pattern stored in a u32 word; the blitter reads
//! them back through a Float32Array view over the same words.

const camera = @import("camera.zig");

// 256 KiB of words — far more than a frame needs, bounded so there is no memory.grow.
const CAP_WORDS: usize = (1 << 18) / 4;
var buf: [CAP_WORDS]u32 = undefined;
var cursor: usize = 0; // next free word

pub fn reset() void {
    cursor = 0;
}

/// byteLen: how many bytes of `buf` this frame filled — the blitter walks exactly
/// this many from ptr().
pub fn byteLen() u32 {
    return @intCast(cursor * 4);
}

/// ptr: the byte offset of the buffer in linear memory (fixed; the blitter reads it
/// once and builds typed-array views at that offset).
pub fn ptr() u32 {
    return @intCast(@intFromPtr(&buf));
}

/// pushPoly appends one SOLID-filled polygon (tag 0).
pub fn pushPoly(color: u32, pts: []const camera.ScreenPt) void {
    push(0, color, pts);
}

/// pushRoundPoly appends one polygon filled with a horizontal round gradient (tag 1)
/// — the cylinder/cone shading (dark edges, bright centre) the near trees use.
pub fn pushRoundPoly(color: u32, pts: []const camera.ScreenPt) void {
    push(1, color, pts);
}

/// push appends one polygon command: tag, color (0xRRGGBB), and its screen points.
/// Drops it silently if it has fewer than 3 points or the bounded buffer is full.
fn push(tag: u32, color: u32, pts: []const camera.ScreenPt) void {
    if (pts.len < 3) return;
    const need = 3 + pts.len * 2;
    if (cursor + need > CAP_WORDS) return;
    buf[cursor] = tag;
    cursor += 1;
    buf[cursor] = color;
    cursor += 1;
    buf[cursor] = @intCast(pts.len);
    cursor += 1;
    for (pts) |p| {
        buf[cursor] = @bitCast(p.x);
        cursor += 1;
        buf[cursor] = @bitCast(p.y);
        cursor += 1;
    }
}
