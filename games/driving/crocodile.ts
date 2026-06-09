// crocodile.ts — the crocodile corner: a little lagoon just BEYOND a (right-turn) intersection, off to
// its LEFT, with four crocodile emoji wading at the near bank, each half-submerged behind a wavy
// waterline. safari_critter.ts hands off to this module when a corner's creature is CROCODILE.
//
// Authored in the CORNER frame the intersection hands us: cu = metres across from the road's end-left
// corner (0 = left edge, + = toward the road, so the lagoon's cu is NEGATIVE, out to the left), cv =
// metres beyond the end edge (+ = past the intersection). The emoji reuse critter.ts's sprite cache.

import { emojiSprite } from './critter.ts';
import type { Project, Ctx, Scenery, Quad, RiderPt } from './scenery.ts';

// ---- types ----

// maps a corner-frame point (cu across, cv beyond) into the Rider's frame.
export type CornerMap = (cu: number, cv: number) => RiderPt;
type P = readonly [number, number];

// ---- constants ----

// the lagoon outline, corner-frame metres: an irregular blob on the LEFT of the road, reaching ~12m
// beyond the end edge and ~15m across.
const LAGOON: P[] = [
  [-1.2, 3], [-5, 2], [-11, 2.4], [-16, 3.6], [-16.5, 9], [-13, 14.5], [-7, 15], [-2.2, 12.5], [-0.7, 7],
];
const LAGOON_WATER = '#2f7e8c';

// the four crocs along the near bank: corner-frame anchors (cu, cv), spread across the width and
// staggered slightly in depth so they overlap cleanly; all face the same way (toward the road).
const CROC_BANK: P[] = [[-3.5, 3.4], [-7.5, 3.8], [-11.5, 4.3], [-15.5, 4.8]];
const CROC_EMOJI = '🐊';
const CROC_FACE_RIGHT = true;       // all four face the road

const CROC_ADULT_HEIGHT = 1.4;      // metres
const CROC_GIANT_SCALE = 1.7;       // late-route corners upsize, like the other safari critters...
const CROC_GIANT_FROM_SEG = 8;      // ...on segments numbered above this

// the waterline that half-submerges each croc: water (lagoon colour) over the bottom WATER_RISE of the
// sprite, with a few small WAVE_AMP bumps along the top.
const WATER_RISE = 0.42;            // fraction of the sprite height that's underwater
const WAVE_AMP = 0.035;             // wave height (sprite-height units) — small
const WAVE_COUNT = 5;

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
  if (h < 1) return;

  ctx.save();
  ctx.translate(base.x, base.y);
  if (CROC_FACE_RIGHT) ctx.scale(-1, 1);                      // emoji faces left; flip to face the road
  ctx.drawImage(emojiSprite(CROC_EMOJI), -h / 2, -h, h, h);   // square, bottom on the bank

  // the waterline: fill the bottom WATER_RISE of the sprite with lagoon water, a small zig-zag of
  // waves along the top — so the croc reads as half in the lagoon, half on the bank.
  ctx.fillStyle = LAGOON_WATER;
  ctx.beginPath();
  ctx.moveTo(-h / 2, 0);
  for (let i = 0; i <= WAVE_COUNT; i++) {
    const x = -h / 2 + (h * i) / WAVE_COUNT;
    const y = -WATER_RISE * h + (i % 2 ? -WAVE_AMP * h : WAVE_AMP * h);
    ctx.lineTo(x, y);
  }
  ctx.lineTo(h / 2, 0);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}
