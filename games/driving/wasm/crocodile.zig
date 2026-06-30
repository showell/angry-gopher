//! crocodile — the crocodile corner: a lagoon just BEYOND a right-turn intersection, off to its LEFT, with
//! seven crocodile emoji hauled out on the near bank. Authored in the INCOMING segment's corner frame (the
//! road the rider arrives on), exactly like crocodile.ts. safari_critter hands off here when a corner's
//! creature is CROCODILE — it's hand-drawn (a ground quad + emoji), not an emoji PAIR, so it lives apart.
//!
//! Frame: cv = metres BEYOND the incoming segment's end edge (the rider's forward as he arrives), cu =
//! metres across from its end-left corner (0 = left edge, + = toward the road; the lagoon's cu is NEGATIVE,
//! out to the left — the outer side of the right turn). render.zig maps corner(cu, cv) = at(from_len+cv, cu).
//!
//! Pure data + dimensions; the mapping/projection/emit lives in render.zig (it owns the frame mappers), the
//! same split safari_critter.zig uses. The late-route giant upsizing (crocodile.ts's CROC_GIANT_SCALE) is
//! OMITTED — Steve: never effective (same call as the other corner creatures).

pub const P = struct { cu: f32, cv: f32 };

// the lagoon outline, corner-frame metres: a big blob off the LEFT of the road, ~30m across (cu -1 → -31)
// and reaching ~30m beyond the intersection (cv 3 → 32). Its near edge (the flat front at cv 3) faces the
// incoming road. Mirrors LAGOON in crocodile.ts.
pub const LAGOON = [_]P{
    .{ .cu = -2, .cv = 3 },   .{ .cu = -28, .cv = 3 }, .{ .cu = -31, .cv = 14 }, .{ .cu = -26, .cv = 28 },
    .{ .cu = -15, .cv = 32 }, .{ .cu = -5, .cv = 29 }, .{ .cu = -1, .cv = 16 },
};
pub const WATER: u32 = 0x2f7e8c;

// a 1m khaki mud bank along the water's FAR edge — the shore the crocs sit on. Its inner edge hugs the
// water's far edge (the arc cv 29 → 32 → 28), its outer edge is 1m further onto the land. Mirrors MUD_BANK.
pub const MUD_BANK = [_]P{
    .{ .cu = -5, .cv = 29 }, .{ .cu = -15, .cv = 32 }, .{ .cu = -26, .cv = 28 }, // the water's far edge
    .{ .cu = -26, .cv = 29 }, .{ .cu = -15, .cv = 33 }, .{ .cu = -5, .cv = 30 }, // 1m back onto the land
};
pub const MUD: u32 = 0xc2b280;

// the seven crocs hauled out on the mud bank (the water's far edge + 0.5m), spread across the width, all
// facing the same way. Mirrors CROC_BANK in crocodile.ts.
pub const CROC_BANK = [_]P{
    .{ .cu = -5, .cv = 29.5 }, .{ .cu = -9, .cv = 30.7 }, .{ .cu = -12, .cv = 31.6 }, .{ .cu = -15, .cv = 32.5 },
    .{ .cu = -19, .cv = 31.1 }, .{ .cu = -22, .cv = 30 }, .{ .cu = -26, .cv = 28.5 },
};
pub const CROC_CP: u32 = 0x1F40A; // 🐊
pub const CROC_HEIGHT: f32 = 2.8; // metres (no giant upsizing — omitted)
pub const CROC_FACE_RIGHT: bool = true; // all seven face the same way
