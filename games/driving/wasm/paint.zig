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
//!
//! tag 3 = an alpha disc (see pushBeacon) — a tower's blinking apex beacon; tag 4 = a radial-gradient
//! polygon (see pushGradPoly) — the truck's headlight beams + brake glow. Tags 3 and 4 are the only
//! commands that composite with an alpha < 1. (There is no glyph command: the critters are baked to
//! polygons — emoji_frames.zig — so the seam is purely polygons + gradients.)

const camera = @import("camera.zig");

// 1 MiB of words — bounded so there is no memory.grow. Generous headroom: the critters are now full-body
// baked polygon sets (emoji_frames.zig), hundreds of points each, and we cull them only lightly (a close
// safari corner + a pig herd can fill a frame). Static .bss — cheap to oversize, and blit cost scales with
// polygons actually drawn, not the cap. The buf-peak HUD + ops/check_safari guard the real headroom.
const CAP_WORDS: usize = (1 << 20) / 4;
var buf: [CAP_WORDS]u32 = undefined;
var cursor: usize = 0; // next free word
var high_water: usize = 0; // max words used by any frame this run (instrumentation)

pub fn reset() void {
    cursor = 0;
}

/// byteLen: how many bytes of `buf` this frame filled — the blitter walks exactly
/// this many from ptr(). Also rolls the run-wide high-water mark, so the HUD can show
/// how close we ever came to the cap (a full buffer means push() silently dropped).
pub fn byteLen() u32 {
    if (cursor > high_water) high_water = cursor;
    return @intCast(cursor * 4);
}

/// highWaterBytes: the most bytes any single frame has used this run. If this ever
/// reaches capBytes(), the bounded buffer overflowed and commands were dropped.
pub fn highWaterBytes() u32 {
    return @intCast(high_water * 4);
}

/// capBytes: the fixed buffer size — the ceiling highWaterBytes() must stay under.
pub fn capBytes() u32 {
    return @intCast(CAP_WORDS * 4);
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

/// pushBeacon appends an alpha-disc command (tag 3): the tower beacon's blinking glow.
/// Layout: [tag 3][color u32][x][y][r][alpha] — a circle of radius `r` px centred at
/// (x, y), composited at `alpha` (0..1, the blink brightness). The blitter draws a true
/// arc at this alpha; unlike every other command it is NOT opaque, so it gets its own tag
/// rather than riding the solid-poly path (whose colour word has no alpha).
pub fn pushBeacon(color: u32, x: f32, y: f32, r: f32, alpha: f32) void {
    if (cursor + 6 > CAP_WORDS) return;
    buf[cursor] = 3;
    cursor += 1;
    buf[cursor] = color;
    cursor += 1;
    buf[cursor] = @bitCast(x);
    cursor += 1;
    buf[cursor] = @bitCast(y);
    cursor += 1;
    buf[cursor] = @bitCast(r);
    cursor += 1;
    buf[cursor] = @bitCast(alpha);
    cursor += 1;
}

/// pushGradPoly appends a radial-gradient-filled polygon (tag 4): a TRANSLUCENT shape — the truck's
/// headlight beams + brake-light glow. Layout: [tag 4][rgba_center u32][rgba_edge u32][cx][cy][r][nPts]
/// [x,y…]. The two colours are 0xAARRGGBB (alpha in the top byte); the blitter fills the polygon path with
/// a radial gradient centred at (cx, cy) radius r — rgba_center at the core, fading to rgba_edge at r. The
/// only non-opaque command besides the beacon disc (tag 3), so light reads as light, not a painted shape.
pub fn pushGradPoly(rgba_center: u32, rgba_edge: u32, cx: f32, cy: f32, r: f32, pts: []const camera.ScreenPt) void {
    if (pts.len < 3) return;
    const need = 6 + pts.len * 2;
    if (cursor + need > CAP_WORDS) return;
    buf[cursor] = 4;
    cursor += 1;
    buf[cursor] = rgba_center;
    cursor += 1;
    buf[cursor] = rgba_edge;
    cursor += 1;
    buf[cursor] = @bitCast(cx);
    cursor += 1;
    buf[cursor] = @bitCast(cy);
    cursor += 1;
    buf[cursor] = @bitCast(r);
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
