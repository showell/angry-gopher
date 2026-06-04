// =============================================================================
// main — canvas. Projects the car-relative scene (from view.ts) to the screen
// and draws it; drives the forward/back stack of CarStates.
//
//   ArrowUp   : advanceCar -> push a new CarState, redraw
//   ArrowDown : pop a CarState, redraw
// =============================================================================
import { buildWorld, initialState, advanceCar, carHeading } from './model.ts';
import type { CarState } from './model.ts';
import { buildScene } from './view.ts';
import { groundBase, northRange, westRange, SUN_BEARING, SNOWLINE } from './horizon.ts';
import type { CarPt, Quad, TreeView, CritterView } from './view.ts';

const canvas = document.getElementById('c') as HTMLCanvasElement;
const ctx = canvas.getContext('2d') as CanvasRenderingContext2D;
const W = canvas.width;
const H = canvas.height;

// ---- camera ----
const FOV = 70;
const FOCAL = (W / 2) / Math.tan((FOV / 2) * Math.PI / 180);
const NEAR = 0.4;
const EYE_H = 1.2;

// ---- the world + the state stack ----
const world = buildWorld();
const stack: CarState[] = [initialState(world)];
const current = (): CarState => stack[stack.length - 1];

// the game is over once we've driven to the end of the final (exit-less) segment
const lastId = world.order[world.order.length - 1];
function gameEnded(s: CarState): boolean {
  return s.segment === lastId && !s.turn && s.along >= world.segments[lastId].length - 1e-6;
}

window.addEventListener('keydown', (e) => {
  if (e.code === 'ArrowUp') {
    const next = advanceCar(current(), world);
    const c = current();
    if (next.segment !== c.segment || next.along !== c.along || next.across !== c.across) stack.push(next);
    e.preventDefault();
  } else if (e.code === 'ArrowDown') {
    if (stack.length > 1) stack.pop();
    e.preventDefault();
  }
});

// ---- projection (car frame -> screen) ----
interface V3 { right: number; forward: number; height: number }
function project(p: V3): { x: number; y: number } {
  return { x: W / 2 + (p.right / p.forward) * FOCAL, y: H / 2 - ((p.height - EYE_H) / p.forward) * FOCAL };
}
function clipNear(verts: V3[]): V3[] {
  const out: V3[] = [];
  for (let i = 0; i < verts.length; i++) {
    const a = verts[i], b = verts[(i + 1) % verts.length];
    const aIn = a.forward >= NEAR, bIn = b.forward >= NEAR;
    if (aIn) out.push(a);
    if (aIn !== bIn) {
      const f = (NEAR - a.forward) / (b.forward - a.forward);
      out.push({
        right: a.right + f * (b.right - a.right),
        forward: NEAR,
        height: a.height + f * (b.height - a.height),
      });
    }
  }
  return out;
}

function drawQuad(q: Quad): void {
  const verts: V3[] = q.pts.map((p: CarPt) => ({ right: p.right, forward: p.forward, height: 0 }));
  const clipped = clipNear(verts);
  if (clipped.length < 3) return;
  const pts = clipped.map(project);
  ctx.fillStyle = q.color;
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
  ctx.closePath();
  ctx.fill();
}

