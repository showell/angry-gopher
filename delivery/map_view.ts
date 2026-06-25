// map_view.ts — draws the static Seattle network onto a 2D canvas, in logical
// (1000x720) coordinates. No interaction yet; this is the backdrop everything
// else (customers, routes, the manager's overrides) will later draw on top of.

import type { Pt } from "./geography.ts";
import {
  MAP_W,
  MAP_H,
  WEST_SHORE,
  EAST_SHORE,
  MERCER_ISLAND,
  WAREHOUSE,
  BRIDGES,
  PLACES,
  MERCER_MESS,
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
  place: "#3a3f46",
  placeText: "#2a2e34",
  note: "#7b8088",
  depot: "#c0392b",
  faint: "#b9b3bf",
};

function poly(ctx: CanvasRenderingContext2D, pts: Pt[], close: boolean): void {
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
  if (close) ctx.closePath();
}

/** Lake polygon = west shore (N->S) then east shore (S->N). */
function lakePath(ctx: CanvasRenderingContext2D): void {
  ctx.beginPath();
  ctx.moveTo(WEST_SHORE[0].x, WEST_SHORE[0].y);
  for (const p of WEST_SHORE) ctx.lineTo(p.x, p.y);
  for (let i = EAST_SHORE.length - 1; i >= 0; i--) ctx.lineTo(EAST_SHORE[i].x, EAST_SHORE[i].y);
  ctx.closePath();
}

function drawLand(ctx: CanvasRenderingContext2D): void {
  // Whole canvas is Seattle; paint the Eastside over the right portion. The lake
  // (drawn next) hides the straight seam between them.
  ctx.fillStyle = COLOR.westLand;
  ctx.fillRect(0, 0, MAP_W, MAP_H);
  ctx.fillStyle = COLOR.eastLand;
  ctx.fillRect(500, 0, MAP_W - 500, MAP_H);
}

function drawLake(ctx: CanvasRenderingContext2D): void {
  lakePath(ctx);
  ctx.fillStyle = COLOR.water;
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.strokeStyle = COLOR.waterEdge;
  ctx.stroke();

  // Mercer Island sits on top of the water.
  poly(ctx, MERCER_ISLAND, true);
  ctx.fillStyle = COLOR.island;
  ctx.fill();
  ctx.strokeStyle = COLOR.waterEdge;
  ctx.stroke();
}

function drawTraffic(ctx: CanvasRenderingContext2D): void {
  const g = ctx.createRadialGradient(
    MERCER_MESS.center.x,
    MERCER_MESS.center.y,
    10,
    MERCER_MESS.center.x,
    MERCER_MESS.center.y,
    MERCER_MESS.radius,
  );
  g.addColorStop(0, COLOR.traffic);
  g.addColorStop(1, "rgba(206, 64, 52, 0)");
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(MERCER_MESS.center.x, MERCER_MESS.center.y, MERCER_MESS.radius, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "rgba(150, 40, 32, 0.7)";
  ctx.font = "italic 13px system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText("the Mercer Mess", MERCER_MESS.center.x, MERCER_MESS.center.y + 4);
}

function drawBridges(ctx: CanvasRenderingContext2D): void {
  for (const b of BRIDGES) {
    // Deck.
    poly(ctx, b.spans, false);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.lineWidth = 9;
    ctx.strokeStyle = COLOR.bridge;
    ctx.stroke();
    // Center stripe.
    poly(ctx, b.spans, false);
    ctx.lineWidth = 2;
    ctx.setLineDash([8, 7]);
    ctx.strokeStyle = COLOR.bridgeStripe;
    ctx.stroke();
    ctx.setLineDash([]);
    // Label.
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

function drawWarehouse(ctx: CanvasRenderingContext2D): void {
  const { x, y } = WAREHOUSE;
  // A little depot box with a roof.
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

  ctx.fillStyle = COLOR.placeText;
  ctx.font = "bold 13px system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText("Warehouse", x, y + 26);
  ctx.fillStyle = COLOR.note;
  ctx.font = "italic 11px system-ui, sans-serif";
  ctx.fillText("AmazonFresh DC", x, y + 39);
}

function drawPlaces(ctx: CanvasRenderingContext2D): void {
  for (const p of PLACES) {
    ctx.beginPath();
    ctx.arc(p.at.x, p.at.y, 4, 0, Math.PI * 2);
    ctx.fillStyle = COLOR.place;
    ctx.fill();
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 1.5;
    ctx.stroke();

    ctx.fillStyle = COLOR.placeText;
    ctx.font = "12px system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.fillText(p.name, p.at.x + 8, p.at.y + 4);
    if (p.note) {
      ctx.fillStyle = COLOR.note;
      ctx.font = "italic 10px system-ui, sans-serif";
      ctx.fillText(p.note, p.at.x + 8, p.at.y + 16);
    }
  }
}

function drawRegionLabels(ctx: CanvasRenderingContext2D): void {
  ctx.textAlign = "center";
  ctx.fillStyle = COLOR.faint;
  ctx.font = "bold 26px system-ui, sans-serif";
  ctx.fillText("SEATTLE", 175, 56);
  ctx.font = "italic 13px system-ui, sans-serif";
  ctx.fillText("the Westside", 175, 76);

  ctx.font = "bold 26px system-ui, sans-serif";
  ctx.fillText("THE EASTSIDE", 820, 56);
  ctx.font = "italic 13px system-ui, sans-serif";
  ctx.fillText("warehouse country", 820, 76);

  // "Lake Washington" set vertically down the water.
  ctx.save();
  ctx.translate(498, 300);
  ctx.rotate(Math.PI / 2);
  ctx.fillStyle = COLOR.waterEdge;
  ctx.font = "italic 16px system-ui, sans-serif";
  ctx.fillText("Lake Washington", 0, 0);
  ctx.restore();
}

function drawTitle(ctx: CanvasRenderingContext2D): void {
  ctx.textAlign = "left";
  ctx.fillStyle = "#2a2e34";
  ctx.font = "bold 18px system-ui, sans-serif";
  ctx.fillText("Seattle Delivery Network", 24, 690);
  ctx.fillStyle = COLOR.note;
  ctx.font = "italic 12px system-ui, sans-serif";
  ctx.fillText("totally not to scale", 24, 708);
}

/** Paint the whole static map into the logical 1000x720 space. */
export function drawMap(ctx: CanvasRenderingContext2D): void {
  drawLand(ctx);
  drawLake(ctx);
  drawTraffic(ctx);
  drawRegionLabels(ctx);
  drawBridges(ctx);
  drawPlaces(ctx);
  drawWarehouse(ctx);
  drawTitle(ctx);
}
