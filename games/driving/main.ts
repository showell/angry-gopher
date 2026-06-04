// =============================================================================
// driving — the smallest possible world
//
//   axes of difficulty (deliberately tiny for now):
//   - one-lane roads (~2 car widths) + trees. nothing else.
//   - straight, axis-aligned (N/S or E/W) segments; square intersections.
//   - trees are radially symmetric: only distance + angle to the car matter.
//   - the car self-drives ON RAILS: the route is a list of 2D frames (poses);
//     ArrowUp = next frame, ArrowDown = previous frame.
//
// Built with ./build (esbuild -> app.js). Typecheck: npm run typecheck.
// Vocabulary comes from types.ts; this prototype uses the slice it needs.
// =============================================================================
import type { Cardinal } from './types.ts';

// ---- canvas ----
const canvas = document.getElementById('c') as HTMLCanvasElement;
const ctx = canvas.getContext('2d') as CanvasRenderingContext2D;
const W = canvas.width;
const H = canvas.height;

// ---- constants (metres) ----
const CAR_W = 2;
const LANE = 2 * CAR_W;     // a one-lane road is about two car widths wide
const HALF = LANE / 2;      // road half-width
const CORNER_R = HALF;      // turn radius — fits inside the square intersection
const TREE_H = 5;
const STEP = 1.2;           // metres advanced per forward press (~100 for 3 segs)

// ---- camera ----
const FOV = 70;
const FOCAL = (W / 2) / Math.tan((FOV / 2) * Math.PI / 180);
const NEAR = 0.4;
const EYE_H = 1.2;          // driver eye level

// ---- the world: a chain of straight, axis-aligned legs ----
interface Leg { name: string; dir: Cardinal; len: number }
const DIRV: Record<Cardinal, [number, number]> = { N: [0, 1], E: [1, 0], S: [0, -1], W: [-1, 0] };
const DIRH: Record<Cardinal, number> = { N: 0, E: Math.PI / 2, S: Math.PI, W: -Math.PI / 2 };

const LEGS: Leg[] = [
  { name: 'Segment 1', dir: 'N', len: 40 },
  { name: 'Segment 2', dir: 'E', len: 40 },
  { name: 'Segment 3', dir: 'N', len: 40 },
];

// centreline vertices (corner points)
const V: Array<[number, number]> = [[0, 0]];
for (const leg of LEGS) {
  const d = DIRV[leg.dir];
  const p = V[V.length - 1];
  V.push([p[0] + d[0] * leg.len, p[1] + d[1] * leg.len]);
}

// ---- pavement: a rectangle per leg + a square at each intersection ----
interface Rect { x1: number; z1: number; x2: number; z2: number }
const pavement: Rect[] = [];
for (let i = 0; i < LEGS.length; i++) {
  const a = V[i], b = V[i + 1];
  if (a[0] === b[0]) {  // vertical (N/S)
    pavement.push({ x1: a[0] - HALF, z1: Math.min(a[1], b[1]), x2: a[0] + HALF, z2: Math.max(a[1], b[1]) });
  } else {              // horizontal (E/W)
    pavement.push({ x1: Math.min(a[0], b[0]), z1: a[1] - HALF, x2: Math.max(a[0], b[0]), z2: a[1] + HALF });
  }
}
for (let i = 1; i < V.length - 1; i++) {  // square intersections
  const v = V[i];
  pavement.push({ x1: v[0] - HALF, z1: v[1] - HALF, x2: v[0] + HALF, z2: v[1] + HALF });
}

// ---- trees beside each leg (radially symmetric: position is all we keep) ----
interface Tree { x: number; z: number }
const trees: Tree[] = [];
for (let i = 0; i < LEGS.length; i++) {
  const a = V[i];
  const d = DIRV[LEGS[i].dir];
  const perp: [number, number] = [-d[1], d[0]];
  const off = HALF + 1.5;
  for (let along = 4; along <= LEGS[i].len - 4; along += 6) {
    const cx = a[0] + d[0] * along;
    const cz = a[1] + d[1] * along;
    trees.push({ x: cx + perp[0] * off, z: cz + perp[1] * off });
    trees.push({ x: cx - perp[0] * off, z: cz - perp[1] * off });
  }
}

