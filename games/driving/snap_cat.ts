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

const COLS = 3, ROWS = 2;
const CELL_W = 380, CELL_H = 440;
const W = COLS * CELL_W, H = ROWS * CELL_H;
const UNIT_PX = 150;       // pixels per cat-unit (full standing height)
const FOOT_FROM_BOTTOM = 56;   // ground line above each cell's bottom edge
const CAT_HEIGHT = 1.7;
const SILH_CX = 0.30;      // x of the silhouette's centre in cat-frame units, so each panel roughly centres the cat

// the contact sheet: label + the pose knobs (gait phase, head facing, leap progress, vertical hop).
const POSES: { label: string; walk: number; headFront: boolean; leapT: number; lift: number }[] = [
  { label: 'profile · rest', walk: 0, headFront: false, leapT: -1, lift: 0 },
  { label: 'profile · mid-stride', walk: Math.PI / 2, headFront: false, leapT: -1, lift: 0 },
  { label: 'frozen · head-on', walk: 0, headFront: true, leapT: -1, lift: 0 },
  { label: 'leap · coil', walk: 0, headFront: false, leapT: 0.02, lift: 0 },
  { label: 'leap · airborne', walk: 0, headFront: false, leapT: 0.45, lift: 0.42 },
  { label: 'leap · landing', walk: 0, headFront: false, leapT: 0.9, lift: 0.06 },
];

const mc = new MiniCanvas(W, H, '#202329');
const ctx = mc as unknown as Ctx;

// faint cell grid + a ground line in each cell
ctx.strokeStyle = '#3a3f48';
ctx.lineWidth = 1.5;
for (let c = 1; c < COLS; c++) { ctx.beginPath(); ctx.moveTo(c * CELL_W, 0); ctx.lineTo(c * CELL_W, H); ctx.stroke(); }
for (let r = 1; r < ROWS; r++) { ctx.beginPath(); ctx.moveTo(0, r * CELL_H); ctx.lineTo(W, r * CELL_H); ctx.stroke(); }
for (let r = 0; r < ROWS; r++) {
  const gy = r * CELL_H + CELL_H - FOOT_FROM_BOTTOM;
  ctx.beginPath(); ctx.moveTo(r === 0 ? 0 : 0, gy); ctx.lineTo(W, gy); ctx.stroke();
}

POSES.forEach((pose, i) => {
  const col = i % COLS, row = Math.floor(i / COLS);
  const cx = col * CELL_W + CELL_W / 2;
  const baseY = row * CELL_H + CELL_H - FOOT_FROM_BOTTOM;
  const project: Project = (right, _forward, height) => ({ x: cx + (right - SILH_CX) * UNIT_PX, y: baseY - (height / CAT_HEIGHT) * UNIT_PX });
  const view: CatView = { at: { right: 0, forward: 10 }, height: CAT_HEIGHT, faceRight: false, form: CAT, walk: pose.walk, headFront: pose.headFront, lift: pose.lift, leapT: pose.leapT };
  catScenery(view).drawAsNear(ctx, project);
});

mkdirSync('snap', { recursive: true });
writeFileSync('snap/cat.png', mc.toPNG());
console.log('wrote games/driving/snap/cat.png');
POSES.forEach((p, i) => console.log(`  panel ${i + 1}: ${p.label}`));
