// main.ts — entry point. Builds a full-window canvas, fits the fixed 1000x720
// logical map into it (letterboxed, DPR-aware), draws the map with the day's
// orders, reveals a neighborhood's name on hover, and reshuffles orders on R.

import { MAP_W, MAP_H, FLEET, NEIGHBORHOODS, housesOf } from "./geography.ts";
import type { Pt } from "./geography.ts";
import { chooseOrders, ordersByNeighborhood } from "./orders.ts";
import { buildSubstrate } from "./roadgraph.ts";
import { solve } from "./solver.ts";
import type { Plan, SolveFrame } from "./solver.ts";
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
let hoverHouse: string | null = null; // nearest ordered house under the cursor (`nbhd#i`)
let focusTruck: number | null = null; // truck-panel row under the cursor

// The day's deliveries. Each "shift" is a fresh random draw: S1 on load (fixed
// seed => reproducible), and S re-rolls. The number lets a particular shuffle be
// reported back ("anomaly on S4").
let seed = 49;
let shift = 1;
let solving = false; // true while the solver runs — grey the map, ignore re-presses
let orders = chooseOrders(seed, FLEET.orders);
let plan: Plan = solve(SUB, ordersByNeighborhood(orders));

// Playback: a single clock (route-minutes) advances PLAY_RATE min per real
// second, so the longest route (~200 min) plays out in ~40s. null = static map.
const PLAY_RATE = 5;
const STEP_MIN = 2; // route-minutes the ←/→ arrows nudge the clock while paused
let anim: { t: number; maxT: number; playing: boolean; tracks: Track[] } | null = null;
let lastFrame = 0;

// Solver animation: a manual stepper through the plan's recorded frames — each
// `A` advances one move, ←/→ scrub either way. Never auto-plays: the solve is
// dense and jarring at speed, so the eye sets its own pace. null = not stepping.
let solveAnim: { frames: SolveFrame[]; i: number } | null = null;

/** Leave the solver stepper, back to the static map. */
function stopSolveAnim(): void {
  solveAnim = null;
}

/** `A`: enter the stepper at the first frame, or advance one move if already in it. */
function stepSolveAnim(): void {
  if (!solveAnim) {
    anim = null; // the two animations are mutually exclusive
    solveAnim = { frames: plan.frames, i: 0 };
  } else {
    solveAnim.i = Math.min(solveAnim.frames.length - 1, solveAnim.i + 1);
  }
  render();
}

/**
 * Re-roll the day's orders and re-solve. The solver blocks for a beat — long
 * enough that you might hit the key twice — so we grey the map first (a paint the
 * browser shows before the blocking solve), defer the solve a frame, and ignore
 * re-presses until it lands.
 */
function shuffle(): void {
  if (solving) return; // already working — swallow the impatient double-tap
  solving = true;
  anim = null; // leaving any running day; the new plan would invalidate it
  stopSolveAnim(); // a new plan means new frames; drop any running solve replay
  render(); // paint the grey "shuffling…" veil before the blocking solve
  setTimeout(() => {
    seed = (seed * 1664525 + 1013904223) >>> 0; // a fresh, deterministic seed
    orders = chooseOrders(seed, FLEET.orders);
    plan = solve(SUB, ordersByNeighborhood(orders));
    shift++;
    focusTruck = null; // truck indices may not survive a re-plan
    hoverNbhd = null;
    hoverHouse = null;
    solving = false;
    render();
  }, 30);
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
  drawMap(ctx!, { orders, plan, hoverNbhd, hoverHouse, focusTruck, shift, solving, anim, solveAnim });
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
  stopSolveAnim(); // the day's playback and the solve replay don't share the screen
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

/**
 * The neighborhood under the cursor and, within it, the ordered house nearest
 * the pointer. The house matters because a split neighborhood is served by more
 * than one truck — hovering near a house should surface *that house's* truck,
 * not whichever truck happens to be first in the list.
 */
function hitTest(p: Pt): { nbhd: string | null; house: string | null } {
  let nbhd: string | null = null;
  let bestD = Infinity;
  for (const n of NEIGHBORHOODS) {
    const d = Math.hypot(p.x - n.center.x, p.y - n.center.y);
    if (d <= n.ringRadius + 18 && d < bestD) {
      bestD = d;
      nbhd = n.name;
    }
  }
  if (nbhd === null) return { nbhd: null, house: null };

  // Closest ordered house within that neighborhood (a delivered house = a truck).
  const n = NEIGHBORHOODS.find((m) => m.name === nbhd)!;
  let house: string | null = null;
  let bestH = Infinity;
  housesOf(n).forEach((h, i) => {
    const key = `${nbhd}#${i}`;
    if (!orders.has(key)) return;
    const d = Math.hypot(p.x - h.x, p.y - h.y);
    if (d < bestH) {
      bestH = d;
      house = key;
    }
  });
  return { nbhd, house };
}

canvas.addEventListener("mousemove", (e) => {
  if (solveAnim) return; // the solve replay owns the dots; no hover focus over it
  if (anim && anim.playing) return; // hover wakes up only when the day is paused
  const p = { x: (e.clientX - offX) / scale, y: (e.clientY - offY) / scale };
  // The truck panel sits on top of the map; test it first.
  const truck = truckPanelHitTest(plan, p);
  const hit = truck === null ? hitTest(p) : { nbhd: null, house: null };
  if (truck !== focusTruck || hit.nbhd !== hoverNbhd || hit.house !== hoverHouse) {
    focusTruck = truck;
    hoverNbhd = hit.nbhd;
    hoverHouse = hit.house;
    canvas.style.cursor = truck !== null || hit.nbhd ? "pointer" : "default";
    render();
  }
});

window.addEventListener("keydown", (e) => {
  if (e.key === " " || e.code === "Space") {
    e.preventDefault();
    togglePlay();
  } else if (e.key === "s" || e.key === "S") {
    shuffle(); // re-roll the day into a new shift
  } else if (e.key === "a" || e.key === "A") {
    // Step through the solver build, one move per press.
    e.preventDefault();
    stepSolveAnim();
  } else if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
    const dir = e.key === "ArrowRight" ? 1 : -1;
    if (solveAnim) {
      // Scrub the solve stepper by hand, either direction.
      e.preventDefault();
      solveAnim.i = Math.max(0, Math.min(solveAnim.frames.length - 1, solveAnim.i + dir));
      render();
      return;
    }
    // Step the day frame-by-frame. Arrows are a paused activity: a running day
    // pauses, then each press (or held key-repeat) scrubs by STEP_MIN.
    if (!anim) return;
    e.preventDefault();
    anim.playing = false;
    anim.t = Math.max(0, Math.min(anim.maxT, anim.t + dir * STEP_MIN));
    render();
  } else if (e.key === "b" || e.key === "B" || e.key === "Escape") {
    // "Back": leave whichever animation is running and return to the static map,
    // where you can see every route or hover one at a time.
    if (solveAnim) {
      stopSolveAnim();
      render();
    } else if (anim) {
      anim = null;
      render();
    }
  }
});

render();
window.addEventListener("resize", render);
