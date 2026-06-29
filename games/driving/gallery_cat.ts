// gallery_cat.ts — a ONE-TIME hero render of the safari cat for the home-page
// gallery (gallery/safari.png), run via ops/gallery_cat. Like snap_cat.ts it runs
// the REAL cat drawing code (cat_anatomy via catScenery) against the dependency-free
// MiniCanvas rasterizer — but it composes a single, dusk-lit leaping cat sized for a
// card, rather than the contact sheet of poses. Stylized, not a screenshot: faithful
// because it IS the app's cat code, and it can't go stale the way a capture would.
//
// Re-run whenever the cat anatomy changes; the PNG is committed (it's content, not a
// build artifact). Tune the pose + palette below.

import { writeFileSync } from 'node:fs';
import { MiniCanvas } from './mini_canvas.ts';
import { catScenery, CAT } from './cat_anatomy.ts';
import type { CatView } from './cat_anatomy.ts';
import type { Ctx, Project } from './scenery.ts';

const W = 600, H = 420;
const GROUND_Y = 322;          // the road line the cat leaps over
const UNIT_PX = 150;           // pixels per cat-unit (full standing height)
const CAT_HEIGHT = 1.7;
const SILH_CX = 0.30;          // x of the silhouette's centre, cat-frame units
const CX = 330;                // a touch right of centre — the cat faces left, so leave it room ahead

// dusk palette — evokes the app's signature sunset without importing its staging.
const SKY_TOP = '#181f3a';     // deep dusk blue overhead
const SKY_HORIZON = '#d8743a'; // warm band at the horizon
const ROAD = '#23222b';        // dusk asphalt
const ROAD_EDGE = '#3a3947';
const LANE = '#b9a86a';        // faded centre line

function lerpHex(a: string, b: string, t: number): string {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  const c = pa.map((v, i) => Math.round(v + (pb[i] - v) * t));
  return '#' + c.map((v) => v.toString(16).padStart(2, '0')).join('');
}

const mc = new MiniCanvas(W, H, SKY_TOP);
const ctx = mc as unknown as Ctx;

// Sky: a banded vertical gradient (MiniCanvas has no gradient fill, so step it),
// from the deep overhead blue down to a warm horizon glow at the road line.
const BANDS = 64;
for (let i = 0; i < BANDS; i++) {
  const y0 = (GROUND_Y * i) / BANDS;
  const y1 = (GROUND_Y * (i + 1)) / BANDS;
  ctx.fillStyle = lerpHex(SKY_TOP, SKY_HORIZON, (i / (BANDS - 1)) ** 1.6);
  ctx.fillRect(0, y0, W, y1 - y0 + 1);
}

// Road: a dusk-asphalt band below the horizon, a lighter shoulder edge, and a faded
// dashed centre line running to a vanishing point — just enough to read as "the road".
ctx.fillStyle = ROAD;
ctx.fillRect(0, GROUND_Y, W, H - GROUND_Y);
ctx.fillStyle = ROAD_EDGE;
ctx.fillRect(0, GROUND_Y, W, 2);
ctx.fillStyle = LANE;
for (let i = 0; i < 5; i++) {
  const t = i / 5;
  const y = GROUND_Y + 8 + t * (H - GROUND_Y - 8);
  const w = 3 + t * 12, dash = 6 + t * 22;
  ctx.fillRect(W / 2 - w / 2, y, w, dash);
}

// The cat — a grounded mid-stride profile, facing left, planted on the road. (The
// airborne leap pose reads as "floating" out of motion; a walking profile is the
// most legible single still — unmistakably the cat, on its feet, at dusk.)
const project: Project = (right, _forward, height) => ({
  x: CX + (right - SILH_CX) * UNIT_PX,
  y: GROUND_Y - (height / CAT_HEIGHT) * UNIT_PX,
});
const view: CatView = {
  at: { right: 0, forward: 10 },
  height: CAT_HEIGHT,
  faceRight: false,
  form: CAT,
  walk: Math.PI / 2,   // mid-stride — legs clearly striding, not tucked
  headFront: false,
  lift: 0,
  leapT: -1,           // no leap — grounded
};
catScenery(view).drawAsNear(ctx, project);

writeFileSync('../../gallery/safari.png', mc.toPNG());
console.log('wrote gallery/safari.png');
