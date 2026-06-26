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

  // Houses — orders pop, plain homes recede.
  housesOf(n).forEach((h, i) => {
    const isOrder = orders.has(`${n.name}#${i}`);
    if (isOrder) {
      const s = 9;
      ctx.fillStyle = COLOR.order;
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.rect(h.x - s / 2, h.y - s / 2, s, s);
      ctx.fill();
      ctx.stroke();
    } else {
      const s = 6;
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
  swatch(ctx, 24, 30, COLOR.order, "#ffffff", 9, "order today");
  swatch(ctx, 24, 52, COLOR.home, COLOR.homeEdge, 9, "home");

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
  ctx.fillText("totally not to scale  ·  hover a neighborhood  ·  press R to reshuffle orders", 24, 706);
}

/**
 * The drawn polyline of a truck's whole tour, FC -> stops -> FC, following real
 * arteries and bridges (each service-to-service leg is the substrate's shortest
 * path, stitched edge by edge).
 */
function routeGeometry(route: Route): Pt[] {
  const waypoints = ["FC", ...route.stops.map((s) => s.nbhd), "FC"];
  const nodes: string[] = [];
  for (let i = 1; i < waypoints.length; i++) {
    const leg = SUB.path(waypoints[i - 1], waypoints[i]); // [a, ..., b]
    for (const node of leg) if (nodes[nodes.length - 1] !== node) nodes.push(node);
  }
  const pts: Pt[] = [];
  for (let i = 1; i < nodes.length; i++) pts.push(...edgePolyline(nodes[i - 1], nodes[i]));
  return pts;
}

function drawRoutes(ctx: CanvasRenderingContext2D, plan: Plan, hover: string | null): void {
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  plan.routes.forEach((route, i) => {
    const pts = routeGeometry(route);
    if (pts.length < 2) return;
    const color = TRUCK_COLORS[i % TRUCK_COLORS.length];
    const serves = route.stops.some((s) => s.nbhd === hover);
    trace(ctx, pts, false);
    ctx.globalAlpha = hover && !serves ? 0.25 : 0.9;
    ctx.lineWidth = serves ? 6 : 3.5;
    ctx.strokeStyle = color;
    ctx.stroke();
    ctx.globalAlpha = 1;
  });
}

function drawTruckPanel(ctx: CanvasRenderingContext2D, plan: Plan, hover: string | null): void {
  const x = MAP_W - 234;
  let y = 28;

  ctx.textAlign = "left";
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 14px system-ui, sans-serif";
  ctx.fillText(`Plan — ${plan.routes.length} trucks`, x, y);
  y += 17;
  ctx.fillStyle = COLOR.note;
  ctx.font = "12px system-ui, sans-serif";
  ctx.fillText(`${Math.round(plan.totalTime)} driver-min  ·  ${Math.round(plan.travel)} on the road`, x, y);
  y += 20;

  plan.routes.forEach((route, i) => {
    const color = TRUCK_COLORS[i % TRUCK_COLORS.length];
    const serves = route.stops.some((s) => s.nbhd === hover);
    ctx.strokeStyle = color;
    ctx.lineWidth = serves ? 5 : 3;
    ctx.beginPath();
    ctx.moveTo(x, y - 4);
    ctx.lineTo(x + 18, y - 4);
    ctx.stroke();

    ctx.fillStyle = serves ? COLOR.text : COLOR.note;
    ctx.font = `${serves ? "bold " : ""}12px system-ui, sans-serif`;
    ctx.fillText(`Truck ${i + 1}: ${route.orders}t · ${Math.round(route.time)}m · ${route.stops.length} stops`, x + 26, y);
    y += 18;
  });

  if (plan.unrouted.length) {
    ctx.fillStyle = "#c0392b";
    ctx.font = "bold 12px system-ui, sans-serif";
    ctx.fillText(`⚠ ${plan.unrouted.length} stops unrouted`, x, y + 2);
  }
}

/** Paint the whole map plus the day's plan. `hover` highlights one neighborhood + its truck. */
export function drawMap(ctx: CanvasRenderingContext2D, hover: string | null, orders: Set<string>, plan: Plan): void {
  drawLand(ctx);
  drawWater(ctx);
  drawTraffic(ctx);
  drawRegionLabels(ctx);
  drawRoads(ctx);
  drawBridges(ctx);
  drawRoutes(ctx, plan, hover);
  drawGates(ctx);
  for (const n of NEIGHBORHOODS) drawNeighborhood(ctx, n, n.name === hover, orders);
  drawWarehouse(ctx);
  const hot = NEIGHBORHOODS.find((n) => n.name === hover);
  if (hot) drawHoverCard(ctx, hot, orders);
  drawHud(ctx);
  drawTruckPanel(ctx, plan, hover);
}
