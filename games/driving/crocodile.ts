// crocodile.ts — the crocodile corner: a little lagoon just BEYOND a (right-turn) intersection, off to
// its LEFT, with four adult crocodiles hauled out side-by-side on the near bank, each half in the water
// and half on the ground. Hand-drawn (no emoji) in profile, like the cat. safari_critter.ts hands off
// to this module when a corner's creature is CROCODILE.
//
// Everything is authored in the CORNER frame the intersection hands us: cu = metres across from the
// road's end-left corner (0 = left edge, + = toward/across the road, so the lagoon's cu is NEGATIVE,
// out to the left), cv = metres beyond the end edge (+ = past the intersection). The crocs themselves
// live in a unit frame standing `height` tall (feet on y = 0), facing LEFT (snout at -x, tail at +x).

import type { Project, Ctx, Scenery, Quad, RiderPt } from './scenery.ts';

// ---- types ----

// maps a corner-frame point (cu across, cv beyond) into the Rider's frame.
export type CornerMap = (cu: number, cv: number) => RiderPt;

type P = readonly [number, number];

// ---- constants ----

// the lagoon outline, corner-frame metres: an irregular blob on the LEFT of the road, just beyond the
// end edge, roughly 15m across.
const LAGOON: P[] = [
  [-1, 8], [-2.5, 4.8], [-6, 3.2], [-12, 3.6], [-16, 6], [-15.5, 12], [-10, 15.5], [-4, 14.5], [-1.2, 11],
];
const LAGOON_WATER = '#2f7e8c';

// the four crocs on the near bank: corner-frame anchors (cu, cv), staggered slightly in depth so they
// overlap cleanly, all facing the same way (toward the road).
const CROC_BANK: P[] = [[-4, 4.6], [-7.5, 4.9], [-11, 5.3], [-14.5, 5.9]];
const CROC_FACE_RIGHT = true;       // all four face the road

const CROC_ADULT_HEIGHT = 0.9;      // metres — back height of the lying croc (length is ~4.7x this)
const CROC_GIANT_SCALE = 1.7;       // late-route corners upsize, like the other safari critters...
const CROC_GIANT_FROM_SEG = 8;      // ...on segments numbered above this

// croc palette
const CROC_BACK = '#3b6b35';        // dark green back
const CROC_BELLY = '#8aa06a';       // pale olive belly
const CROC_LINE = '#21401d';        // outline
const CROC_EYE_RING = '#c9b86a';    // yellow eye
const CROC_EYE = '#15110a';         // slit pupil
const CROC_TEETH = '#f2efe2';

const LINE_WIDTH = 0.03;            // outline weight, in croc-height units

// the croc silhouette (snout -> back -> tail along the top, then belly back to the snout).
const BODY: P[] = [
  [-2.30, 0.16], [-1.70, 0.27], [-1.15, 0.40], [-0.95, 0.54], [-0.70, 0.50], [-0.20, 0.60],
  [0.50, 0.60], [1.10, 0.50], [1.70, 0.32], [2.30, 0.12],
  [2.30, 0.06], [1.60, 0.02], [0.50, 0.00], [-0.50, 0.00], [-1.20, 0.05], [-1.95, 0.11],
];
const BELLY: P[] = [[-1.60, 0.10], [-0.50, 0.00], [0.60, 0.00], [1.40, 0.05], [0.60, 0.12], [-0.50, 0.12]];
const BACK_BUMPS = [-0.25, 0.15, 0.55, 0.95];   // x of each spine triangle
const LEGS = [-0.5, 0.95];                       // x of each (webbed) foot
// the waterline: water (lagoon colour) over the TAIL half, with a wavy top — submerges the rear body
// and back leg, leaving the head and front leg on the bank.
const WATER_OVER_TAIL: P[] = [
  [0.15, 0.00], [0.28, 0.40], [0.70, 0.32], [1.10, 0.40], [1.60, 0.30], [2.10, 0.30], [2.40, 0.22], [2.40, 0.00],
];

// ---- functions ----

