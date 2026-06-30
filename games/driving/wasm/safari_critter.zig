//! safari_critter — the big animals parked AT a corner: an ADULT standing just past the far (outer) edge as
//! if it had crossed, facing into the turn, and its BABY ahead in the rider's path beyond the turn. Emoji
//! billboards, one shared placement rule, only the per-species dimensions differ. Faithful port of
//! safari_critter.ts's cornerCritters — MINUS the late-route giant upsizing (Steve: never effective). The
//! adult/baby sizing IS kept. The POND is the exception: a hand-drawn scene (pond.zig — water + bank +
//! ducks), not an emoji pair, so it returns no pair here and render.zig draws the pond separately.

const world = @import("world.zig");

const Species = struct { cp: u32, adult_h: f32 };
const ADULT_RAIL_BUFFER: f32 = 1.5; // the adult stands this much further off than half its width, clear of the rail
const BABY_RATIO: f32 = 0.5; // baby height as a fraction of the adult
const BABY_BEYOND: f32 = 14.0; // how far past the turn the baby stands, in the rider's path

// the emoji + adult height (m) per species. Mirrors SPECIES in safari_critter.ts (giants omitted).
fn species(c: world.Creature) ?Species {
    return switch (c) {
        .elephant => .{ .cp = 0x1F418, .adult_h = 2.8 }, // 🐘
        .giraffe => .{ .cp = 0x1F992, .adult_h = 4.5 }, // 🦒 — stands tallest
        .zebra => .{ .cp = 0x1F993, .adult_h = 1.6 }, // 🦓
        .rhino => .{ .cp = 0x1F98F, .adult_h = 2.2 }, // 🦏 — ~30% smaller; less sky-blend, sits against the mountains
        .pond => null, // hand-drawn duck-pond scene (pond.zig), not an emoji pair
        .none => null,
    };
}

// The two creatures at a segment's exit corner, in the FROM segment's frame (`along` = the segment end =
// the intersection; centre-relative across). The adult sits at the FAR corner — half its width plus the
// rail buffer beyond the outer edge — facing into the turn; the baby stands BEYOND the turn in the rider's
// path. Fills out[0..n], returns n (0 for `none`). Mirrors cornerCritters in safari_critter.ts.
pub fn cornerCritters(c: world.Creature, along: f32, turn_right: bool, hw: f32, out: *[2]world.Critter) usize {
    const sp = species(c) orelse return 0;
    const adult_h = sp.adult_h;
    const baby_h = adult_h * BABY_RATIO;
    const turn_sign: f32 = if (turn_right) 1.0 else -1.0;
    const face_right = turn_right; // face INTO the turn — eyes lead the rider around the bend
    out[0] = .{ // adult, at the far (outer) corner
        .along = along,
        .across = -turn_sign * (hw + ADULT_RAIL_BUFFER + adult_h / 2.0),
        .codepoint = sp.cp,
        .height = adult_h,
        .face_right = face_right,
    };
    out[1] = .{ // baby, ahead in the rider's path beyond the turn
        .along = along + BABY_BEYOND,
        .across = 0,
        .codepoint = sp.cp,
        .height = baby_h,
        .face_right = face_right,
    };
    return 2;
}
