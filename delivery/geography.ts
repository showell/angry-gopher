// geography.ts — the winking, not-to-scale Seattle road network.
//
// Pure data + helpers, no DOM. Everything lives in a fixed 1000x720 "logical"
// coordinate space; the view scales it to fit the window. A Seattleite should
// clock every beat in about three seconds; everyone else just sees two regions
// split by a lake, two bridges (one through an island), and neighborhoods wired
// together by roads — with the bridges as genuine edges in that network.
//
// Coordinate convention: x grows east (toward the Eastside), y grows south.

export type Pt = { x: number; y: number };

export type Side = "west" | "east" | "island";

/**
 * A neighborhood: a circular ring road with `houses` homes spaced around it.
 * Orders (the day's deliveries) are a subset of these houses. `lake` draws a
 * little pond at the center (Green Lake) that the ring wraps around.
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

/** The fleet + demand. 8 trucks * 10 totes = 80 orders (Bezos will be the limo extra). */
// Capacity is a true max, not a quota: demand (orders) sits below total capacity
// so the solver has slack — it can run trucks partial, or idle one entirely.
export const FLEET = { trucks: 8, totesPerTruck: 10, orders: 64 };

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
  { x: 516, y: 524 },
  { x: 534, y: 494 },
  { x: 566, y: 496 },
  { x: 584, y: 526 },
  { x: 572, y: 566 },
  { x: 538, y: 580 },
  { x: 514, y: 558 },
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
  { x: 432, y: 250 },
  { x: 486, y: 214 },
];

/** Union Bay — the little opening where the Montlake Cut meets Lake Washington. */
export const UNION_BAY: Pt[] = [
  { x: 484, y: 200 },
  { x: 512, y: 196 },
  { x: 540, y: 210 },
  { x: 544, y: 232 },
  { x: 516, y: 242 },
  { x: 488, y: 228 },
];

// ---------------------------------------------------------------------------
// Land: warehouse, neighborhoods, roads, bridges
// ---------------------------------------------------------------------------

/** The warehouse: Eastside, between the two bridges (Bellevue/Factoria-ish). */
export const WAREHOUSE: Pt = { x: 802, y: 396 };

/**
 * A bridge: a chain of artery `nodes` it stitches together, with `waters` giving
 * the mid-lake waypoints between consecutive nodes. The deck (built by
 * `bridgeDeck`) runs gate-to-gate just like a surface road, so the two sides of
 * the lake are genuinely connected — Mercer Island included, since it's a node
 * on I-90 (you enter it from Beacon Hill and exit toward Factoria).
 */
export type Bridge = {
  name: string;
  nodes: string[];
  waters: Pt[][]; // waters[i] = waypoints between nodes[i] and nodes[i+1]
};

export const NEIGHBORHOODS: Neighborhood[] = [
  // --- Westside (Seattle) — the city, heavier traffic ---
  { name: "Ballard", center: { x: 250, y: 120 }, side: "west", ringRadius: 32, houses: 12 },
  { name: "Green Lake", center: { x: 420, y: 96 }, side: "west", ringRadius: 34, houses: 12, lake: 16 },
  { name: "Fremont", center: { x: 340, y: 212 }, side: "west", ringRadius: 30, houses: 12, note: "Center of the Universe" },
  { name: "U-District", center: { x: 478, y: 158 }, side: "west", ringRadius: 30, houses: 12 },
  { name: "Queen Anne", center: { x: 252, y: 318 }, side: "west", ringRadius: 32, houses: 12 },
  { name: "Capitol Hill", center: { x: 432, y: 330 }, side: "west", ringRadius: 32, houses: 12 },
  { name: "Downtown", center: { x: 300, y: 430 }, side: "west", ringRadius: 30, houses: 12 },
  { name: "Beacon Hill", center: { x: 432, y: 470 }, side: "west", ringRadius: 30, houses: 12 },
  { name: "West Seattle", center: { x: 200, y: 600 }, side: "west", ringRadius: 30, houses: 12 },
  // --- Mercer Island (mid-I-90) ---
  { name: "Mercer Island", center: { x: 548, y: 530 }, side: "island", ringRadius: 26, houses: 12, note: "the Rock" },
  // --- Eastside — tech money, more room ---
  { name: "Medina", center: { x: 628, y: 140 }, side: "east", ringRadius: 28, houses: 12, note: "you-know-who lives here" },
  { name: "Kirkland", center: { x: 700, y: 212 }, side: "east", ringRadius: 30, houses: 12 },
  { name: "Redmond", center: { x: 868, y: 200 }, side: "east", ringRadius: 32, houses: 12 },
  { name: "Bellevue", center: { x: 740, y: 330 }, side: "east", ringRadius: 34, houses: 12 },
  { name: "Factoria", center: { x: 672, y: 568 }, side: "east", ringRadius: 30, houses: 12 },
  { name: "Issaquah", center: { x: 858, y: 612 }, side: "east", ringRadius: 30, houses: 12 },
];

