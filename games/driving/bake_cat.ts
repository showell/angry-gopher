// bake_cat.ts — bake the cat's named-pose stills into hard-coded polygons for the zig→WASM port.
//
// The WASM seam to the blitter is POLYGON-ONLY (no stroke, no arc-fill, no curve), but the cat's real
// drawing code (cat_anatomy.ts) is heavily procedural — Catmull-Rom splines, tapered capsules with
// quadratic end-caps, circle-union snouts, FK leg chains, plus strokes for whiskers/mouth/outlines.
// Rather than re-implement all that in zig, we run the REAL cat code once per named pose against a
// PolyRecorder — a Ctx shim that captures every fill() as a filled polygon and every stroke() as thin
// filled quads — and dump the result as a flat polygon table in games/driving/wasm/cat_frames.zig. The
// port just transforms + blits those stills (a flipbook, one locked to each crossing step).
//
// The cat is a FLIPBOOK of 7 named poses (the snap_cat contact-sheet set), selected per step with no
// interpolation; the lateral travel + vertical hop are added at runtime by cat.zig's choreography, so
// every pose is baked at the cat's resting anchor (lift 0), facing LEFT, in the unit frame (feet at
// y = 0, y up, standing height 1, x toward the tail).
//
// Run via ops/bake_cat. cat_frames.zig is GENERATED + committed (like a gold file); re-run after any
// change to cat_anatomy.ts. A validation contact sheet is written to snap/cat_baked.png — it must look
// like snap/cat.png (same code, replayed through the recorded polygons instead of the rasterizer).

import { writeFileSync, mkdirSync } from 'node:fs';
import { MiniCanvas } from './mini_canvas.ts';
import { catScenery, CAT } from './cat_anatomy.ts';
import type { CatView } from './cat_anatomy.ts';
import type { Ctx, Project } from './scenery.ts';

type Pt = [number, number];
interface Poly { color: string; pts: Pt[] }

// tessellation density — kept identical to mini_canvas.ts so the recorded polygons match what the
// rasterizer (and the live browser canvas) would draw.
const QUAD_SEGS = 14;
const ARC_SEGS = 64;

const quadAt = (p0: Pt, p1: Pt, p2: Pt, t: number): Pt => {
  const u = 1 - t;
  return [u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]];
};

// A stroked polyline as ONE fillable ribbon polygon (not N per-segment quads — that exploded the count):
// offset every vertex ±w along its averaged edge-normal, trace the outer side forward then the inner side
// BACKWARD. Under nonzero winding this fills a band centred on the path; for a CLOSED path the reversed
// inner loop winds opposite the outer, so the interior cancels and it renders as a proper ring (a thin
// outline) — exactly what canvas stroke draws. Sign of the normal is irrelevant: ±w is symmetric, so the
// band stays centred whatever the path's orientation.
function ribbon(pts: Pt[], closed: boolean, w: number): Pt[] {
  const n = pts.length;
  const edgeN: Pt[] = [];   // left-normal of each segment i→i+1
  for (let i = 0; i < n - 1; i++) {
    const dx = pts[i + 1][0] - pts[i][0], dy = pts[i + 1][1] - pts[i][1];
    const len = Math.hypot(dx, dy) || 1e-6;
    edgeN.push([-dy / len, dx / len]);
  }
  const vnorm = (i: number): Pt => {
    const a = closed ? edgeN[(i - 1 + edgeN.length) % edgeN.length] : edgeN[Math.max(0, i - 1)];
    const b = closed ? edgeN[i % edgeN.length] : edgeN[Math.min(edgeN.length - 1, i)];
    let nx = a[0] + b[0], ny = a[1] + b[1];
    const len = Math.hypot(nx, ny) || 1e-6;
    return [nx / len, ny / len];
  };
  const outer: Pt[] = [], inner: Pt[] = [];
  for (let i = 0; i < n; i++) {
    const [nx, ny] = vnorm(i);
    outer.push([pts[i][0] + nx * w, pts[i][1] + ny * w]);
    inner.push([pts[i][0] - nx * w, pts[i][1] - ny * w]);
  }
  return [...outer, ...inner.reverse()];
}

