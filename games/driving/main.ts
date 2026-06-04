// =============================================================================
// main — canvas. Projects the car-relative scene (from view.ts) to the screen
// and draws it; drives the forward/back stack of CarStates.
//
//   ArrowUp   : advanceCar -> push a new CarState, redraw
//   ArrowDown : pop a CarState, redraw
// =============================================================================
import { buildWorld, initialState, advanceCar } from './model.ts';
import type { CarState } from './model.ts';
import { buildScene } from './view.ts';
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

// radially symmetric: drawn only from distance + angle (a trunk + a coloured disc)
function drawTree(t: TreeView): void {
  const at = t.at;
  if (at.forward <= NEAR) return;
  const base = project({ right: at.right, forward: at.forward, height: 0 });
  const top = project({ right: at.right, forward: at.forward, height: t.height });
  const ht = base.y - top.y;
  const trunkW = Math.max(1, ht * 0.10);
  ctx.fillStyle = '#5a3e22';
  ctx.fillRect(base.x - trunkW / 2, base.y - ht * 0.42, trunkW, ht * 0.42);
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

function drawHud(s: CarState): void {
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(12, 12, 300, 30);
  ctx.fillStyle = '#fff';
  ctx.font = 'bold 13px ui-monospace, monospace';
  ctx.textAlign = 'left';
  const where = s.turn ? `${s.segment} (turning ${s.turn.phase})` : `${s.segment} @ ${s.along.toFixed(1)}m`;
  ctx.fillText(`${where}   ·   step ${stack.length - 1}`, 22, 32);
}

function render(): void {
  const s = current();
  const scene = buildScene(s, world);

  // level camera => horizon at H/2: sky above, grass below
  ctx.fillStyle = '#8ecae6';
  ctx.fillRect(0, 0, W, H / 2);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(0, H / 2, W, H / 2);

  for (const q of scene.quads) drawQuad(q);

  // trees + critters are billboards; draw them back-to-front together so a
  // nearer one correctly occludes a farther one.
  const bills: Array<{ forward: number; draw: () => void }> = [];
  for (const t of scene.trees) bills.push({ forward: t.at.forward, draw: () => drawTree(t) });
  for (const cr of scene.critters) bills.push({ forward: cr.at.forward, draw: () => drawCritter(cr) });
  bills.filter((b) => b.forward > NEAR).sort((a, b) => b.forward - a.forward).forEach((b) => b.draw());

  drawHud(s);
}

function loop(): void {
  render();
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