// radially symmetric: drawn only from distance + angle. Round trees (autumn
// colours) are a trunk + a coloured disc; pines are a trunk + a thin, jagged
// conifer in darker green.
const PINE = '#1c5a22';   // darker than the round green
function drawTree(t: TreeView): void {
  const at = t.at;
  if (at.forward <= NEAR) return;
  const base = project({ right: at.right, forward: at.forward, height: 0 });
  const top = project({ right: at.right, forward: at.forward, height: t.height });
  const ht = base.y - top.y;
  const trunkW = Math.max(1, ht * 0.10);
  ctx.fillStyle = '#5a3e22';
  ctx.fillRect(base.x - trunkW / 2, base.y - ht * 0.42, trunkW, ht * 0.42);

  if (t.pine) {
    // three stacked tiers, narrow and widest at the bottom — a jagged conifer
    const apexY = base.y - ht, foliage = ht * 0.90, w = ht * 0.20;
    const tops = [0.0, 0.28, 0.56], bots = [0.46, 0.74, 1.0], wide = [0.5, 0.78, 1.0];
    ctx.fillStyle = PINE;
    for (let k = 0; k < 3; k++) {
      ctx.beginPath();
      ctx.moveTo(base.x, apexY + foliage * tops[k]);
      ctx.lineTo(base.x + w * wide[k], apexY + foliage * bots[k]);
      ctx.lineTo(base.x - w * wide[k], apexY + foliage * bots[k]);
      ctx.closePath();
      ctx.fill();
    }
    return;
  }

  ctx.fillStyle = t.color;
  ctx.beginPath();
  ctx.arc(base.x, base.y - ht * 0.62, ht * 0.30, 0, Math.PI * 2);
  ctx.fill();
}

// Emoji are expensive to rasterize every frame, so render each one ONCE to an
// offscreen sprite and reuse it. drawImage is far cheaper than fillText.
const spriteCache = new Map<string, HTMLCanvasElement>();
function emojiSprite(emoji: string): HTMLCanvasElement {
  const cached = spriteCache.get(emoji);
  if (cached) return cached;
  const S = 96;
  const c = document.createElement('canvas');
  c.width = S; c.height = S;
  const g = c.getContext('2d') as CanvasRenderingContext2D;
  g.font = `${Math.round(S * 0.8)}px serif`;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText(emoji, S / 2, S / 2 + S * 0.06);
  spriteCache.set(emoji, c);
  return c;
}

// a full-body emoji billboard, sized by distance, flipped to face the road
function drawCritter(cr: CritterView): void {
  const at = cr.at;
  if (at.forward <= NEAR) return;
  const base = project({ right: at.right, forward: at.forward, height: 0 });
  const top = project({ right: at.right, forward: at.forward, height: cr.height });
  const h = base.y - top.y;
  if (h < 5) return;
  ctx.save();
  ctx.translate(base.x, base.y);
  if (cr.faceRight) ctx.scale(-1, 1);   // most animal emoji face left by default
  ctx.drawImage(emojiSprite(cr.emoji), -h / 2, -h, h, h);   // square, bottom on the ground
  ctx.restore();
}

// ---- the horizon, at infinity (orientation only) ----
// Each screen column is a viewing ray at some absolute bearing (car heading +
// its angle off-centre). A "silhouette" fills the band between a height f(bearing)
// above the horizon and some bottom line.
const ROCK = '#5b6a8f';        // northern range
const ROCK_WEST = '#39435f';   // westward range, darker — backlit by the sunset
const SNOW = '#eef3f8';
const LAND = '#4a8f43';        // foreground rolling land (matches the grass)

function wrapAngle(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}
function bearingAt(x: number, heading: number): number {
  return heading + Math.atan((x - W / 2) / FOCAL);
}
function silhouette(heading: number, f: (b: number) => number, bottomY: number): void {
  ctx.beginPath();
  ctx.moveTo(0, bottomY);
  for (let x = 0; x <= W; x += 2) ctx.lineTo(x, H / 2 - f(bearingAt(x, heading)));
  ctx.lineTo(W, bottomY);
  ctx.closePath();
  ctx.fill();
}