// PolyRecorder — implements the slice of CanvasRenderingContext2D that cat_anatomy uses, capturing
// transformed polygons instead of rasterizing. The matrix [a,b,c,d,e,f] maps user→output exactly as the
// canvas does (device = (a·x + c·y + e, b·x + d·y + f)); we start at identity so the captured coordinates
// are whatever drawCat's own translate/scale produce (with our unit-frame project: x = unit-x toward the
// tail, y = −unit-y, i.e. y points DOWN — flipped back to y-up when we dump).
class PolyRecorder {
  m: [number, number, number, number, number, number] = [1, 0, 0, 1, 0, 0];
  fillStyle = '#000';
  strokeStyle = '#000';
  lineWidth = 1;
  lineJoin = 'round';
  lineCap = 'round';
  polys: Poly[] = [];

  private stack: { m: PolyRecorder['m']; fillStyle: string; strokeStyle: string; lineWidth: number }[] = [];
  private subs: Pt[][] = [];
  private sub: Pt[] | null = null;
  private curUser: Pt | null = null;

  // ---- transform ----
  save(): void { this.stack.push({ m: [...this.m], fillStyle: this.fillStyle, strokeStyle: this.strokeStyle, lineWidth: this.lineWidth }); }
  restore(): void { const s = this.stack.pop(); if (s) { this.m = s.m; this.fillStyle = s.fillStyle; this.strokeStyle = s.strokeStyle; this.lineWidth = s.lineWidth; } }
  translate(tx: number, ty: number): void { const [a, b, c, d, e, f] = this.m; this.m = [a, b, c, d, e + a * tx + c * ty, f + b * tx + d * ty]; }
  scale(sx: number, sy: number): void { const [a, b, c, d, e, f] = this.m; this.m = [a * sx, b * sx, c * sy, d * sy, e, f]; }
  rotate(r: number): void {
    const cos = Math.cos(r), sin = Math.sin(r);
    const [a, b, c, d, e, f] = this.m;
    this.m = [a * cos + c * sin, b * cos + d * sin, c * cos - a * sin, d * cos - b * sin, e, f];
  }
  private apply(x: number, y: number): Pt { const [a, b, c, d, e, f] = this.m; return [a * x + c * y + e, b * x + d * y + f]; }
  private scaleFactor(): number { const [a, b, c, d] = this.m; return Math.sqrt(Math.abs(a * d - b * c)); }

  // ---- path ----
  beginPath(): void { this.subs = []; this.sub = null; this.curUser = null; }
  moveTo(x: number, y: number): void { this.sub = [this.apply(x, y)]; this.subs.push(this.sub); this.curUser = [x, y]; }
  lineTo(x: number, y: number): void { if (!this.sub) { this.moveTo(x, y); return; } this.sub.push(this.apply(x, y)); this.curUser = [x, y]; }
  quadraticCurveTo(cx: number, cy: number, x: number, y: number): void {
    const p0 = this.curUser ?? [x, y];
    for (let i = 1; i <= QUAD_SEGS; i++) { const p = quadAt(p0, [cx, cy], [x, y], i / QUAD_SEGS); this.lineTo(p[0], p[1]); }
    this.curUser = [x, y];
  }
  arc(cx: number, cy: number, r: number, a0: number, a1: number, ccw = false): void {
    let span = a1 - a0;
    if (ccw && span > 0) span -= Math.PI * 2;
    if (!ccw && span < 0) span += Math.PI * 2;
    const n = Math.max(2, Math.ceil((Math.abs(span) / (Math.PI * 2)) * ARC_SEGS));
    for (let i = 0; i <= n; i++) {
      const a = a0 + span * (i / n);
      const x = cx + r * Math.cos(a), y = cy + r * Math.sin(a);
      if (i === 0 && !this.sub) this.moveTo(x, y); else this.lineTo(x, y);
    }
  }
  ellipse(cx: number, cy: number, rx: number, _ry: number, _rot: number, a0: number, a1: number, ccw = false): void {
    this.arc(cx, cy, rx, a0, a1, ccw);   // cat_anatomy only ever calls ellipse with rx === ry (a circle)
  }
  closePath(): void { if (this.sub && this.sub.length) this.sub.push([...this.sub[0]]); }

