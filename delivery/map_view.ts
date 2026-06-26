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

// The routing substrate is static, so build the travel-time matrix once.
const SUB = buildSubstrate();

const HOME_COUNT = NEIGHBORHOODS.reduce((s, n) => s + n.houses, 0);

// One distinct colour per truck — saturated enough to read over the pale land.
const TRUCK_COLORS = [
  "#1f6feb", // blue
  "#d9480f", // burnt orange
  "#2f9e44", // green
  "#ae3ec9", // purple
  "#1098ad", // teal
  "#e8590c", // amber
  "#c2255c", // magenta
  "#5c7cfa", // periwinkle
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
  hot: boolean,
  orders: Set<string>,
  orderColor: string,
  highlight: Set<string> | null, // houses of the focused truck, to make pop
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

  // Ring road.
  ctx.beginPath();
  ctx.arc(n.center.x, n.center.y, n.ringRadius, 0, Math.PI * 2);
  ctx.lineWidth = hot ? 4 : 3;
  ctx.strokeStyle = hot ? COLOR.ringHot : COLOR.ring;
  ctx.stroke();

  // Houses — orders take their truck's colour and pop, plain homes recede.
  housesOf(n).forEach((h, i) => {
    const isOrder = orders.has(`${n.name}#${i}`);
    if (isOrder) {
      const focused = highlight !== null && highlight.has(`${n.name}#${i}`);
      const s = focused ? 13 : ORDER_SIZE;
      ctx.save();
      if (focused) {
        ctx.shadowColor = "rgba(255, 255, 255, 0.95)";
        ctx.shadowBlur = 9; // a halo so the truck's stops read at a glance
      }
      ctx.fillStyle = orderColor;
      ctx.beginPath();
      ctx.rect(h.x - s / 2, h.y - s / 2, s, s);
      ctx.fill();
      ctx.restore();
      ctx.strokeStyle = focused ? "#fff6c0" : "#ffffff";
      ctx.lineWidth = focused ? 2.5 : 1.5;
      ctx.beginPath();
      ctx.rect(h.x - s / 2, h.y - s / 2, s, s);
      ctx.stroke();
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

type CardLine = { text: string; font: string; color: string };

function drawHoverCard(ctx: CanvasRenderingContext2D, n: Neighborhood, orders: Set<string>): void {
  let count = 0;
  for (let i = 0; i < n.houses; i++) if (orders.has(`${n.name}#${i}`)) count++;

  const bold = "bold 13px system-ui, sans-serif";
  const italic = "italic 11px system-ui, sans-serif";
  const lines: CardLine[] = [{ text: n.name, font: bold, color: "#ffffff" }];
  if (n.note) lines.push({ text: n.note, font: italic, color: "#bcd3df" });
  const fc = Math.round(SUB.time("FC", n.name));
  lines.push({
    text: `${count} order${count === 1 ? "" : "s"}  ·  ≈${fc} min from FC`,
    font: italic,
    color: "#bcd3df",
  });

  let textW = 0;
  for (const l of lines) {
    ctx.font = l.font;
    textW = Math.max(textW, ctx.measureText(l.text).width);
  }
  const lineH = 16;
  const w = textW + 18;
  const h = 10 + lines.length * lineH;
  const x = n.center.x - w / 2;
  const y = n.center.y - n.ringRadius - h - 8;

  ctx.fillStyle = "rgba(20, 26, 34, 0.92)";
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, 6);
  ctx.fill();

  ctx.textAlign = "center";
  let ty = y + 18;
  for (const l of lines) {
    ctx.fillStyle = l.color;
    ctx.font = l.font;
    ctx.fillText(l.text, n.center.x, ty);
    ty += lineH;
  }
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
  ctx.fillText("totally not to scale  ·  hover a neighborhood or a truck  ·  press R to reshuffle orders", 24, 706);
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
 * The route layer (z=2), drawn on top of the map. With a truck focused (panel
 * hover) we show ONLY that truck's tour; otherwise all of them, dimming the rest
 * when a neighborhood is hovered to spotlight whoever serves it.
 */
function drawRoutes(ctx: CanvasRenderingContext2D, plan: Plan, hoverNbhd: string | null, focusTruck: number | null): void {
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  plan.routes.forEach((route, i) => {
    if (focusTruck !== null && i !== focusTruck) return; // single-route mode
    const pts = routeGeometry(route);
    if (pts.length < 2) return;
    const serves = route.stops.some((s) => s.nbhd === hoverNbhd);
    const emphasised = focusTruck === i || serves;
    const dim = focusTruck === null && hoverNbhd !== null && !serves;
    trace(ctx, pts, false);
    ctx.globalAlpha = dim ? 0.16 : 0.92;
    ctx.lineWidth = emphasised ? 4 : 2.2;
    ctx.strokeStyle = TRUCK_COLORS[i % TRUCK_COLORS.length];
    ctx.stroke();
    ctx.globalAlpha = 1;
  });
}

function drawTruckPanel(ctx: CanvasRenderingContext2D, plan: Plan, hoverNbhd: string | null, focusTruck: number | null): void {
  ctx.textAlign = "left";
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 14px system-ui, sans-serif";
  ctx.fillText(`Plan — ${plan.routes.length} trucks`, PANEL_X, 28);
  ctx.fillStyle = COLOR.note;
  ctx.font = "12px system-ui, sans-serif";
  ctx.fillText(
    `${Math.round(plan.totalTime)} driver-min  ·  ${Math.round(plan.travel)} road / ${Math.round(plan.local)} local`,
    PANEL_X,
    45,
  );

  plan.routes.forEach((route, i) => {
    const y = PANEL_ROW0 + i * PANEL_ROW_H;
    const serves = route.stops.some((s) => s.nbhd === hoverNbhd);
    const lit = focusTruck === i || serves;

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
};

/**
 * Paint the frame. The map (z=1) is always the same picture — only the order
 * squares are tinted by their truck. The routes (z=2) ride on top, all of them
 * or just the focused truck's.
 */
export function drawMap(ctx: CanvasRenderingContext2D, view: MapView): void {
  const { orders, plan, hoverNbhd, focusTruck } = view;

  // Each neighborhood's order squares take the colour of the truck serving it.
  const nbhdColor = new Map<string, string>();
  plan.routes.forEach((r, i) => {
    for (const s of r.stops) nbhdColor.set(s.nbhd, TRUCK_COLORS[i % TRUCK_COLORS.length]);
  });

  // When a truck is focused, the houses it delivers to get a bright border.
  let highlight: Set<string> | null = null;
  if (focusTruck !== null && plan.routes[focusTruck]) {
    highlight = new Set();
    for (const s of plan.routes[focusTruck].stops) for (const i of s.houses) highlight.add(`${s.nbhd}#${i}`);
  }

  // z=1 — the map itself.
  drawLand(ctx);
  drawWater(ctx);
  drawTraffic(ctx);
  drawRegionLabels(ctx);
  drawRoads(ctx);
  drawBridges(ctx);
  drawGates(ctx);
  for (const n of NEIGHBORHOODS) drawNeighborhood(ctx, n, n.name === hoverNbhd, orders, nbhdColor.get(n.name) ?? COLOR.order, highlight);
  drawWarehouse(ctx);

  // z=2 — the routes, on top so the loop around each cul-de-sac is visible.
  drawRoutes(ctx, plan, hoverNbhd, focusTruck);

  // Screen furniture.
  const hot = NEIGHBORHOODS.find((n) => n.name === hoverNbhd);
  if (hot) drawHoverCard(ctx, hot, orders);
  drawHud(ctx);
  drawTruckPanel(ctx, plan, hoverNbhd, focusTruck);
}
