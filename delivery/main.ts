// main.ts — entry point. Builds a full-window canvas, fits the fixed 1000x720
// logical map into it (letterboxed, DPR-aware), and draws the map. Redraws on
// resize. No state, no interaction yet.

import { MAP_W, MAP_H } from "./geography.ts";
import { drawMap } from "./map_view.ts";

const PAGE_BG = "#0d1b2a";

const canvas = document.createElement("canvas");
document.body.appendChild(canvas);
const ctx = canvas.getContext("2d");
if (!ctx) throw new Error("2d canvas context unavailable");

function render(c: CanvasRenderingContext2D): void {
  const dpr = window.devicePixelRatio || 1;
  const vw = window.innerWidth;
  const vh = window.innerHeight;

  canvas.width = Math.round(vw * dpr);
  canvas.height = Math.round(vh * dpr);
  canvas.style.width = vw + "px";
  canvas.style.height = vh + "px";

  // Fit the logical map into the window, centered (letterboxed).
  const scale = Math.min(vw / MAP_W, vh / MAP_H);
  const offX = (vw - MAP_W * scale) / 2;
  const offY = (vh - MAP_H * scale) / 2;

  // Backdrop (the letterbox margins).
  c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.fillStyle = PAGE_BG;
  c.fillRect(0, 0, vw, vh);

  // Logical-coordinate space for the map itself.
  c.setTransform(scale * dpr, 0, 0, scale * dpr, offX * dpr, offY * dpr);
  drawMap(c);
}

render(ctx);
window.addEventListener("resize", () => render(ctx));
