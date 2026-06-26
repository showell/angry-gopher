// map_view.ts — draws the static Seattle network onto a 2D canvas, in logical
// (1000x720) coordinates. The backdrop everything else (routes, the manager's
// overrides) will later draw on top of. Arteries connect to neighborhoods at
// gates (cul-de-sac entrances); names are hover-reveal to stay uncluttered.

import type { Pt, Neighborhood } from "./geography.ts";
import {
  MAP_W,
  MAP_H,
  FLEET,
  WEST_SHORE,
  EAST_SHORE,
  MERCER_ISLAND,
  PUGET_SOUND,
  LAKE_UNION,
  CANAL_WEST,
  CANAL_EAST,
  UNION_BAY,
  WAREHOUSE,
  BRIDGES,
  NEIGHBORHOODS,
  ROADS,
  MERCER_MESS,
  housesOf,
  roadGates,
  bridgeDeck,
  allGates,
  edgePolyline,
  ringWalkPath,
  gateAngle,
  houseAngles,
  nodeAt,
} from "./geography.ts";
import { buildSubstrate } from "./roadgraph.ts";
import type { Plan, Route } from "./solver.ts";
import { buildItinerary } from "./timeline.ts";
import type { Itinerary, Leg } from "./timeline.ts";

// The routing substrate is static, so build the travel-time matrix once.
const SUB = buildSubstrate();

const HOME_COUNT = NEIGHBORHOODS.reduce((s, n) => s + n.houses, 0);

// One colour per truck — eight hues spread ~45° around the wheel, all dark
// enough to read over the pale land and far enough apart to tell apart.
const TRUCK_COLORS = [
  "#1c6fd6", // blue
  "#e8590c", // orange
  "#2f9e44", // green
  "#d6336c", // magenta
  "#1098ad", // teal
  "#7048e8", // violet
  "#b8860b", // dark gold
  "#343a40", // charcoal
];

// House marker sizes (squares), orders 10% larger than the base homes were.
const ORDER_SIZE = 9.9;
const HOME_SIZE = 6.6;

// Truck-panel layout (top-right), shared by the renderer and the hit-test.
const PANEL_X = MAP_W - 250;
const PANEL_W = 240;
const PANEL_ROW0 = 65; // text baseline of the first truck row
const PANEL_ROW_H = 18;

const COLOR = {
  westLand: "#e7e3ea",
  eastLand: "#e7eede",
  water: "#9fcfe6",
  waterEdge: "#6fb2d2",
  island: "#eef3df",
  bridge: "#5b6470",
  bridgeStripe: "#d9b34a",
  traffic: "rgba(206, 64, 52, 0.14)",
  road: "#cfc7bb",
  roadCasing: "#b3aa9c",
  gate: "#7d7464",
  ring: "#a89f90",
  ringHot: "#2a2e34",
  home: "#cdc6b8",
  homeEdge: "#a9a094",
  order: "#e8732e",
  depot: "#c0392b",
  text: "#2a2e34",
  note: "#7b8088",
  faint: "#b9b3bf",
};

function trace(ctx: CanvasRenderingContext2D, pts: Pt[], close: boolean): void {
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
  if (close) ctx.closePath();
}

function fillPoly(ctx: CanvasRenderingContext2D, pts: Pt[], fill: string, edge?: string): void {
  trace(ctx, pts, true);
  ctx.fillStyle = fill;
  ctx.fill();
  if (edge) {
    ctx.lineWidth = 2;
    ctx.strokeStyle = edge;
    ctx.stroke();
  }
}

function drawLand(ctx: CanvasRenderingContext2D): void {
  ctx.fillStyle = COLOR.westLand;
  ctx.fillRect(0, 0, MAP_W, MAP_H);
  ctx.fillStyle = COLOR.eastLand;
  ctx.fillRect(540, 0, MAP_W - 540, MAP_H);
}