/** Surface roads between nodes ("FC" = warehouse). Bridges (below) add the crossings. */
export const ROADS: Road[] = [
  // Westside arterials
  ["Ballard", "Green Lake"],
  ["Ballard", "Fremont"],
  ["Green Lake", "Fremont"],
  ["Green Lake", "U-District"],
  ["Fremont", "U-District"],
  ["Fremont", "Queen Anne"],
  ["Queen Anne", "Downtown"],
  ["Downtown", "Capitol Hill"],
  ["Capitol Hill", "U-District"],
  ["Capitol Hill", "Beacon Hill"],
  ["Downtown", "Beacon Hill"],
  ["Downtown", "West Seattle"],
  ["Beacon Hill", "West Seattle"],
  // Eastside arterials
  ["Medina", "Kirkland"],
  ["Kirkland", "Redmond"],
  ["Kirkland", "Bellevue"],
  ["Bellevue", "Redmond"],
  ["Bellevue", "Factoria"],
  ["Bellevue", "FC"],
  ["FC", "Factoria"],
  ["Factoria", "Issaquah"],
  ["Issaquah", "Redmond"], // the far-east "fast" bypass (I-405 / Sammamish)
];

export const BRIDGES: Bridge[] = [
  {
    // North crossing: Montlake (U-District) -> Medina.
    name: "SR 520",
    nodes: ["U-District", "Medina"],
    waters: [[{ x: 554, y: 148 }]],
  },
  {
    // South crossing: Beacon Hill -> Mercer Island -> Factoria.
    name: "I-90",
    nodes: ["Beacon Hill", "Mercer Island", "Factoria"],
    waters: [[{ x: 492, y: 501 }], [{ x: 608, y: 549 }]],
  },
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

/** The house positions evenly spaced around a neighborhood's ring road. */
export function housesOf(n: Neighborhood): Pt[] {
  const phase = namePhase(n.name);
  const pts: Pt[] = [];
  for (let i = 0; i < n.houses; i++) {
    const a = phase + (i / n.houses) * Math.PI * 2;
    pts.push({ x: n.center.x + Math.cos(a) * n.ringRadius, y: n.center.y + Math.sin(a) * n.ringRadius });
  }
  return pts;
}

/** Resolve a road endpoint name to a neighborhood (or null for "FC"/the warehouse). */
function neighborhood(name: string): Neighborhood | null {
  if (name === "FC") return null;
  const n = NEIGHBORHOODS.find((m) => m.name === name);
  if (!n) throw new Error(`unknown road node: ${name}`);
  return n;
}

/** Resolve a road endpoint name to a point (neighborhood center, or the warehouse). */
export function nodeAt(name: string): Pt {
  return neighborhood(name)?.center ?? WAREHOUSE;
}

/**
 * The gate where an artery meets a neighborhood: the point on the ring road
 * facing `toward`. Arteries connect gate-to-gate, so each neighborhood is a
 * cul-de-sac you enter/exit — the road never crosses the ring's interior.
 */
export function gateOf(name: string, toward: Pt): Pt {
  const n = neighborhood(name);
  if (!n) return WAREHOUSE; // the FC is a plain point, no ring
  const a = Math.atan2(toward.y - n.center.y, toward.x - n.center.x);
  return { x: n.center.x + Math.cos(a) * n.ringRadius, y: n.center.y + Math.sin(a) * n.ringRadius };
}

/** The two gate endpoints of a surface road [a, b], each on its own ring. */
export function roadGates(road: Road): [Pt, Pt] {
  const [a, b] = road;
  return [gateOf(a, nodeAt(b)), gateOf(b, nodeAt(a))];
}

/** Each bridge segment: the graph edge it carries and its deck (gate -> waters -> gate). */
export function bridgeSegments(b: Bridge): { edge: Road; pts: Pt[] }[] {
  const segs: { edge: Road; pts: Pt[] }[] = [];
  for (let i = 0; i < b.nodes.length - 1; i++) {
    const a = b.nodes[i];
    const c = b.nodes[i + 1];
    const pts: Pt[] = [gateOf(a, nodeAt(c)), ...(b.waters[i] ?? []), gateOf(c, nodeAt(a))];
    segs.push({ edge: [a, c], pts });
  }
  return segs;
}

/** The full drawn polyline of a bridge: each segment's deck, end to end. */
export function bridgeDeck(b: Bridge): Pt[] {
  return bridgeSegments(b).flatMap((s) => s.pts);
}

/** The graph edges a bridge carries (consecutive node pairs). */
export function bridgeEdges(b: Bridge): Road[] {
  return bridgeSegments(b).map((s) => s.edge);
}

/** All gate points across every surface road and bridge — little entrance markers. */
export function allGates(): Pt[] {
  const gates: Pt[] = [];
  for (const r of ROADS) {
    const [g1, g2] = roadGates(r);
    gates.push(g1, g2);
  }
  for (const b of BRIDGES) {
    for (const e of bridgeEdges(b)) {
      gates.push(gateOf(e[0], nodeAt(e[1])), gateOf(e[1], nodeAt(e[0])));
    }
  }
  return gates;
}

/**
 * The drawn polyline of the single graph edge between adjacent nodes `a` and
 * `b`, oriented a -> b. Mirrors the geometry the map renders: a surface road is
 * gate-to-gate; a bridge segment follows its deck (gate -> waters -> gate). A
 * route's full path is these stitched together. Throws if a and b aren't a real
 * edge — the caller has an off-graph hop.
 */
export function edgePolyline(a: string, b: string): Pt[] {
  for (const r of ROADS) {
    if (r[0] === a && r[1] === b) return roadGates(r);
    if (r[0] === b && r[1] === a) { const [g1, g2] = roadGates(r); return [g2, g1]; }
  }
  for (const br of BRIDGES) {
    for (const seg of bridgeSegments(br)) {
      const [x, y] = seg.edge;
      if (x === a && y === b) return seg.pts;
      if (x === b && y === a) return [...seg.pts].reverse();
    }
  }
  throw new Error(`no edge between adjacent nodes: ${a} -> ${b}`);
}
