// main.ts — entry point. Builds a full-window canvas, fits the fixed 1000x720
// logical map into it (letterboxed, DPR-aware), draws the map with the day's
// orders, reveals a neighborhood's name on hover, and reshuffles orders on R.

import { MAP_W, MAP_H, FLEET, NEIGHBORHOODS } from "./geography.ts";
import type { Pt } from "./geography.ts";
import { chooseOrders, demandByNeighborhood } from "./orders.ts";
import { buildSubstrate } from "./roadgraph.ts";
import { solve } from "./solver.ts";
import type { Plan } from "./solver.ts";
import { drawMap, truckPanelHitTest } from "./map_view.ts";

const SUB = buildSubstrate();

const PAGE_BG = "#0d1b2a";

const canvas = document.createElement("canvas");
document.body.appendChild(canvas);
const ctx = canvas.getContext("2d");
if (!ctx) throw new Error("2d canvas context unavailable");

// View transform (logical -> screen), kept so the pointer maps back to logical
// coordinates for hit-testing.
let scale = 1;
let offX = 0;
let offY = 0;
let hoverNbhd: string | null = null; // neighborhood under the cursor
let focusTruck: number | null = null; // truck-panel row under the cursor

// The day's deliveries. Fixed seed => reproducible on load; R picks a new seed.
let seed = 49;
let orders = chooseOrders(seed, FLEET.orders);
let plan: Plan = solve(SUB, demandByNeighborhood(orders));

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

  ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx!.fillStyle = PAGE_BG;
  ctx!.fillRect(0, 0, vw, vh);

  ctx!.setTransform(scale * dpr, 0, 0, scale * dpr, offX * dpr, offY * dpr);
  drawMap(ctx!, { orders, plan, hoverNbhd, focusTruck });
}

/** Nearest neighborhood whose ring the logical point falls within (else null). */
function hitTest(p: Pt): string | null {
  let best: string | null = null;
  let bestD = Infinity;
  for (const n of NEIGHBORHOODS) {
    const d = Math.hypot(p.x - n.center.x, p.y - n.center.y);
    if (d <= n.ringRadius + 18 && d < bestD) {
      bestD = d;
      best = n.name;
    }
  }
  return best;
}

canvas.addEventListener("mousemove", (e) => {
  const p = { x: (e.clientX - offX) / scale, y: (e.clientY - offY) / scale };
  // The truck panel sits on top of the map; test it first.
  const truck = truckPanelHitTest(plan, p);
  const nbhd = truck === null ? hitTest(p) : null;
  if (truck !== focusTruck || nbhd !== hoverNbhd) {
    focusTruck = truck;
    hoverNbhd = nbhd;
    canvas.style.cursor = truck !== null || nbhd ? "pointer" : "default";
    render();
  }
});

window.addEventListener("keydown", (e) => {
  if (e.key === "r" || e.key === "R") {
    seed = (seed * 1664525 + 1013904223) >>> 0; // a fresh, deterministic seed
    orders = chooseOrders(seed, FLEET.orders);
    plan = solve(SUB, demandByNeighborhood(orders)); // re-plan for the new day
    focusTruck = null; // truck indices may not survive a re-plan
    hoverNbhd = null;
    render();
  }
});

render();
window.addEventListener("resize", render);