// ---- the rail: precomputed frames (poses) along the centreline ----
interface Pose { x: number; z: number; h: number; where: string }
const frames: Pose[] = [];
{
  const s = { x: V[0][0], z: V[0][1], h: DIRH[LEGS[0].dir] };
  let where = LEGS[0].name;
  frames.push({ x: s.x, z: s.z, h: s.h, where });

  const straight = (dir: Cardinal, len: number): void => {
    const d = DIRV[dir];
    let t = 0;
    while (t < len - 1e-6) {
      const st = Math.min(STEP, len - t);
      s.x += d[0] * st; s.z += d[1] * st; t += st;
      frames.push({ x: s.x, z: s.z, h: s.h, where });
    }
  };
  const arc = (sign: number, R: number): void => {
    const total = (Math.PI / 2) * R;
    let t = 0;
    while (t < total - 1e-6) {
      const st = Math.min(STEP, total - t);
      s.h += sign * (st / R);
      s.x += Math.sin(s.h) * st; s.z += Math.cos(s.h) * st; t += st;
      frames.push({ x: s.x, z: s.z, h: s.h, where });
    }
    s.h = Math.round(s.h / (Math.PI / 2)) * (Math.PI / 2);  // snap to a clean cardinal
  };
  const turnSign = (a: Cardinal, b: Cardinal): number => {
    let dh = DIRH[b] - DIRH[a];
    while (dh > Math.PI) dh -= 2 * Math.PI;
    while (dh < -Math.PI) dh += 2 * Math.PI;
    return dh > 0 ? 1 : -1;
  };

  for (let i = 0; i < LEGS.length; i++) {
    const entry = i > 0 ? CORNER_R : 0;
    const exit = i < LEGS.length - 1 ? CORNER_R : 0;
    where = LEGS[i].name;
    straight(LEGS[i].dir, LEGS[i].len - entry - exit);
    if (i < LEGS.length - 1) {
      where = 'Intersection ' + i;
      arc(turnSign(LEGS[i].dir, LEGS[i + 1].dir), CORNER_R);
    }
  }
}

// ---- input: step forward / back through the frames ----
let idx = 0;
window.addEventListener('keydown', (e) => {
  if (e.code === 'ArrowUp')   { idx = Math.min(idx + 1, frames.length - 1); e.preventDefault(); }
  if (e.code === 'ArrowDown') { idx = Math.max(idx - 1, 0); e.preventDefault(); }
});

// ---- projection (camera placed at the current frame) ----
interface Cam { x: number; y: number; z: number }
let cx = 0, cz = 0, ch = 1, sh = 0;  // camera origin + heading cos/sin
function toCam(wx: number, wy: number, wz: number): Cam {
  const dx = wx - cx, dy = wy - EYE_H, dz = wz - cz;
  return { x: ch * dx - sh * dz, y: dy, z: sh * dx + ch * dz };
}
function project(p: Cam): { x: number; y: number } {
  return { x: W / 2 + (p.x / p.z) * FOCAL, y: H / 2 - (p.y / p.z) * FOCAL };
}
function clipNear(verts: Cam[]): Cam[] {
  const out: Cam[] = [];
  for (let i = 0; i < verts.length; i++) {
    const a = verts[i];
    const b = verts[(i + 1) % verts.length];
    const aIn = a.z >= NEAR, bIn = b.z >= NEAR;
    if (aIn) out.push(a);
    if (aIn !== bIn) {
      const f = (NEAR - a.z) / (b.z - a.z);
      out.push({ x: a.x + f * (b.x - a.x), y: a.y + f * (b.y - a.y), z: NEAR });
    }
  }
  return out;
}