function lakeWashington(ctx: CanvasRenderingContext2D): void {
  ctx.beginPath();
  ctx.moveTo(WEST_SHORE[0].x, WEST_SHORE[0].y);
  for (const p of WEST_SHORE) ctx.lineTo(p.x, p.y);
  for (let i = EAST_SHORE.length - 1; i >= 0; i--) ctx.lineTo(EAST_SHORE[i].x, EAST_SHORE[i].y);
  ctx.closePath();
  ctx.fillStyle = COLOR.water;
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.strokeStyle = COLOR.waterEdge;
  ctx.stroke();
}

function channel(ctx: CanvasRenderingContext2D, pts: Pt[]): void {
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  trace(ctx, pts, false);
  ctx.lineWidth = 14;
  ctx.strokeStyle = COLOR.waterEdge;
  ctx.stroke();
  trace(ctx, pts, false);
  ctx.lineWidth = 10;
  ctx.strokeStyle = COLOR.water;
  ctx.stroke();
}

function drawWater(ctx: CanvasRenderingContext2D): void {
  lakeWashington(ctx);
  fillPoly(ctx, PUGET_SOUND, COLOR.water, COLOR.waterEdge);
  channel(ctx, CANAL_WEST);
  channel(ctx, CANAL_EAST);
  fillPoly(ctx, UNION_BAY, COLOR.water, COLOR.waterEdge);
  fillPoly(ctx, LAKE_UNION, COLOR.water, COLOR.waterEdge);
  fillPoly(ctx, MERCER_ISLAND, COLOR.island, COLOR.waterEdge);
}

