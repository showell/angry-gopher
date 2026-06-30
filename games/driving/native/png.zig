//! png — a minimal, allocator-free, I/O-free PNG encoder for the native Safari renderer.
//!
//! encode() builds a complete 8-bit RGB (color type 2) PNG into a caller-supplied buffer
//! and returns the filled slice; the caller writes it out. It uses STORED (uncompressed)
//! deflate blocks, so there is no zlib/compression dependency — the same zero-dep posture
//! as the rest of the renderer. Files are bigger than a compressed PNG, but these are
//! local verification snapshots (games/driving/snap/native), not shipped assets.
//!
//! Pixels are 0x00RRGGBB in a u32 (the framebuffer the rasterizer fills); the alpha byte
//! is ignored — the scene is fully opaque (the background fills every pixel).

const std = @import("std");

const SIG = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// encode writes a PNG of `pixels` (w*h, 0x00RRGGBB) into `out` and returns out[0..n].
/// `raw` holds the filtered scanlines, `zlib` the deflate stream — both caller-sized
/// (see native/main.zig) to keep this module allocator-free.
pub fn encode(pixels: []const u32, w: usize, h: usize, raw: []u8, zlib: []u8, out: []u8) []const u8 {
    // 1) filtered scanlines: each row is a filter byte (0 = None) + w RGB triples.
    const row_bytes = 1 + w * 3;
    std.debug.assert(raw.len >= h * row_bytes);
    var ri: usize = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        raw[ri] = 0; // filter: None
        ri += 1;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const px = pixels[y * w + x];
            raw[ri] = @intCast((px >> 16) & 0xff);
            raw[ri + 1] = @intCast((px >> 8) & 0xff);
            raw[ri + 2] = @intCast(px & 0xff);
            ri += 3;
        }
    }
    const raw_used = raw[0..ri];

    // 2) zlib stream: 2-byte header, STORED deflate blocks, adler32 trailer.
    var zi: usize = 0;
    zlib[zi] = 0x78;
    zlib[zi + 1] = 0x01;
    zi += 2;
    var off: usize = 0;
    while (off < raw_used.len) {
        const remain = raw_used.len - off;
        const block: usize = if (remain > 65535) 65535 else remain;
        const last = (off + block) >= raw_used.len;
        zlib[zi] = if (last) 1 else 0; // BFINAL bit, BTYPE = 00 (stored)
        zi += 1;
        const len_lo: u8 = @intCast(block & 0xff);
        const len_hi: u8 = @intCast((block >> 8) & 0xff);
        zlib[zi] = len_lo;
        zlib[zi + 1] = len_hi;
        zlib[zi + 2] = ~len_lo;
        zlib[zi + 3] = ~len_hi;
        zi += 4;
        @memcpy(zlib[zi .. zi + block], raw_used[off .. off + block]);
        zi += block;
        off += block;
    }
    writeBe(zlib[zi .. zi + 4], adler32(raw_used));
    zi += 4;
    const idat = zlib[0..zi];

    // 3) assemble the file: signature + IHDR + IDAT + IEND.
    @memcpy(out[0..8], &SIG);
    var p: usize = 8;
    var ihdr: [13]u8 = undefined;
    writeBe(ihdr[0..4], @intCast(w));
    writeBe(ihdr[4..8], @intCast(h));
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: RGB
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    p = chunk(out, p, "IHDR", &ihdr);
    p = chunk(out, p, "IDAT", idat);
    p = chunk(out, p, "IEND", &.{});
    return out[0..p];
}

// chunk writes [len][type][data][crc] at out[p..] and returns the new position.
fn chunk(out: []u8, p: usize, name: *const [4]u8, data: []const u8) usize {
    writeBe(out[p .. p + 4], @intCast(data.len));
    @memcpy(out[p + 4 .. p + 8], name);
    @memcpy(out[p + 8 .. p + 8 + data.len], data);
    var c = crc32(0xFFFFFFFF, name);
    c = crc32(c, data);
    writeBe(out[p + 8 + data.len .. p + 12 + data.len], c ^ 0xFFFFFFFF);
    return p + 12 + data.len;
}

fn writeBe(dst: []u8, v: u32) void {
    dst[0] = @intCast((v >> 24) & 0xff);
    dst[1] = @intCast((v >> 16) & 0xff);
    dst[2] = @intCast((v >> 8) & 0xff);
    dst[3] = @intCast(v & 0xff);
}

// CRC-32 (polynomial 0xEDB88320), tableless. `c` is the running pre-XOR state; pass
// 0xFFFFFFFF to start and XOR the final result with 0xFFFFFFFF (see chunk()).
fn crc32(c_in: u32, bytes: []const u8) u32 {
    var c = c_in;
    for (bytes) |b| {
        c ^= b;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
    }
    return c;
}

// Adler-32 over the uncompressed (filtered-scanline) data — the zlib stream's checksum.
fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}
