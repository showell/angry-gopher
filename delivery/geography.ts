// geography.ts — the winking, not-to-scale Seattle road network.
//
// Pure data + helpers, no DOM. Everything lives in a fixed 1000x720 "logical"
// coordinate space; the view scales it to fit the window. A Seattleite should
// clock every beat in about three seconds; everyone else just sees two regions
// split by a lake, two bridges (one through an island), and a tangle of
// neighborhoods wired together by roads.
//
// Coordinate convention: x grows east (toward the Eastside), y grows south.

export type Pt = { x: number; y: number };

export type Side = "west" | "east" | "island";

/**
 * A neighborhood: a circular ring road with `houses` homes spaced around it.
 * Customers (later) are a subset of these houses. `lake` draws a little pond at
 * the center (Green Lake) that the ring wraps around.
 */
export type Neighborhood = {
  name: string;
  center: Pt;
  side: Side;
  ringRadius: number;
  houses: number;
  note?: string;
  lake?: number;
};

/** A road between two named nodes (neighborhood names, or "FC" for the warehouse). */
export type Road = [string, string];

export const MAP_W = 1000;
export const MAP_H = 720;

// ---------------------------------------------------------------------------
// Water
// ---------------------------------------------------------------------------

/** Lake Washington — west (Seattle) shoreline, north to south. */
export const WEST_SHORE: Pt[] = [
  { x: 488, y: 0 },
  { x: 470, y: 110 },
  { x: 498, y: 230 },
  { x: 466, y: 350 },
  { x: 492, y: 470 },
  { x: 474, y: 590 },
  { x: 496, y: 720 },
];

/** Lake Washington — east (Eastside) shoreline, north to south. */
export const EAST_SHORE: Pt[] = [
  { x: 590, y: 0 },
  { x: 606, y: 130 },
  { x: 582, y: 260 },
  { x: 616, y: 380 },
  { x: 588, y: 500 },
  { x: 612, y: 620 },
  { x: 594, y: 720 },
];

/** Mercer Island — "the Rock" — sitting in the lake's lower middle. I-90 crosses it. */
export const MERCER_ISLAND: Pt[] = [
  { x: 506, y: 522 },
  { x: 524, y: 490 },
  { x: 556, y: 492 },
  { x: 574, y: 522 },
  { x: 562, y: 562 },
  { x: 528, y: 576 },
  { x: 504, y: 556 },
];

/** Puget Sound / Elliott Bay — water down the far-west margin, bulging in near downtown. */
export const PUGET_SOUND: Pt[] = [
  { x: 0, y: 0 },
  { x: 118, y: 0 },
  { x: 100, y: 140 },
  { x: 138, y: 225 },
  { x: 116, y: 330 },
  { x: 158, y: 405 },
  { x: 250, y: 445 }, // Elliott Bay reaches in toward downtown
  { x: 238, y: 505 },
  { x: 150, y: 520 },
  { x: 182, y: 600 },
  { x: 138, y: 690 },
  { x: 0, y: 720 },
];

/** Lake Union — a teardrop in central Seattle, south of Fremont, between QA and Cap Hill. */
export const LAKE_UNION: Pt[] = [
  { x: 338, y: 292 },
  { x: 376, y: 286 },
  { x: 394, y: 322 },
  { x: 376, y: 360 },
  { x: 342, y: 366 },
  { x: 324, y: 330 },
];

/**
 * The ship canal, in two reaches that Lake Union sits between:
 *  - west: Lake Union out to Puget Sound (the Fremont/Ballard cut), south of
 *    Ballard & Fremont, north of Queen Anne — "out to Elliott Bay & the Sound."
 *  - east: the Montlake Cut, Lake Union to Lake Washington by the U-District.
 */
export const CANAL_WEST: Pt[] = [
  { x: 135, y: 232 },
  { x: 215, y: 240 },
  { x: 300, y: 250 },
  { x: 340, y: 296 },
];
export const CANAL_EAST: Pt[] = [
  { x: 378, y: 296 },
  { x: 422, y: 252 },
  { x: 470, y: 222 },
];

// ---------------------------------------------------------------------------
// Land
// ---------------------------------------------------------------------------

/** The warehouse: Eastside, between the two bridges (Bellevue/Factoria-ish). */
export const WAREHOUSE: Pt = { x: 786, y: 374 };

export type Bridge = {
  name: string;
  spans: Pt[];
  label: Pt;
  note?: string;
};