  // ---- paint ----
  fill(): void { for (const sp of this.subs) if (sp.length >= 3) this.polys.push({ color: this.fillStyle, pts: sp.map((p): Pt => [p[0], p[1]]) }); }
  stroke(): void {
    const w = (this.lineWidth * this.scaleFactor()) / 2;   // half-width in output units
    if (w <= 0) return;
    for (const sp of this.subs) {
      if (sp.length < 2) continue;
      const last = sp[sp.length - 1];
      const closed = sp.length > 2 && Math.hypot(last[0] - sp[0][0], last[1] - sp[0][1]) < 1e-6;
      const path = closed ? sp.slice(0, -1) : sp;   // drop the duplicate closing point
      this.polys.push({ color: this.strokeStyle, pts: ribbon(path, closed, w) });
    }
  }
}

// the 7 named poses — the snap_cat contact-sheet set, but baked at lift 0 (the hop is a runtime
// translate in cat.zig, not part of the still). Order is the flipbook index cat.zig selects by.
const POSES: { name: string; walk: number; headFront: boolean; leapT: number }[] = [
  { name: 'rest', walk: 0, headFront: false, leapT: -1 },
  { name: 'stride', walk: Math.PI / 2, headFront: false, leapT: -1 },
  { name: 'frozen', walk: 0, headFront: true, leapT: -1 },
  { name: 'coil', walk: 0, headFront: false, leapT: 0.1 },
  { name: 'flight', walk: 0, headFront: false, leapT: 0.4 },
  { name: 'land', walk: 0, headFront: false, leapT: 0.8 },
  { name: 'collapse', walk: 0, headFront: false, leapT: 1.0 },
];

const CAT_HEIGHT = 1.7;

// drawCat culls anything under 2px tall ("too small to detail"), so capture at UNIT_SCALE px per
// standing-height and divide back out — the captured coordinates are then in the unit frame. The project
// makes base = (0,0) and the projected height = UNIT_SCALE; drawCat applies scale(h, −h), flipping y to
// point DOWN (flipped back to up on dump).
const UNIT_SCALE = 100;
const unitProject: Project = (_right, _forward, height) => ({ x: 0, y: -(height / CAT_HEIGHT) * UNIT_SCALE });

// hex '#rrggbb' (or '#rgb') → 0xRRGGBB.
function hexToU32(s: string): number {
  let hex = s.replace('#', '');
  if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
  return parseInt(hex, 16) >>> 0;
}

const round = (n: number): number => Math.round(n * 1e4) / 1e4;

// record one pose's polygons in the unit frame (y flipped back to up).
function bakePose(walk: number, headFront: boolean, leapT: number): Poly[] {
  const rec = new PolyRecorder();
  const view: CatView = { at: { right: 0, forward: 10 }, height: CAT_HEIGHT, faceRight: false, form: CAT, walk, headFront, lift: 0, leapT };
  catScenery(view).drawAsNear(rec as unknown as Ctx, unitProject);
  return rec.polys.map((p) => ({ color: p.color, pts: p.pts.map(([x, y]): Pt => [round(x / UNIT_SCALE), round(-y / UNIT_SCALE)]) }));
}

const baked = POSES.map((p) => ({ ...p, polys: bakePose(p.walk, p.headFront, p.leapT) }));

