// snap_cat.ts — render the cat IN ISOLATION to a PNG, so it can be looked at without a browser.
// Runs the REAL cat drawing code (cat_anatomy via catScenery) against the dependency-free
// MiniCanvas rasterizer and writes a contact sheet of poses to snap/cat.png. Run via ops/snap_cat.
//
// One-off exercise tool: edit the POSES list freely while iterating on the anatomy.

import { writeFileSync, mkdirSync } from 'node:fs';
import { MiniCanvas } from './mini_canvas.ts';
import { catScenery, CAT } from './cat_anatomy.ts';
import type { CatView } from './cat_anatomy.ts';
import type { Ctx, Project } from './scenery.ts';

const W = 1140, H = 440;
const CAT_HEIGHT = 1.7;
// drawCat scales the unit frame (standing height = 1) by `h` = (base.y - top.y). We drive that
// directly: UNIT_PX pixels per cat-unit, so the silhouette (head ~-0.64 … tail ~+1.14 = ~1.78 wide)
// is UNIT_PX·1.78 px across. project() must return base/top that differ by UNIT_PX over one unit.
const UNIT_PX = 170;
const BASE_Y = 372;        // the ground line (feet) in css pixels
const SILH_CX = 0.28;      // x of the silhouette's centre in cat-frame units, so each panel centres the cat

// the contact sheet: label + the two pose knobs the anatomy exposes (gait phase + head facing).
const POSES: { label: string; walk: number; headFront: boolean }[] = [
  { label: 'profile · rest', walk: 0, headFront: false },
  { label: 'profile · mid-stride', walk: Math.PI / 2, headFront: false },
  { label: 'frozen · head-on', walk: 0, headFront: true },
];

const mc = new MiniCanvas(W, H, '#202329');
const ctx = mc as unknown as Ctx;
const cols = POSES.length;
const colW = W / cols;

// a faint ground line + column separators (drawn at the base transform, css pixels)
ctx.strokeStyle = '#3a3f48';
ctx.lineWidth = 1.5;
ctx.beginPath();
ctx.moveTo(0, BASE_Y); ctx.lineTo(W, BASE_Y); ctx.stroke();
for (let i = 1; i < cols; i++) { ctx.beginPath(); ctx.moveTo(i * colW, 0); ctx.lineTo(i * colW, H); ctx.stroke(); }

POSES.forEach((pose, i) => {
  const cx = colW * (i + 0.5);
  const project: Project = (right, _forward, height) => ({ x: cx + (right - SILH_CX) * UNIT_PX, y: BASE_Y - (height / CAT_HEIGHT) * UNIT_PX });
  const view: CatView = { at: { right: 0, forward: 10 }, height: CAT_HEIGHT, faceRight: false, form: CAT, walk: pose.walk, headFront: pose.headFront };
  catScenery(view).drawAsNear(ctx, project);
});

mkdirSync('snap', { recursive: true });
writeFileSync('snap/cat.png', mc.toPNG());
console.log('wrote games/driving/snap/cat.png');
POSES.forEach((p, i) => console.log(`  panel ${i + 1}: ${p.label}`));
