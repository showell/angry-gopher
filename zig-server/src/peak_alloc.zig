//! peak_alloc: an allocator that counts, for the benches: what it holds
//! now, and the most it ever held at once.

const std = @import("std");

/// An allocator that remembers the most it ever held at once.
pub const Peak = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    most: usize = 0,

    pub fn allocator(self: *Peak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grew(self: *Peak, by: usize) void {
        self.live += by;
        self.most = @max(self.most, self.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, al, ra) orelse return null;
        self.grew(len);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, al, n, ra)) return false;
        self.live -= m.len;
        self.grew(n);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, al, n, ra) orelse return null;
        self.live -= m.len;
        self.grew(n);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, al, ra);
        self.live -= m.len;
    }
};