// ---- emit cat_frames.zig ----
const lines: string[] = [];
lines.push('//! cat_frames — GENERATED by ops/bake_cat from cat_anatomy.ts. DO NOT EDIT BY HAND.');
lines.push('//!');
lines.push('//! The crossing cat as a FLIPBOOK of named-pose stills: each pose is a flat list of filled');
lines.push('//! polygons in the cat\'s UNIT FRAME (feet at y = 0, y up, standing height 1, x toward the tail,');
lines.push('//! facing LEFT). cat.zig selects a pose per crossing step and transforms its polygons to the');
lines.push('//! screen (scaled by the projected height, offset to the anchor, hopped by the leap lift). The');
lines.push('//! seam is polygon-only, so cat_anatomy\'s fills are baked as polygons and its strokes as thin');
lines.push('//! quads — see bake_cat.ts. Colours are 0xRRGGBB, straight from the CAT palette.');
lines.push('');
lines.push('pub const Pt = struct { x: f32, y: f32 };');
lines.push('pub const Poly = struct { color: u32, pts: []const Pt };');
lines.push('pub const Pose = struct { polys: []const Poly };');
lines.push('');
baked.forEach((pose, i) => {
  lines.push(`// pose ${i}: ${pose.name} — ${pose.polys.length} polygons`);
  lines.push(`const pose_${pose.name} = [_]Poly{`);
  for (const poly of pose.polys) {
    const pts = poly.pts.map(([x, y]) => `.{ .x = ${x}, .y = ${y} }`).join(', ');
    lines.push(`    .{ .color = 0x${hexToU32(poly.color).toString(16).padStart(6, '0')}, .pts = &[_]Pt{ ${pts} } },`);
  }
  lines.push('};');
  lines.push('');
});
lines.push('pub const POSES = [_]Pose{');
for (const pose of baked) lines.push(`    .{ .polys = &pose_${pose.name} },`);
lines.push('};');
lines.push('');
// named indices so cat.zig reads by name, not magic numbers.
baked.forEach((pose, i) => lines.push(`pub const ${pose.name.toUpperCase()}: usize = ${i};`));
lines.push('');

writeFileSync('wasm/cat_frames.zig', lines.join('\n'));
const totalPolys = baked.reduce((n, p) => n + p.polys.length, 0);
console.log(`wrote games/driving/wasm/cat_frames.zig (${baked.length} poses, ${totalPolys} polygons)`);
baked.forEach((p, i) => console.log(`  pose ${i}: ${p.name} (${p.polys.length} polys)`));

// ---- validation contact sheet: replay the RECORDED polygons through MiniCanvas ----
// If cat_frames.zig is faithful this looks like snap/cat.png (same shapes, reconstructed from the table).
const COLS = 4, ROWS = 2, CELL_W = 340, CELL_H = 440, UNIT_PX = 140, FOOT_FROM_BOTTOM = 56, SILH_CX = 0.3;
const W = COLS * CELL_W, H = ROWS * CELL_H;
const mc = new MiniCanvas(W, H, '#202329');
const vctx = mc as unknown as { fillStyle: string; beginPath(): void; moveTo(x: number, y: number): void; lineTo(x: number, y: number): void; closePath(): void; fill(): void };
baked.forEach((pose, i) => {
  const col = i % COLS, row = Math.floor(i / COLS);
  const cx = col * CELL_W + CELL_W / 2;
  const baseY = row * CELL_H + CELL_H - FOOT_FROM_BOTTOM;
  for (const poly of pose.polys) {
    vctx.fillStyle = poly.color;
    vctx.beginPath();
    poly.pts.forEach(([x, y], k) => {
      const sx = cx + (x - SILH_CX) * UNIT_PX;
      const sy = baseY - y * UNIT_PX;   // y is up in the dumped frame
      if (k === 0) vctx.moveTo(sx, sy); else vctx.lineTo(sx, sy);
    });
    vctx.closePath();
    vctx.fill();
  }
});
mkdirSync('snap', { recursive: true });
writeFileSync('snap/cat_baked.png', mc.toPNG());
console.log('wrote games/driving/snap/cat_baked.png (validation — should match snap/cat.png)');
