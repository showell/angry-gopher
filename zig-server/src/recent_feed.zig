//! recent_feed: a doc's row in the Recent feed, as docs.zig publishes it
//! when a doc is saved: kind, at, who, slug, title, empties omitted. A
//! message's row, its excerpt and the backlog are the Roc's (roc-webbox
//! chat/Recent.roc; metal-vmm QUEUE 285 took the Zig's).

const std = @import("std");
const Alloc = std.mem.Allocator;
/// encodeDocEvent writes one doc recentEvent object into `j`. `who` is the
/// editor, already "You" for the viewer (docs are the viewer's own).
pub fn encodeDocEvent(j: *std.ArrayList(u8), alloc: Alloc, at: []const u8, who: []const u8, slug: []const u8, title: []const u8) !void {
    try j.print(alloc, "{{\"kind\":\"doc\",\"at\":{f}", .{std.json.fmt(at, .{})});
    try appendField(j, alloc, "who", who);
    try appendField(j, alloc, "slug", slug);
    try appendField(j, alloc, "title", title);
    try j.append(alloc, '}');
}

fn appendField(j: *std.ArrayList(u8), alloc: Alloc, name: []const u8, val: []const u8) !void {
    if (val.len == 0) return; // omitempty
    try j.print(alloc, ",\"{s}\":{f}", .{ name, std.json.fmt(val, .{}) });
}