function drawTraffic(ctx: CanvasRenderingContext2D): void {
  const { center, radius } = MERCER_MESS;
  const g = ctx.createRadialGradient(center.x, center.y, 10, center.x, center.y, radius);
  g.addColorStop(0, COLOR.traffic);
  g.addColorStop(1, "rgba(206, 64, 52, 0)");
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(center.x, center.y, radius, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "rgba(150, 40, 32, 0.7)";
  ctx.font = "italic 13px system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText("the Mercer Mess", center.x, center.y - 60);
}

function stroke(ctx: CanvasRenderingContext2D, pts: Pt[], width: number, color: string): void {
  trace(ctx, pts, false);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.lineWidth = width;
  ctx.strokeStyle = color;
  ctx.stroke();
}

function drawRoads(ctx: CanvasRenderingContext2D): void {
  for (const r of ROADS) {
    const gates = roadGates(r);
    stroke(ctx, gates, 6, COLOR.roadCasing);
    stroke(ctx, gates, 3.5, COLOR.road);
  }
}

function drawBridges(ctx: CanvasRenderingContext2D): void {
  for (const b of BRIDGES) {
    const deck = bridgeDeck(b);
    stroke(ctx, deck, 9, COLOR.bridge);
    trace(ctx, deck, false);
    ctx.lineWidth = 2;
    ctx.setLineDash([8, 7]);
    ctx.strokeStyle = COLOR.bridgeStripe;
    ctx.stroke();
    ctx.setLineDash([]);
  }
}

function drawGates(ctx: CanvasRenderingContext2D): void {
  ctx.fillStyle = COLOR.gate;
  for (const g of allGates()) {
    ctx.beginPath();
    ctx.arc(g.x, g.y, 2.4, 0, Math.PI * 2);
    ctx.fill();
  }
}

function drawNeighborhood(
  ctx: CanvasRenderingContext2D,
  n: Neighborhood,
  orders: Set<string>,
  houseColor: Map<string, string>, // per-house truck colour (so a split shows two colours)
  highlight: Set<string> | null, // houses of the focused truck, to make pop
  delivered: Set<string> | null, // houses already serviced (playback) → checkmark
): void {
  if (n.lake) {
    ctx.beginPath();
    ctx.arc(n.center.x, n.center.y, n.lake, 0, Math.PI * 2);
    ctx.fillStyle = COLOR.water;
    ctx.fill();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = COLOR.waterEdge;
    ctx.stroke();
  }

  // Ring road — kept neutral even on hover, so it never fights the routes.
  ctx.beginPath();
  ctx.arc(n.center.x, n.center.y, n.ringRadius, 0, Math.PI * 2);
  ctx.lineWidth = 3;
  ctx.strokeStyle = COLOR.ring;
  ctx.stroke();

  // Houses — orders take their truck's colour and pop, plain homes recede.
  // When a truck is focused, its stops stay vivid and bigger while every other
  // truck's orders fade right back, so the route's doors read at a glance.
  const focusMode = highlight !== null;
  housesOf(n).forEach((h, i) => {
    const key = `${n.name}#${i}`;
    const isOrder = orders.has(key);
    if (isOrder) {
      const focused = focusMode && highlight.has(key);
      const muted = focusMode && !focused;
      const color = houseColor.get(key) ?? COLOR.order;
      // Delivered (during playback): the square becomes a checkmark in the
      // truck's colour — the moment the goods hit the doorstep.
      if (delivered && delivered.has(key)) {
        drawCheck(ctx, h.x, h.y, ORDER_SIZE * 1.5, color);
        return;
      }
      const s = focused ? 13 : ORDER_SIZE;
      ctx.globalAlpha = muted ? 0.5 : 1;
      ctx.fillStyle = color;
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = focused ? 2 : 1.5;
      ctx.beginPath();
      ctx.rect(h.x - s / 2, h.y - s / 2, s, s);
      ctx.fill();
      ctx.stroke();
      ctx.globalAlpha = 1;
    } else {
      const s = HOME_SIZE;
      ctx.fillStyle = COLOR.home;
      ctx.strokeStyle = COLOR.homeEdge;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.rect(h.x - s / 2, h.y - s / 2, s, s);
      ctx.fill();
      ctx.stroke();
    }
  });
}

/**
 * The detail panel under the truck list (top-right). When a neighborhood is
 * hovered it leads with that neighborhood's facts; either way it then shows the
 * active truck's neighborhood-by-neighborhood breakdown (the hovered one in
 * bold). Off the map on purpose, so nothing floats over the routes.
 */
function drawDetail(ctx: CanvasRenderingContext2D, plan: Plan, orders: Set<string>, hoverNbhd: string | null, activeTruck: number | null): void {
  if (hoverNbhd === null && activeTruck === null) return;

  const x = PANEL_X;
  let y = PANEL_ROW0 + plan.routes.length * PANEL_ROW_H + (plan.unrouted.length ? 18 : 0) + 20;
  ctx.strokeStyle = "rgba(0, 0, 0, 0.12)";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x, y - 14);
  ctx.lineTo(x + PANEL_W, y - 14);
  ctx.stroke();
  ctx.textAlign = "left";

  // Lead with the hovered neighborhood's facts.
  const n = hoverNbhd ? NEIGHBORHOODS.find((m) => m.name === hoverNbhd) : undefined;
  if (n) {
    let count = 0;
    for (let i = 0; i < n.houses; i++) if (orders.has(`${n.name}#${i}`)) count++;
    ctx.fillStyle = COLOR.text;
    ctx.font = "bold 14px system-ui, sans-serif";
    ctx.fillText(n.name, x, y);
    y += 18;
    if (n.note) {
      ctx.fillStyle = COLOR.note;
      ctx.font = "italic 12px system-ui, sans-serif";
      ctx.fillText(n.note, x, y);
      y += 17;
    }
    ctx.fillStyle = COLOR.note;
    ctx.font = "12px system-ui, sans-serif";
    ctx.fillText(`${count} order${count === 1 ? "" : "s"}  ·  ≈${Math.round(SUB.time("FC", n.name))} min from FC`, x, y);
    y += 24;
  }

  // Then the active truck's whole route.
  if (activeTruck === null || !plan.routes[activeTruck]) return;
  const r = plan.routes[activeTruck];
  const color = TRUCK_COLORS[activeTruck % TRUCK_COLORS.length];
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 13px system-ui, sans-serif";
  ctx.fillText(`Truck ${activeTruck + 1} — ${r.orders} totes · ${Math.round(r.time)} min`, x, y);
  y += 19;
  r.stops.forEach((s, k) => {
    const here = s.nbhd === hoverNbhd;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(x + 4, y - 4, here ? 4.5 : 3.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = COLOR.text;
    ctx.font = `${here ? "bold " : ""}12px system-ui, sans-serif`;
    ctx.fillText(`${k + 1}. ${s.nbhd}`, x + 14, y);
    ctx.fillStyle = COLOR.note;
    ctx.textAlign = "right";
    ctx.fillText(`${s.orders} tote${s.orders === 1 ? "" : "s"}`, x + PANEL_W, y);
    ctx.textAlign = "left";
    y += 17;
  });
}

function drawWarehouse(ctx: CanvasRenderingContext2D): void {
  const { x, y } = WAREHOUSE;
  ctx.fillStyle = COLOR.depot;
  ctx.strokeStyle = "#7d241a";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.rect(x - 13, y - 8, 26, 18);
  ctx.fill();
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(x - 16, y - 8);
  ctx.lineTo(x, y - 20);
  ctx.lineTo(x + 16, y - 8);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();

  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 13px system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText("Warehouse", x, y + 26);
  ctx.fillStyle = COLOR.note;
  ctx.font = "italic 11px system-ui, sans-serif";
  ctx.fillText("AmazonFresh FC", x, y + 39);
}

function drawRegionLabels(ctx: CanvasRenderingContext2D): void {
  ctx.textAlign = "center";
  ctx.fillStyle = COLOR.faint;
  ctx.font = "bold 24px system-ui, sans-serif";
  ctx.fillText("SEATTLE", 168, 250);
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("the Westside", 168, 268);

  ctx.font = "bold 24px system-ui, sans-serif";
  ctx.fillText("THE EASTSIDE", 852, 474);
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("warehouse country", 852, 492);

  ctx.save();
  ctx.translate(545, 320);
  ctx.rotate(Math.PI / 2);
  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 16px system-ui, sans-serif";
  ctx.fillText("Lake Washington", 0, 0);
  ctx.restore();

  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 11px system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText("Lake Union", 358, 400);

  ctx.save();
  ctx.translate(48, 360);
  ctx.rotate(-Math.PI / 2);
  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 13px system-ui, sans-serif";
  ctx.fillText("Puget Sound", 0, 0);
  ctx.restore();
}

function swatch(ctx: CanvasRenderingContext2D, x: number, y: number, fill: string, edge: string, s: number, label: string): void {
  ctx.fillStyle = fill;
  ctx.strokeStyle = edge;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.rect(x, y - s / 2, s, s);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = COLOR.text;
  ctx.font = "12px system-ui, sans-serif";
  ctx.textAlign = "left";
  ctx.fillText(label, x + s + 6, y + 4);
}

function drawHud(ctx: CanvasRenderingContext2D): void {
  // Legend (top-left).
  swatch(ctx, 24, 30, COLOR.order, "#ffffff", ORDER_SIZE, "order today (tinted by truck)");
  swatch(ctx, 24, 52, COLOR.home, COLOR.homeEdge, HOME_SIZE, "home");

  // Title + problem statement (bottom-left).
  ctx.textAlign = "left";
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 18px system-ui, sans-serif";
  ctx.fillText("Seattle Delivery Network", 24, 668);
  ctx.fillStyle = COLOR.note;
  ctx.font = "13px system-ui, sans-serif";
  ctx.fillText(
    `${FLEET.orders} orders  ·  ${FLEET.trucks} trucks × ${FLEET.totesPerTruck} totes  ·  ${HOME_COUNT} homes`,
    24,
    688,
  );
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("totally not to scale  ·  hover a neighborhood or a truck  ·  Space run the day  ·  B back  ·  R reshuffle", 24, 706);
}

/**
 * The drawn polyline of a truck's whole tour, FC -> stops -> FC. It follows real
 * arteries and bridges (each leg is the substrate's shortest path, stitched edge
 * by edge), and at every neighborhood it threads onto the ring road: a full loop
 * of the cul-de-sac where the truck delivers, a short arc where it only passes
 * through. So the line stays on the roads the whole way and visibly drives
 * around to the houses.
 */
function routeGeometry(route: Route): Pt[] {
  const waypoints = ["FC", ...route.stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    const leg = SUB.path(waypoints[i - 1], waypoints[i]); // [a, ..., b]
    for (const node of leg) if (nodes[nodes.length - 1] !== node) nodes.push(node);
  }
  const housesAt = new Map<string, number[]>();
  for (const s of route.stops) housesAt.set(s.nbhd, (housesAt.get(s.nbhd) ?? []).concat(s.houses));

  const pts: Pt[] = [];
  for (let i = 1; i < nodes.length; i++) {
    const prev = nodes[i - 1];
    const node = nodes[i];
    pts.push(...edgePolyline(prev, node)); // the artery in, ending at node's entry gate
    if (node !== "FC" && i < nodes.length - 1) {
      const next = nodes[i + 1];
      const entry = gateAngle(node, nodeAt(prev));
      const exit = gateAngle(node, nodeAt(next));
      pts.push(...ringWalkPath(node, entry, exit, houseAngles(node, housesAt.get(node) ?? []))); // ring to exit gate
    }
  }
  return pts;
}

/**
 * The route layer (z=2), drawn on top of the map. With a truck active (hovered
 * directly, or via the neighborhood it serves) we show ONLY that truck's tour;
 * otherwise every truck's, lighter.
 */
function drawRoutes(ctx: CanvasRenderingContext2D, plan: Plan, activeTruck: number | null): void {
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  plan.routes.forEach((route, i) => {
    if (activeTruck !== null && i !== activeTruck) return; // single-route mode
    const pts = routeGeometry(route);
    if (pts.length < 2) return;
    const emphasised = activeTruck === i;
    trace(ctx, pts, false);
    ctx.globalAlpha = 0.8;
    ctx.lineWidth = emphasised ? 2.8 : 1.6;
    ctx.strokeStyle = TRUCK_COLORS[i % TRUCK_COLORS.length];
    ctx.stroke();
    ctx.globalAlpha = 1;
  });
}

// --- Animation: trucks as dots riding their routes (the "watch the day run"
// flipbook). It's a pure read-out of each truck's Itinerary (timeline.ts): the
// dot's position AND the doorstep checkmarks both come from the same ordered
// legs, so they can't drift. A single global clock drives every truck.
//
// Departures stagger because the warehouse can only load one truck at a time:
// the crew loads the hardest route first (LOAD_PER_TOTE per tote), and each
// truck waits at the dock until the trucks ahead of it in line are loaded. So a
// truck behind a big load waits longer — the fleet fans out on its own.

const LOAD_PER_TOTE = 0.5; // minutes the crew spends loading one tote

export type Track = {
  itin: Itinerary; // the canonical sequence of timed legs
  full: Pt[]; // the whole polyline, for the faint "road ahead" underlay
  deliveries: { key: string; t: number }[]; // local time each house's service ends
  total: number; // minutes start-to-finish (== route.time)
  depart: number; // minutes after the global clock that this truck leaves the FC
  color: string;
};

function legEnd(leg: Leg): Pt {
  return leg.kind === "drive" || leg.kind === "arc" ? leg.pts[leg.pts.length - 1] : leg.at;
}

/** Build every truck's itinerary once when play starts, then stagger departures. */
export function buildTracks(plan: Plan): Track[] {
  const tracks: Track[] = plan.routes.map((r, i) => {
    const itin = buildItinerary(SUB, r);
    const full: Pt[] = [];
    const deliveries: { key: string; t: number }[] = [];
    let t = 0;
    for (const leg of itin.legs) {
      if (leg.kind === "drive" || leg.kind === "arc") for (const p of leg.pts) full.push(p);
      else if (leg.kind === "service") deliveries.push({ key: leg.house, t: t + leg.dur });
      t += leg.dur;
    }
    return { itin, full, deliveries, total: itin.total, depart: 0, color: TRUCK_COLORS[i % TRUCK_COLORS.length] };
  });
  // One loading dock: the crew loads the hardest route first, and each truck
  // departs only once the trucks ahead of it have been loaded.
  const load = plan.routes.map((r) => r.orders * LOAD_PER_TOTE);
  const order = tracks.map((_, i) => i).sort((a, b) => tracks[b].total - tracks[a].total);
  let dock = 0;
  for (const ti of order) {
    tracks[ti].depart = dock;
    dock += load[ti];
  }
  return tracks;
}

/** Houses delivered by global clock `t` (a house flips once its service ends). */
function deliveredAt(tracks: Track[], t: number): Set<string> {
  const done = new Set<string>();
  for (const track of tracks) {
    const e = t - track.depart;
    for (const d of track.deliveries) if (e >= d.t) done.add(d.key);
  }
  return done;
}

/** A checkmark in the truck's colour, with a white halo so it reads on the map. */
function drawCheck(ctx: CanvasRenderingContext2D, cx: number, cy: number, s: number, color: string): void {
  ctx.beginPath();
  ctx.moveTo(cx - s * 0.45, cy + s * 0.05);
  ctx.lineTo(cx - s * 0.1, cy + s * 0.4);
  ctx.lineTo(cx + s * 0.5, cy - s * 0.45);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.strokeStyle = "#ffffff";
  ctx.lineWidth = s * 0.55;
  ctx.stroke();
  ctx.strokeStyle = color;
  ctx.lineWidth = s * 0.34;
  ctx.stroke();
}

/**
 * Read the truck off its itinerary at the global clock: where its dot is, the
 * trail behind it, and whether it's out on the road (vs waiting at the FC or
 * already home). Walk the legs accumulating minutes; the leg holding `e` gives
 * the head (interpolated along a drive/arc, parked at an enter/service point).
 */
function posAt(track: Track, clock: number): { head: Pt; prefix: Pt[]; active: boolean } {
  const e = clock - track.depart;
  const legs = track.itin.legs;
  if (e <= 0 || legs.length === 0) return { head: WAREHOUSE, prefix: [], active: false };
  if (e >= track.total) return { head: legEnd(legs[legs.length - 1]), prefix: track.full, active: false };

  const prefix: Pt[] = [];
  let head: Pt = WAREHOUSE;
  let acc = 0;
  for (const leg of legs) {
    const end = acc + leg.dur;
    if (leg.kind === "drive" || leg.kind === "arc") {
      if (e >= end) {
        for (const p of leg.pts) prefix.push(p);
        head = leg.pts[leg.pts.length - 1];
      } else {
        const f = leg.dur > 0 ? (e - acc) / leg.dur : 0;
        head = alongPoly(leg.pts, f, prefix);
        break;
      }
    } else {
      // enter / service: the truck is parked at a single point for the duration.
      head = leg.at;
      if (e < end) {
        prefix.push(leg.at);
        break;
      }
      prefix.push(leg.at);
    }
    acc = end;
  }
  return { head, prefix, active: true };
}

/** Point at fraction `f` along a polyline; pushes the travelled prefix into `out`. */
function alongPoly(pts: Pt[], f: number, out: Pt[]): Pt {
  let total = 0;
  for (let i = 1; i < pts.length; i++) total += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
  const target = f * total;
  out.push(pts[0]);
  let acc = 0;
  for (let i = 1; i < pts.length; i++) {
    const d = Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
    if (acc + d >= target) {
      const t = d > 0 ? (target - acc) / d : 0;
      const head = { x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t, y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * t };
      out.push(head);
      return head;
    }
    out.push(pts[i]);
    acc += d;
  }
  return pts[pts.length - 1];
}

function drawAnimation(ctx: CanvasRenderingContext2D, tracks: Track[], t: number): void {
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  // Faint full routes underneath — "the roads ahead".
  for (const track of tracks) {
    if (track.full.length < 2) continue;
    trace(ctx, track.full, false);
    ctx.globalAlpha = 0.16;
    ctx.lineWidth = 1.4;
    ctx.strokeStyle = track.color;
    ctx.stroke();
  }

  // Travelled trail + the dot at each truck's head.
  for (const track of tracks) {
    const { head, prefix, active } = posAt(track, t);

    if (prefix.length >= 2) {
      trace(ctx, prefix, false);
      ctx.globalAlpha = 0.85;
      ctx.lineWidth = 2.4;
      ctx.strokeStyle = track.color;
      ctx.stroke();
    }

    // Trucks waiting at the FC or already home read smaller and dimmer, so the
    // ones actually out driving are what your eye follows.
    ctx.globalAlpha = active ? 1 : 0.55;
    ctx.beginPath();
    ctx.arc(head.x, head.y, active ? 6 : 4.5, 0, Math.PI * 2);
    ctx.fillStyle = track.color;
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = "#ffffff";
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

function drawClock(ctx: CanvasRenderingContext2D, t: number, maxT: number, playing: boolean): void {
  const done = t >= maxT;
  ctx.textAlign = "left";
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 15px system-ui, sans-serif";
  const badge = done ? "✓ day complete" : playing ? "▶ running the day" : "⏸ paused";
  ctx.fillText(`${badge}  ·  ${Math.round(Math.min(t, maxT))} / ${Math.round(maxT)} min`, 24, 640);
}

function drawTruckPanel(ctx: CanvasRenderingContext2D, plan: Plan, activeTruck: number | null, balanceLabel: string): void {
  ctx.textAlign = "left";
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 14px system-ui, sans-serif";
  ctx.fillText(`Plan — ${plan.routes.length} trucks  ·  balance: ${balanceLabel}`, PANEL_X, 28);
  ctx.fillStyle = COLOR.note;
  ctx.font = "12px system-ui, sans-serif";
  ctx.fillText(`${Math.round(plan.totalTime)} driver-min  ·  spread ${Math.round(plan.spread)} min`, PANEL_X, 45);

  plan.routes.forEach((route, i) => {
    const y = PANEL_ROW0 + i * PANEL_ROW_H;
    const lit = activeTruck === i;

    if (lit) {
      ctx.fillStyle = "rgba(20, 26, 34, 0.06)";
      ctx.fillRect(PANEL_X - 4, y - 13, PANEL_W + 8, PANEL_ROW_H);
    }

    ctx.strokeStyle = TRUCK_COLORS[i % TRUCK_COLORS.length];
    ctx.lineWidth = lit ? 5 : 3;
    ctx.beginPath();
    ctx.moveTo(PANEL_X, y - 4);
    ctx.lineTo(PANEL_X + 18, y - 4);
    ctx.stroke();

    ctx.fillStyle = lit ? COLOR.text : COLOR.note;
    ctx.font = `${lit ? "bold " : ""}12px system-ui, sans-serif`;
    ctx.fillText(
      `Truck ${i + 1}: ${route.orders}/${FLEET.totesPerTruck} totes · ${Math.round(route.time)}m · ${route.stops.length} stops`,
      PANEL_X + 26,
      y,
    );
  });

  if (plan.unrouted.length) {
    ctx.fillStyle = "#c0392b";
    ctx.font = "bold 12px system-ui, sans-serif";
    ctx.fillText(`⚠ ${plan.unrouted.length} stops unrouted`, PANEL_X, PANEL_ROW0 + plan.routes.length * PANEL_ROW_H + 2);
  }
}

/** Which truck-panel row (if any) a logical point falls on — for hover focus. */
export function truckPanelHitTest(plan: Plan, p: Pt): number | null {
  for (let i = 0; i < plan.routes.length; i++) {
    const y = PANEL_ROW0 + i * PANEL_ROW_H;
    if (p.x >= PANEL_X - 4 && p.x <= PANEL_X + PANEL_W + 4 && p.y >= y - 13 && p.y <= y + PANEL_ROW_H - 13) return i;
  }
  return null;
}

export type MapView = {
  orders: Set<string>;
  plan: Plan;
  hoverNbhd: string | null; // neighborhood under the cursor (map)
  focusTruck: number | null; // truck row under the cursor (panel)
  balanceLabel: string; // current balance level (off/low/med/high)
  anim?: { t: number; maxT: number; playing: boolean; tracks: Track[] } | null; // play mode
};

/**
 * Paint the frame. The map (z=1) is always the same picture — only the order
 * squares are tinted by their truck. The routes (z=2) ride on top, all of them
 * or just the focused truck's.
 */
export function drawMap(ctx: CanvasRenderingContext2D, view: MapView): void {
  const { orders, plan, hoverNbhd, focusTruck, balanceLabel, anim } = view;

  // Play mode: the static map underneath, then the moving dots on top. Hover
  // focus is suppressed so nothing competes with the trucks running their day.
  if (anim) {
    const houseColor = new Map<string, string>();
    plan.routes.forEach((r, i) => {
      for (const s of r.stops) for (const h of s.houses) houseColor.set(`${s.nbhd}#${h}`, TRUCK_COLORS[i % TRUCK_COLORS.length]);
    });
    drawLand(ctx);
    drawWater(ctx);
    drawTraffic(ctx);
    drawRegionLabels(ctx);
    drawRoads(ctx);
    drawBridges(ctx);
    drawGates(ctx);
    const delivered = deliveredAt(anim.tracks, anim.t);
    for (const n of NEIGHBORHOODS) drawNeighborhood(ctx, n, orders, houseColor, null, delivered);
    drawWarehouse(ctx);
    drawAnimation(ctx, anim.tracks, anim.t);
    drawHud(ctx);
    drawTruckPanel(ctx, plan, null, balanceLabel);
    drawClock(ctx, anim.t, anim.maxT, anim.playing);
    return;
  }

  // Each ordered house takes the colour of the truck that delivers it — so a
  // neighborhood split between two trucks shows both colours.
  const houseColor = new Map<string, string>();
  plan.routes.forEach((r, i) => {
    for (const s of r.stops) for (const h of s.houses) houseColor.set(`${s.nbhd}#${h}`, TRUCK_COLORS[i % TRUCK_COLORS.length]);
  });

  // The "active" truck: the one hovered directly in the panel, or — when a
  // neighborhood is hovered — whichever truck serves it. Every focus effect
  // (single route, popped houses, lit panel row, breakdown) keys off this, so
  // hovering a neighborhood behaves exactly like hovering its truck.
  let activeTruck = focusTruck;
  if (activeTruck === null && hoverNbhd !== null) {
    const serving = plan.routes.findIndex((r) => r.stops.some((s) => s.nbhd === hoverNbhd));
    if (serving >= 0) activeTruck = serving;
  }

  // The active truck's houses pop; everyone else's fade back.
  let highlight: Set<string> | null = null;
  if (activeTruck !== null && plan.routes[activeTruck]) {
    highlight = new Set();
    for (const s of plan.routes[activeTruck].stops) for (const i of s.houses) highlight.add(`${s.nbhd}#${i}`);
  }

  // z=1 — the map itself.
  drawLand(ctx);
  drawWater(ctx);
  drawTraffic(ctx);
  drawRegionLabels(ctx);
  drawRoads(ctx);
  drawBridges(ctx);
  drawGates(ctx);
  for (const n of NEIGHBORHOODS) drawNeighborhood(ctx, n, orders, houseColor, highlight, null);
  drawWarehouse(ctx);

  // z=2 — the routes, on top so the loop around each cul-de-sac is visible.
  drawRoutes(ctx, plan, activeTruck);

  // Screen furniture — all off the map, so nothing floats over the routes.
  drawHud(ctx);
  drawTruckPanel(ctx, plan, activeTruck, balanceLabel);
  drawDetail(ctx, plan, orders, hoverNbhd, activeTruck);
}