// The crocodile corner scene: the lagoon (a ground quad) plus the four crocs (depth-sorted scenery).
export function crocodileScene(corner: CornerMap, segNum: number): { quads: Quad[]; scenery: Scenery[] } {
  const height = CROC_ADULT_HEIGHT * (segNum > CROC_GIANT_FROM_SEG ? CROC_GIANT_SCALE : 1);
  const lagoon: Quad = { pts: LAGOON.map(([cu, cv]) => corner(cu, cv)), color: LAGOON_WATER };
  const scenery = CROC_BANK.map(([cu, cv]) => crocScenery(corner(cu, cv), height));
  return { quads: [lagoon], scenery };
}

function crocScenery(at: RiderPt, height: number): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawCroc(ctx, at, height, project);
  return { forward: at.forward, height, drawAsNear: draw, drawAsFar: draw };
}

function drawCroc(ctx: Ctx, at: RiderPt, height: number, project: Project): void {
  const base = project(at.right, at.forward, 0);
  const top = project(at.right, at.forward, height);
  const h = base.y - top.y;
  if (h < 2) return;
  ctx.save();
  ctx.translate(base.x, base.y);
  if (CROC_FACE_RIGHT) ctx.scale(-1, 1);   // drawn facing LEFT; flip to face right
  ctx.scale(h, -h);
  ctx.lineWidth = LINE_WIDTH;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  paintCroc(ctx);
  ctx.restore();
}

function polyPath(ctx: Ctx, pts: P[]): void {
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.closePath();
}

function paintCroc(ctx: Ctx): void {
  ctx.strokeStyle = CROC_LINE;
  ctx.fillStyle = CROC_BACK;

  for (const lx of LEGS) {   // webbed feet, behind the body
    ctx.beginPath();
    ctx.moveTo(lx - 0.10, 0.13);
    ctx.lineTo(lx + 0.20, 0.10);
    ctx.lineTo(lx + 0.24, 0.00); ctx.lineTo(lx + 0.16, 0.05);
    ctx.lineTo(lx + 0.12, 0.00); ctx.lineTo(lx + 0.05, 0.05);
    ctx.lineTo(lx + 0.01, 0.00);
    ctx.closePath();
    ctx.fill(); ctx.stroke();
  }

  polyPath(ctx, BODY); ctx.fillStyle = CROC_BACK; ctx.fill(); ctx.stroke();   // the body silhouette

  polyPath(ctx, BELLY); ctx.fillStyle = CROC_BELLY; ctx.fill();               // pale belly

  ctx.fillStyle = CROC_BACK;                                                   // spine ridge bumps
  for (const bx of BACK_BUMPS) {
    ctx.beginPath();
    ctx.moveTo(bx - 0.13, 0.57); ctx.lineTo(bx + 0.13, 0.57); ctx.lineTo(bx, 0.74);
    ctx.closePath(); ctx.fill(); ctx.stroke();
  }

  ctx.fillStyle = CROC_EYE_RING;                                              // eye: yellow ring + slit pupil
  ctx.beginPath(); ctx.arc(-0.95, 0.55, 0.075, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = CROC_EYE;
  ctx.beginPath(); ctx.ellipse(-0.95, 0.55, 0.026, 0.06, 0, 0, Math.PI * 2); ctx.fill();

  ctx.fillStyle = CROC_LINE;                                                  // nostril at the snout tip
  ctx.beginPath(); ctx.arc(-2.13, 0.21, 0.035, 0, Math.PI * 2); ctx.fill();

  ctx.strokeStyle = CROC_LINE;                                               // the long closed mouth line
  ctx.beginPath(); ctx.moveTo(-2.28, 0.13); ctx.lineTo(-1.2, 0.17); ctx.lineTo(-0.6, 0.25); ctx.stroke();
  ctx.fillStyle = CROC_TEETH;                                                // a few teeth along the snout
  for (const tx of [-2.0, -1.7, -1.4, -1.1]) {
    ctx.beginPath();
    ctx.moveTo(tx - 0.05, 0.155); ctx.lineTo(tx + 0.05, 0.155); ctx.lineTo(tx, 0.075);
    ctx.closePath(); ctx.fill();
  }

  polyPath(ctx, WATER_OVER_TAIL); ctx.fillStyle = LAGOON_WATER; ctx.fill();  // the tail half is underwater
}