function drawHorizon(heading: number): void {
  // the setting sun + its glow, clipped to the sky, behind the ranges
  const rel = wrapAngle(SUN_BEARING - heading);
  if (Math.abs(rel) < 1.4) {
    const sx = W / 2 + Math.tan(rel) * FOCAL, sy = H / 2 - 50;   // up over the range crest, setting behind it
    ctx.save();
    ctx.beginPath(); ctx.rect(0, 0, W, H / 2); ctx.clip();   // sky only — the ground occludes the rest
    const glow = ctx.createRadialGradient(sx, sy, 8, sx, sy, 340);
    glow.addColorStop(0, 'rgba(255,201,128,0.85)');
    glow.addColorStop(0.4, 'rgba(255,150,92,0.32)');
    glow.addColorStop(1, 'rgba(255,150,92,0)');
    ctx.fillStyle = glow; ctx.fillRect(0, 0, W, H / 2);
    const sun = ctx.createRadialGradient(sx, sy, 4, sx, sy, 46);
    sun.addColorStop(0, '#ffe6a3'); sun.addColorStop(1, '#ff9d5c');
    ctx.fillStyle = sun;
    ctx.beginPath(); ctx.arc(sx, sy, 46, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }

  ctx.fillStyle = ROCK_WEST; silhouette(heading, westRange, H / 2);                  // westward range, over the sun
  ctx.fillStyle = ROCK; silhouette(heading, northRange, H / 2);                      // northern range
  ctx.fillStyle = SNOW;                                                              // snowcaps above the snowline
  silhouette(heading, (b) => Math.max(northRange(b), SNOWLINE), H / 2 - SNOWLINE);
  ctx.fillStyle = LAND; silhouette(heading, groundBase, H / 2);                      // rolling land, in front
}

// frame-rate / render-time, smoothed — lets us tell "car going slow" (low speed
// but fps pinned at 60) from "code going slow" (fps drops / render ms climbs).
let fps = 0, renderMs = 0;

function drawHud(s: CarState): void {
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(12, 12, 360, 50);
  ctx.font = 'bold 13px ui-monospace, monospace';
  ctx.textAlign = 'left';
  const where = s.turn ? `${s.segment} (turning ${s.turn.phase})` : `${s.segment} @ ${s.along.toFixed(1)}m`;
  ctx.fillStyle = '#fff';
  ctx.fillText(`${where}   ·   step ${stack.length - 1}`, 22, 31);
  ctx.fillStyle = '#9fe6a0';
  ctx.fillText(`speed ${s.v.toFixed(2)} m/press   ·   ${fps.toFixed(0)} fps   ·   ${renderMs.toFixed(1)} ms`, 22, 50);
}

function render(): void {
  const s = current();
  const scene = buildScene(s, world);

  // level camera => horizon at H/2: sky above, grass below
  ctx.fillStyle = '#8ecae6';
  ctx.fillRect(0, 0, W, H / 2);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(0, H / 2, W, H / 2);

  drawHorizon(carHeading(s, world));   // mountains on the northern horizon, by orientation only

  for (const q of scene.quads) drawQuad(q);

  // trees + critters are billboards; draw them back-to-front together so a
  // nearer one correctly occludes a farther one.
  const bills: Array<{ forward: number; draw: () => void }> = [];
  for (const t of scene.trees) bills.push({ forward: t.at.forward, draw: () => drawTree(t) });
  for (const cr of scene.critters) bills.push({ forward: cr.at.forward, draw: () => drawCritter(cr) });
  bills.filter((b) => b.forward > NEAR).sort((a, b) => b.forward - a.forward).forEach((b) => b.draw());

  drawHud(s);

  if (gameEnded(s)) {
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(0, H / 2 - 48, W, 96);
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 46px ui-monospace, monospace';
    ctx.textAlign = 'center';
    ctx.fillText('Game ended', W / 2, H / 2 + 16);
    ctx.textAlign = 'left';
  }
}

let lastFrame = 0;
function loop(t: number): void {
  if (lastFrame) fps += ((1000 / Math.max(1, t - lastFrame)) - fps) * 0.1;   // smoothed fps from frame dt
  lastFrame = t;
  const t0 = performance.now();
  render();
  renderMs += ((performance.now() - t0) - renderMs) * 0.1;                    // smoothed render cost
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
