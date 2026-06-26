// main.ts — entry point. Builds a full-window canvas, fits the fixed 1000x720
// logical map into it (letterboxed, DPR-aware), draws the map with the day's
// orders, reveals a neighborhood's name on hover, and reshuffles orders on R.

import { MAP_W, MAP_H, FLEET, NEIGHBORHOODS } from "./geography.ts";
import type { Pt } from "./geography.ts";
import { chooseOrders, ordersByNeighborhood } from "./orders.ts";
import { buildSubstrate } from "./roadgraph.ts";
import { solve, BALANCE_LEVELS, BALANCE_LABELS } from "./solver.ts";
import type { Plan } from "./solver.ts";
import { drawMap, truckPanelHitTest, buildTracks } from "./map_view.ts";
import type { Track } from "./map_view.ts";

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
let balance = 1; // index into BALANCE_LEVELS; default 'low' — B cycles it
let orders = chooseOrders(seed, FLEET.orders);
let plan: Plan = solve(SUB, ordersByNeighborhood(orders), BALANCE_LEVELS[balance]);

// Playback: a single clock (route-minutes) advances PLAY_RATE min per real
// second, so the longest route (~200 min) plays out in ~40s. null = static map.
const PLAY_RATE = 5;
let anim: { t: number; maxT: number; playing: boolean; tracks: Track[] } | null = null;
let lastFrame = 0;

function replan(): void {
  plan = solve(SUB, ordersByNeighborhood(orders), BALANCE_LEVELS[balance]);
  anim = null; // a new plan invalidates the running animation
}

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
  drawMap(ctx!, { orders, plan, hoverNbhd, focusTruck, balanceLabel: BALANCE_LABELS[balance], anim });
}

/** The playback clock: advance t by real elapsed time, redraw, stop at the end. */
function tick(now: number): void {
  if (!anim || !anim.playing) return;
  const dt = lastFrame ? (now - lastFrame) / 1000 : 0;
  lastFrame = now;
  anim.t = Math.min(anim.t + dt * PLAY_RATE, anim.maxT);
  if (anim.t >= anim.maxT) anim.playing = false; // day's done; dots park at the FC
  render();
  if (anim.playing) requestAnimationFrame(tick);
}

/** Space toggles playback: start the day, pause, resume, or replay from 0. */
function togglePlay(): void {
  if (!anim) {
    const tracks = buildTracks(plan);
    const maxT = tracks.reduce((m, t) => Math.max(m, t.depart + t.total), 0);
    anim = { t: 0, maxT, playing: true, tracks };
  } else if (anim.playing) {
    anim.playing = false; // pause
  } else {
    if (anim.t >= anim.maxT) anim.t = 0; // finished → replay
    anim.playing = true;
  }
  if (anim.playing) {
    lastFrame = 0;
    requestAnimationFrame(tick);
  } else {
    render();
  }
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
  if (anim) return; // hover focus is suppressed while the day is running
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
  if (e.key === " " || e.code === "Space") {
    e.preventDefault();
    togglePlay();
  } else if (e.key === "r" || e.key === "R") {
    seed = (seed * 1664525 + 1013904223) >>> 0; // a fresh, deterministic seed
    orders = chooseOrders(seed, FLEET.orders);
    replan();
    focusTruck = null; // truck indices may not survive a re-plan
    hoverNbhd = null;
    render();
  } else if (e.key === "b" || e.key === "B") {
    balance = (balance + 1) % BALANCE_LEVELS.length; // off → low → med → high → off
    replan();
    focusTruck = null;
    hoverNbhd = null;
    render();
  }
});

render();
window.addEventListener("resize", render);
