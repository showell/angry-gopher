// geography.ts — the winking, not-to-scale Seattle road network.
//
// Pure data + types, no DOM. Everything lives in a fixed 1000x720 "logical"
// coordinate space; the view scales it to fit the window. A Seattleite should
// clock every beat in about three seconds; everyone else just sees two regions
// split by a lake, with two bridges across it (one through an island).
//
// Coordinate convention: x grows east (toward the Eastside), y grows south.
// The lake runs roughly north-south down the middle.

export type Pt = { x: number; y: number };

export type Side = "west" | "east" | "island";

/** A named place — a neighborhood marker. Customers will later cluster near these. */
export type Place = {
  name: string;
  at: Pt;
  side: Side;
  /** Optional one-line wink shown under the name. */
  note?: string;
};

/** A lake crossing. `spans` are the polyline points the deck follows. */
export type Bridge = {
  name: string;
  spans: Pt[];
  /** Where to anchor the bridge label. */
  label: Pt;
  note?: string;
};

export const MAP_W = 1000;
export const MAP_H = 720;

/** West (Seattle) shoreline, north to south. */
export const WEST_SHORE: Pt[] = [
  { x: 432, y: 0 },
  { x: 414, y: 110 },
  { x: 442, y: 230 },
  { x: 408, y: 350 },
  { x: 436, y: 470 },
  { x: 418, y: 590 },
  { x: 440, y: 720 },
];

/** East (Eastside) shoreline, north to south. */
export const EAST_SHORE: Pt[] = [
  { x: 560, y: 0 },
  { x: 576, y: 130 },
  { x: 552, y: 260 },
  { x: 586, y: 380 },
  { x: 558, y: 500 },
  { x: 582, y: 620 },
  { x: 564, y: 720 },
];

/** Mercer Island — "the Rock" — sitting in the lake's lower middle. I-90 crosses it. */
export const MERCER_ISLAND: Pt[] = [
  { x: 474, y: 520 },
  { x: 494, y: 486 },
  { x: 528, y: 488 },
  { x: 548, y: 520 },
  { x: 538, y: 562 },
  { x: 502, y: 576 },
  { x: 476, y: 556 },
];

/** The warehouse: Eastside, between the two bridges (Bellevue/Factoria-ish). */
export const WAREHOUSE: Pt = { x: 722, y: 352 };

export const BRIDGES: Bridge[] = [
  {
    // North crossing: a straight shot Medina/Bellevue -> Montlake/UW. Tolled (a wink).
    name: "SR 520",
    spans: [
      { x: 576, y: 158 },
      { x: 420, y: 176 },
    ],
    label: { x: 498, y: 150 },
    note: "$ toll",
  },
  {
    // South crossing: dives through Mercer Island on its way into SoDo.
    name: "I-90",
    spans: [
      { x: 596, y: 528 }, // Eastside shore
      { x: 548, y: 522 }, // onto the island
      { x: 476, y: 524 }, // off the island
      { x: 410, y: 520 }, // Westside shore (SoDo)
    ],
    label: { x: 430, y: 552 },
    note: "via Mercer Is.",
  },
];

export const PLACES: Place[] = [
  // --- Westside (Seattle) — the city, heavier traffic ---
  { name: "Ballard", at: { x: 344, y: 120 }, side: "west" },
  { name: "Fremont", at: { x: 372, y: 206 }, side: "west", note: "Center of the Universe" },
  { name: "U-District", at: { x: 402, y: 158 }, side: "west" },
  { name: "Queen Anne", at: { x: 312, y: 268 }, side: "west" },
  { name: "Capitol Hill", at: { x: 378, y: 300 }, side: "west" },
  { name: "Downtown", at: { x: 338, y: 408 }, side: "west" },
  { name: "SoDo", at: { x: 360, y: 470 }, side: "west" },
  { name: "West Seattle", at: { x: 250, y: 540 }, side: "west" },
  // --- Mercer Island (mid-I-90) ---
  { name: "Mercer Island", at: { x: 510, y: 528 }, side: "island", note: "the Rock" },
  // --- Eastside — tech money, more room ---
  { name: "Medina", at: { x: 612, y: 132 }, side: "east", note: "you-know-who lives here" },
  { name: "Kirkland", at: { x: 648, y: 196 }, side: "east" },
  { name: "Bellevue", at: { x: 700, y: 300 }, side: "east" },
  { name: "Redmond", at: { x: 838, y: 214 }, side: "east" },
  { name: "Factoria", at: { x: 706, y: 432 }, side: "east" },
  { name: "Issaquah", at: { x: 872, y: 486 }, side: "east" },
];

/** The Westside traffic blob — slows everything near downtown/SLU. */
export const MERCER_MESS = { center: { x: 352, y: 392 }, radius: 150 };
