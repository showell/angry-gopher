// main.ts — entry point. Builds a full-window canvas, fits the fixed 1000x720
// logical map into it (letterboxed, DPR-aware), draws the map, and reveals a
// neighborhood's name on hover. Redraws on resize and on hover changes.

import { MAP_W, MAP_H, NEIGHBORHOODS } from "./geography.ts";
import type { Pt } from "./geography.ts";
import { drawMap } from "./map_view.ts";

const PAGE_BG = "#0d1b2a";

const canvas = document.createElement("canvas");
document.body.appendChild(canvas);
const ctx = canvas.getContext("2d");
if (!ctx) throw new Error("2d canvas context unavailable");

// Current view transform (logical -> screen), kept so the pointer can be mapped
// back into logical coordinates for hit-testing.
let scale = 1;
let offX = 0;
let offY = 0;
let hover: string | null = null;

function render(): void {
  const dpr = window.devicePixelRatio || 1;
  const vw = window.innerWidth;
  const vh = window.innerHeight;

  canvas.width = Math.round(vw * dpr);
  canvas.height = Math.round(vh * dpr);
  canvas.style.width = vw + "px";
  canvas.style.height = vh + "px";

  scale = Math.min(vw / MAP_W, vh / MAP_H);
  offX = (vw - MAP_W * scale) / 2;
  offY = (vh - MAP_H * scale) / 2;

  // Backdrop (the letterbox margins).
  ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx!.fillStyle = PAGE_BG;
  ctx!.fillRect(0, 0, vw, vh);

  // Logical-coordinate space for the map itself.
  ctx!.setTransform(scale * dpr, 0, 0, scale * dpr, offX * dpr, offY * dpr);
  drawMap(ctx!, hover);
}

/** Nearest neighborhood whose ring the logical point falls within (else null). */
function hitTest(p: Pt): string | null {
  let best: string | null = null;
  let bestD = Infinity;
  for (const n of NEIGHBORHOODS) {
    const d = Math.hypot(p.x - n.center.x, p.y - n.center.y);
    if (d <= n.ringRadius + 10 && d < bestD) {
      bestD = d;
      best = n.name;
    }
  }
  return best;
}

canvas.addEventListener("mousemove", (e) => {
  const p = { x: (e.clientX - offX) / scale, y: (e.clientY - offY) / scale };
  const hit = hitTest(p);
  if (hit !== hover) {
    hover = hit;
    canvas.style.cursor = hit ? "pointer" : "default";
    render();
  }
});

render();
window.addEventListener("resize", render);
