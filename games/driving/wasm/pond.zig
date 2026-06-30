//! pond — a small pond at a corner (seg13), just BEYOND a right-turn intersection, off to its LEFT, with
//! three ducks floating on the water. This WAS the crocodile lagoon (crocodile.ts): the crocs read wrong in
//! our billboard paradigm — a basking crocodile is low and horizontal, but our billboards are upright,
//! camera-facing, side-view sprites, so the crocs stood on their tails next to a top-down water patch.
//! Ducks float UPRIGHT, so the paradigm fits. The water + bank geometry is unchanged from the lagoon.
//!
//! Frame: cv = metres BEYOND the incoming segment's end edge (the rider's forward as he arrives), cu =
//! metres across from its end-left corner (0 = left edge, + = toward the road; the pond's cu is NEGATIVE,
//! out to the left — the outer side of the right turn). render.zig maps corner(cu, cv) = at(from_len+cv, cu).
//!
//! Pure data + dimensions; the mapping/projection/emit lives in render.zig, the same split safari_critter
//! uses. The late-route giant upsizing (crocodile.ts's CROC_GIANT_SCALE) was never ported (Steve: never
//! effective).

pub const P = struct { cu: f32, cv: f32 };

// the pond outline, corner-frame metres: a big blob off the LEFT of the road, ~30m across (cu -1 → -31) and
// reaching ~30m beyond the intersection (cv 3 → 32). Its near edge (the flat front at cv 3) faces the
// incoming road. Mirrors LAGOON in crocodile.ts.
pub const WATER_OUTLINE = [_]P{
    .{ .cu = -2, .cv = 3 },   .{ .cu = -28, .cv = 3 }, .{ .cu = -31, .cv = 14 }, .{ .cu = -26, .cv = 28 },
    .{ .cu = -15, .cv = 32 }, .{ .cu = -5, .cv = 29 }, .{ .cu = -1, .cv = 16 },
};
pub const WATER: u32 = 0x2f7e8c;

// a 1m khaki bank along the water's FAR edge — the shore. Its inner edge hugs the water's far edge (the arc
// cv 29 → 32 → 28), its outer edge is 1m further onto the land. Mirrors MUD_BANK in crocodile.ts.
pub const BANK = [_]P{
    .{ .cu = -5, .cv = 29 }, .{ .cu = -15, .cv = 32 }, .{ .cu = -26, .cv = 28 }, // the water's far edge
    .{ .cu = -26, .cv = 29 }, .{ .cu = -15, .cv = 33 }, .{ .cu = -5, .cv = 30 }, // 1m back onto the land
};
pub const BANK_COLOR: u32 = 0xc2b280;

// six ducks floating on the water, spread across the pond — three deeper in (larger cv) and three nearer the
// intersection (smaller cv, toward the front edge at cv 3). ADULTS, drawn slightly out of proportion so they
// read. Ducks float upright, so the billboard paradigm fits (unlike the basking crocs it replaced).
pub const DUCK_CP: u32 = 0x1F986; // 🦆
pub const DUCK_HEIGHT: f32 = 0.9; // m
pub const Duck = struct { p: P, face_right: bool };
// cu is shifted toward the road (less negative) vs the pond centre — the ducks hug the near/road side of the
// water while still sitting inside the outline.
pub const DUCKS = [_]Duck{
    .{ .p = .{ .cu = -8, .cv = 11 }, .face_right = true }, // deeper trio
    .{ .p = .{ .cu = -16, .cv = 17 }, .face_right = false },
    .{ .p = .{ .cu = -9, .cv = 21 }, .face_right = true },
    .{ .p = .{ .cu = -4, .cv = 6 }, .face_right = true }, // nearer trio (closer to the intersection)
    .{ .p = .{ .cu = -12, .cv = 7 }, .face_right = false },
    .{ .p = .{ .cu = -20, .cv = 8 }, .face_right = true },
};