export const BRIDGES: Bridge[] = [
  {
    // North crossing: a straight shot Medina/Bellevue -> Montlake/UW. Tolled (a wink).
    name: "SR 520",
    spans: [
      { x: 600, y: 168 },
      { x: 472, y: 196 },
    ],
    label: { x: 536, y: 162 },
    note: "$ toll",
  },
  {
    // South crossing: dives through Mercer Island on its way into SoDo.
    name: "I-90",
    spans: [
      { x: 624, y: 528 }, // Eastside shore (toward Factoria)
      { x: 574, y: 522 }, // onto the island
      { x: 506, y: 524 }, // off the island
      { x: 462, y: 522 }, // Westside shore (SoDo / Cap Hill)
    ],
    label: { x: 470, y: 552 },
    note: "via Mercer Is.",
  },
];

export const NEIGHBORHOODS: Neighborhood[] = [
  // --- Westside (Seattle) — the city, heavier traffic ---
  { name: "Ballard", center: { x: 300, y: 112 }, side: "west", ringRadius: 30, houses: 10 },
  { name: "Green Lake", center: { x: 404, y: 118 }, side: "west", ringRadius: 33, houses: 10, lake: 16 },
  { name: "Fremont", center: { x: 372, y: 214 }, side: "west", ringRadius: 28, houses: 10, note: "Center of the Universe" },
  { name: "U-District", center: { x: 446, y: 168 }, side: "west", ringRadius: 28, houses: 10 },
  { name: "Queen Anne", center: { x: 266, y: 300 }, side: "west", ringRadius: 30, houses: 10 },
  { name: "Capitol Hill", center: { x: 408, y: 332 }, side: "west", ringRadius: 30, houses: 10 },
  { name: "West Seattle", center: { x: 206, y: 588 }, side: "west", ringRadius: 30, houses: 10 },
  // --- Mercer Island (mid-I-90) ---
  { name: "Mercer Island", center: { x: 538, y: 528 }, side: "island", ringRadius: 24, houses: 10, note: "the Rock" },
  // --- Eastside — tech money, more room ---
  { name: "Medina", center: { x: 622, y: 138 }, side: "east", ringRadius: 26, houses: 10, note: "you-know-who lives here" },
  { name: "Kirkland", center: { x: 686, y: 214 }, side: "east", ringRadius: 28, houses: 10 },
  { name: "Redmond", center: { x: 858, y: 206 }, side: "east", ringRadius: 30, houses: 10 },
  { name: "Bellevue", center: { x: 712, y: 326 }, side: "east", ringRadius: 30, houses: 10 },
  { name: "Factoria", center: { x: 660, y: 566 }, side: "east", ringRadius: 28, houses: 10 },
  { name: "Issaquah", center: { x: 844, y: 606 }, side: "east", ringRadius: 28, houses: 10 },
];

/** Roads between nodes ("FC" = the warehouse). Bridges (above) carry the crossings. */
export const ROADS: Road[] = [
  // Westside arterials
  ["Ballard", "Green Lake"],
  ["Ballard", "Fremont"],
  ["Green Lake", "Fremont"],
  ["Green Lake", "U-District"],
  ["Fremont", "U-District"],
  ["Fremont", "Queen Anne"],
  ["Queen Anne", "Capitol Hill"],
  ["Capitol Hill", "U-District"],
  ["Queen Anne", "West Seattle"],
  ["Capitol Hill", "West Seattle"],
  // Eastside arterials
  ["Medina", "Kirkland"],
  ["Medina", "Bellevue"],
  ["Kirkland", "Redmond"],
  ["Kirkland", "Bellevue"],
  ["Bellevue", "Redmond"],
  ["Bellevue", "Factoria"],
  ["Factoria", "Issaquah"],
  ["Bellevue", "FC"],
  ["FC", "Medina"],
  ["FC", "Factoria"],
];

/** The Westside traffic blob — slows everything near downtown/SLU. */
export const MERCER_MESS = { center: { x: 352, y: 408 }, radius: 150 };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Deterministic per-name phase in [0, 2π), so neighborhood rings don't all align. */
function namePhase(name: string): number {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return (h % 360) * (Math.PI / 180);
}

/** The 10 house positions evenly spaced around a neighborhood's ring road. */
export function housesOf(n: Neighborhood): Pt[] {
  const phase = namePhase(n.name);
  const pts: Pt[] = [];
  for (let i = 0; i < n.houses; i++) {
    const a = phase + (i / n.houses) * Math.PI * 2;
    pts.push({ x: n.center.x + Math.cos(a) * n.ringRadius, y: n.center.y + Math.sin(a) * n.ringRadius });
  }
  return pts;
}

/** Resolve a road endpoint name to a point (neighborhood center, or the warehouse). */
export function nodeAt(name: string): Pt {
  if (name === "FC") return WAREHOUSE;
  const n = NEIGHBORHOODS.find((m) => m.name === name);
  if (!n) throw new Error(`unknown road node: ${name}`);
  return n.center;
}