// ---- drawing ----
function fillGround(corners: Array<[number, number, number]>, color: string): void {
  const cam = corners.map((c) => toCam(c[0], c[1], c[2]));
  const clipped = clipNear(cam);
  if (clipped.length < 3) return;
  const pts = clipped.map(project);
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
  ctx.closePath();
  ctx.fill();
}

function drawRoad(r: Rect): void {
  fillGround([[r.x1, 0, r.z1], [r.x2, 0, r.z1], [r.x2, 0, r.z2], [r.x1, 0, r.z2]], '#34353c');
}

function drawTree(t: Tree): void {
  const base = toCam(t.x, 0, t.z);
  if (base.z <= NEAR) return;
  const top = toCam(t.x, TREE_H, t.z);
  const pb = project(base), pt = project(top);
  const ht = pb.y - pt.y;            // on-screen height
  const trunkW = Math.max(1, ht * 0.10);
  ctx.fillStyle = '#5a3e22';
  ctx.fillRect(pb.x - trunkW / 2, pb.y - ht * 0.42, trunkW, ht * 0.42);
  ctx.fillStyle = '#2f7a30';
  ctx.beginPath();
  ctx.arc(pb.x, pb.y - ht * 0.62, ht * 0.30, 0, Math.PI * 2);
  ctx.fill();
}

function drawHud(f: Pose): void {
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(12, 12, 230, 30);
  ctx.fillStyle = '#fff';
  ctx.font = 'bold 14px ui-monospace, monospace';
  ctx.textAlign = 'left';
  ctx.fillText(`${f.where}   frame ${idx} / ${frames.length - 1}`, 22, 32);
}

function drawMinimap(f: Pose): void {
  const mw = 150, mh = 150, mx = W - mw - 12, my = H - mh - 12, pad = 10;
  let x1 = Infinity, z1 = Infinity, x2 = -Infinity, z2 = -Infinity;
  for (const r of pavement) {
    x1 = Math.min(x1, r.x1); z1 = Math.min(z1, r.z1);
    x2 = Math.max(x2, r.x2); z2 = Math.max(z2, r.z2);
  }
  const sc = Math.min((mw - 2 * pad) / (x2 - x1), (mh - 2 * pad) / (z2 - z1));
  const ox = mx + (mw - (x2 - x1) * sc) / 2, oy = my + (mh - (z2 - z1) * sc) / 2;
  const MX = (x: number): number => ox + (x - x1) * sc;
  const MY = (z: number): number => oy + (z2 - z) * sc;  // north up

  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(mx, my, mw, mh);
  ctx.fillStyle = '#55585f';
  for (const r of pavement) ctx.fillRect(MX(r.x1), MY(r.z2), (r.x2 - r.x1) * sc, (r.z2 - r.z1) * sc);
  ctx.fillStyle = '#2f7a30';
  for (const t of trees) ctx.fillRect(MX(t.x) - 1, MY(t.z) - 1, 2, 2);
  ctx.save();
  ctx.translate(MX(f.x), MY(f.z));
  ctx.rotate(f.h);
  ctx.fillStyle = '#ff3030';
  ctx.beginPath();
  ctx.moveTo(0, -5); ctx.lineTo(3, 4); ctx.lineTo(-3, 4); ctx.closePath();
  ctx.fill();
  ctx.restore();
}

function render(): void {
  const f = frames[idx];
  cx = f.x; cz = f.z; ch = Math.cos(f.h); sh = Math.sin(f.h);

  // level camera => the horizon sits at H/2: sky above, grass below
  ctx.fillStyle = '#8ecae6';
  ctx.fillRect(0, 0, W, H / 2);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(0, H / 2, W, H / 2);

  for (const r of pavement) drawRoad(r);

  const vis = trees
    .map((t) => ({ t, z: toCam(t.x, 0, t.z).z }))
    .filter((o) => o.z > NEAR)
    .sort((a, b) => b.z - a.z);
  for (const o of vis) drawTree(o.t);

  drawHud(f);
  drawMinimap(f);
}

function loop(): void {
  render();
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
