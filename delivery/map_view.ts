// map_view.ts — draws the static Seattle network onto a 2D canvas, in logical
// (1000x720) coordinates. The backdrop everything else (customers, routes, the
// manager's overrides) will later draw on top of. Neighborhood names are
// hover-reveal to keep the map uncluttered; pass the hovered name to drawMap.

import type { Pt, Neighborhood } from "./geography.ts";
import {
  MAP_W,
  MAP_H,
  WEST_SHORE,
  EAST_SHORE,
  MERCER_ISLAND,
  PUGET_SOUND,
  LAKE_UNION,
  CANAL_WEST,
  CANAL_EAST,
  WAREHOUSE,
  BRIDGES,
  NEIGHBORHOODS,
  ROADS,
  MERCER_MESS,
  housesOf,
  nodeAt,
} from "./geography.ts";

const COLOR = {
  westLand: "#e7e3ea", // Seattle — faintly cool/dense
  eastLand: "#e7eede", // Eastside — faintly green/roomy
  water: "#9fcfe6",
  waterEdge: "#6fb2d2",
  island: "#eef3df",
  bridge: "#5b6470",
  bridgeStripe: "#d9b34a",
  traffic: "rgba(206, 64, 52, 0.14)",
  road: "#cfc7bb",
  roadCasing: "#b3aa9c",
  ring: "#a89f90",
  house: "#dcae6e",
  houseEdge: "#a87b3c",
  houseHot: "#e8732e",
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
  // Whole canvas is Seattle; paint the Eastside over the right portion. The lake
  // (drawn next) hides the straight seam between them.
  ctx.fillStyle = COLOR.westLand;
  ctx.fillRect(0, 0, MAP_W, MAP_H);
  ctx.fillStyle = COLOR.eastLand;
  ctx.fillRect(540, 0, MAP_W - 540, MAP_H);
}

/** Lake Washington polygon = west shore (N->S) then east shore (S->N). */
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

/** A channel: a fat water stroke with a faint bank. */
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
  fillPoly(ctx, LAKE_UNION, COLOR.water, COLOR.waterEdge); // sits over the canal joins
  // Mercer Island sits on top of Lake Washington.
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

function drawRoads(ctx: CanvasRenderingContext2D): void {
  for (const [a, b] of ROADS) {
    const p = nodeAt(a);
    const q = nodeAt(b);
    ctx.lineCap = "round";
    ctx.beginPath();
    ctx.moveTo(p.x, p.y);
    ctx.lineTo(q.x, q.y);
    ctx.lineWidth = 6;
    ctx.strokeStyle = COLOR.roadCasing;
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(p.x, p.y);
    ctx.lineTo(q.x, q.y);
    ctx.lineWidth = 3.5;
    ctx.strokeStyle = COLOR.road;
    ctx.stroke();
  }
}

function drawBridges(ctx: CanvasRenderingContext2D): void {
  for (const b of BRIDGES) {
    trace(ctx, b.spans, false);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.lineWidth = 9;
    ctx.strokeStyle = COLOR.bridge;
    ctx.stroke();
    trace(ctx, b.spans, false);
    ctx.lineWidth = 2;
    ctx.setLineDash([8, 7]);
    ctx.strokeStyle = COLOR.bridgeStripe;
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = "#ffffff";
    ctx.font = "bold 14px system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.strokeStyle = COLOR.bridge;
    ctx.lineWidth = 3;
    ctx.strokeText(b.name, b.label.x, b.label.y);
    ctx.fillText(b.name, b.label.x, b.label.y);
    if (b.note) {
      ctx.fillStyle = COLOR.note;
      ctx.font = "italic 11px system-ui, sans-serif";
      ctx.fillText(b.note, b.label.x, b.label.y + 14);
    }
  }
}

function drawNeighborhood(ctx: CanvasRenderingContext2D, n: Neighborhood, hot: boolean): void {
  // Optional center pond (Green Lake).
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
  ctx.strokeStyle = hot ? COLOR.houseHot : COLOR.ring;
  ctx.stroke();

  // Houses (squares sitting on the ring).
  const s = 7;
  for (const h of housesOf(n)) {
    ctx.fillStyle = hot ? COLOR.houseHot : COLOR.house;
    ctx.strokeStyle = COLOR.houseEdge;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.rect(h.x - s / 2, h.y - s / 2, s, s);
    ctx.fill();
    ctx.stroke();
  }
}

/** A hover label: name (+ note) on a little rounded card above the neighborhood. */
function drawHoverCard(ctx: CanvasRenderingContext2D, n: Neighborhood): void {
  const lines = n.note ? [n.name, n.note] : [n.name];
  ctx.font = "bold 13px system-ui, sans-serif";
  const nameW = ctx.measureText(n.name).width;
  ctx.font = "italic 11px system-ui, sans-serif";
  const noteW = n.note ? ctx.measureText(n.note).width : 0;
  const w = Math.max(nameW, noteW) + 16;
  const h = lines.length === 2 ? 38 : 24;
  const x = n.center.x - w / 2;
  const y = n.center.y - n.ringRadius - h - 8;

  ctx.fillStyle = "rgba(20, 26, 34, 0.92)";
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, 6);
  ctx.fill();

  ctx.textAlign = "center";
  ctx.fillStyle = "#ffffff";
  ctx.font = "bold 13px system-ui, sans-serif";
  ctx.fillText(n.name, n.center.x, y + 16);
  if (n.note) {
    ctx.fillStyle = "#bcd3df";
    ctx.font = "italic 11px system-ui, sans-serif";
    ctx.fillText(n.note, n.center.x, y + 31);
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
  ctx.fillText("SEATTLE", 150, 52);
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("the Westside", 150, 70);

  ctx.font = "bold 24px system-ui, sans-serif";
  ctx.fillText("THE EASTSIDE", 840, 52);
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("warehouse country", 840, 70);

  // Water labels.
  ctx.save();
  ctx.translate(545, 320);
  ctx.rotate(Math.PI / 2);
  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 16px system-ui, sans-serif";
  ctx.fillText("Lake Washington", 0, 0);
  ctx.restore();

  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 11px system-ui, sans-serif";
  ctx.fillText("Lake Union", 358, 400);

  ctx.save();
  ctx.translate(48, 380);
  ctx.rotate(-Math.PI / 2);
  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 13px system-ui, sans-serif";
  ctx.fillText("Puget Sound", 0, 0);
  ctx.restore();
}

function drawTitle(ctx: CanvasRenderingContext2D): void {
  ctx.textAlign = "left";
  ctx.fillStyle = COLOR.text;
  ctx.font = "bold 18px system-ui, sans-serif";
  ctx.fillText("Seattle Delivery Network", 24, 690);
  ctx.fillStyle = COLOR.note;
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("totally not to scale  ·  hover a neighborhood for its name", 24, 708);
}

/** Paint the whole static map. `hover` is the hovered neighborhood name, if any. */
export function drawMap(ctx: CanvasRenderingContext2D, hover: string | null): void {
  drawLand(ctx);
  drawWater(ctx);
  drawTraffic(ctx);
  drawRegionLabels(ctx);
  drawRoads(ctx);
  drawBridges(ctx);
  for (const n of NEIGHBORHOODS) drawNeighborhood(ctx, n, n.name === hover);
  drawWarehouse(ctx);
  const hot = NEIGHBORHOODS.find((n) => n.name === hover);
  if (hot) drawHoverCard(ctx, hot);
  drawTitle(ctx);
}
