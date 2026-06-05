// =============================================================================
// main — canvas. The frame loop is: take the current RiderState, build the
// Rider-relative scene (view.ts), and draw it. The Rider is advanced EXPLICITLY
// by getNextRiderState (model.ts) before drawing — that next RiderState is what
// gets passed into the rendering code.
//
//   ArrowUp   : getNextRiderState -> push the next RiderState onto the history
//   ArrowDown : pop back to the previous RiderState
// =============================================================================
import { buildWorld, initialRiderState, getNextRiderState, riderHeading, leanFor } from './model.ts';
import type { RiderState } from './model.ts';
import { buildScene } from './view.ts';
import type { RiderPt, Quad } from './view.ts';
import { drawHorizon } from './horizon.ts';
import { drawCritter } from './critter.ts';
import type { Project } from './critter.ts';
import { drawTree } from './tree.ts';

const canvas = document.getElementById('c') as HTMLCanvasElement;
const ctx = canvas.getContext('2d') as CanvasRenderingContext2D;
const W = canvas.width;
const H = canvas.height;

// ---- camera ----
const FOV = 70;
const FOCAL = (W / 2) / Math.tan((FOV / 2) * Math.PI / 180);
const NEAR = 0.4;
const EYE_H = 1.2;

// ---- the world + the Rider's history (a forward/back stack of RiderStates) ----
const world = buildWorld();
const riderHistory: RiderState[] = [initialRiderState(world)];
const currentRider = (): RiderState => riderHistory[riderHistory.length - 1];

// the rider's current lean (camera roll), from the heading change of his latest step
const currentLean = (): number => {
  const n = riderHistory.length;
  if (n < 2) return 0;
  return leanFor(riderHeading(riderHistory[n - 1], world) - riderHeading(riderHistory[n - 2], world));
};

// the game is over once the Rider has reached the end of the final (exit-less) segment
const lastId = world.order[world.order.length - 1];
function gameEnded(rider: RiderState): boolean {
  return rider.segment === lastId && !rider.turn && rider.along >= world.segments[lastId].length - 1e-6;
}

// advance the Rider one frame and remember it (a no-op once it stops moving — game over)
function advance(): void {
  const rider = currentRider();
  const next = getNextRiderState(rider, world);
  if (next.segment !== rider.segment || next.along !== rider.along || next.across !== rider.across) {
    riderHistory.push(next);
  }
}

// SPACE toggles automatic mode (advance every frame, so you needn't hold the up arrow);
// the arrows always take manual control, pausing auto so you can walk frame by frame
// (UP = step forward, DOWN = step back). Holding an arrow repeats; holding space doesn't.
let auto = false;
window.addEventListener('keydown', (e) => {
  if (e.code === 'Space') {
    if (!e.repeat) auto = !auto;
    e.preventDefault();
  } else if (e.code === 'ArrowUp') {
    auto = false;
    advance();
    e.preventDefault();
  } else if (e.code === 'ArrowDown') {
    auto = false;
    if (riderHistory.length > 1) riderHistory.pop();
    e.preventDefault();
  }
});

// ---- projection (Rider frame -> screen) ----
interface V3 { right: number; forward: number; height: number }
function project(p: V3): { x: number; y: number } {
  return { x: W / 2 + (p.right / p.forward) * FOCAL, y: H / 2 - ((p.height - EYE_H) / p.forward) * FOCAL };
}
// project a ground-plane point at a height — the form critter.ts wants
const screenOf: Project = (right, forward, height) => project({ right, forward, height });
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
  const verts: V3[] = q.pts.map((p: RiderPt) => ({ right: p.right, forward: p.forward, height: 0 }));
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

// frame timing, smoothed. fps/frameMs are the WALL-CLOCK cadence (how fast the browser
// actually calls us); renderMs is how long our own draw takes. At 60Hz a healthy frame
// is one vsync — TARGET_MS (16.67ms). A gap of ~2x means a vsync was missed (dropped).
const TARGET_MS = 1000 / 60;   // 60Hz vsync budget
let fps = 0, renderMs = 0, frameMs = 0, droppedFrames = 0, dropFlash = 0;

function drawHud(rider: RiderState): void {
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(12, 12, 452, 74);
  ctx.font = 'bold 13px ui-monospace, monospace';
  ctx.textAlign = 'left';

  // line 1: where + step, then the mode badge (green AUTO / amber PAUSED)
  const where = rider.turn ? `${rider.segment} (turning ${rider.turn.phase})` : `${rider.segment} @ ${rider.along.toFixed(1)}m`;
  const l1 = `${where}   ·   step ${riderHistory.length - 1}   ·   `;
  ctx.fillStyle = '#fff';
  ctx.fillText(l1, 22, 31);
  ctx.fillStyle = auto ? '#7cfc7c' : '#e6c64f';
  ctx.fillText(auto ? 'AUTO' : 'PAUSED', 22 + ctx.measureText(l1).width, 31);

  // line 2: the Rider's own pace
  ctx.fillStyle = '#9fe6a0';
  ctx.fillText(`speed ${rider.v.toFixed(2)} m/press`, 22, 50);

  // line 3: frame HEALTH — wall-clock cadence vs the 60Hz budget; turns red while dropping
  ctx.fillStyle = dropFlash > 0 ? '#ff6b6b' : '#9fe6a0';
  ctx.fillText(`${fps.toFixed(0)} fps   ·   frame ${frameMs.toFixed(1)}/${TARGET_MS.toFixed(1)}ms   ·   render ${renderMs.toFixed(1)}ms   ·   dropped ${droppedFrames}`, 22, 69);
}

// draw one frame for the given RiderState (handed in by the loop)
function render(rider: RiderState): void {
  const scene = buildScene(rider, world);

  // CAMERA ROLL: the rider banks into the turn, so the whole world — horizon included
  // — rotates about the screen centre by his lean. The HUD/overlay (below) stay level.
  const lean = currentLean();
  ctx.save();
  ctx.translate(W / 2, H / 2);
  ctx.rotate(-lean);
  ctx.translate(-W / 2, -H / 2);

  // sky above / grass below, drawn oversized so the rolled frame's corners stay filled
  const BIG = W + H;
  ctx.fillStyle = '#8ecae6';
  ctx.fillRect(W / 2 - BIG, H / 2 - BIG, 2 * BIG, BIG);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(W / 2 - BIG, H / 2, 2 * BIG, BIG);

  drawHorizon(ctx, riderHeading(rider, world), W, H, FOCAL, BIG);   // mountains + sun, by orientation only

  for (const q of scene.quads) drawQuad(q);

  // trees + critters are billboards; draw them back-to-front together so a
  // nearer one correctly occludes a farther one.
  const bills: Array<{ forward: number; draw: () => void }> = [];
  for (const t of scene.trees) bills.push({ forward: t.at.forward, draw: () => drawTree(ctx, t, screenOf) });
  for (const cr of scene.critters) bills.push({ forward: cr.at.forward, draw: () => drawCritter(ctx, cr, screenOf) });
  bills.filter((b) => b.forward > NEAR).sort((a, b) => b.forward - a.forward).forEach((b) => b.draw());

  ctx.restore();

  drawHud(rider);

  if (gameEnded(rider)) {
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
  if (lastFrame) {
    const dt = t - lastFrame;
    fps += (1000 / Math.max(1, dt) - fps) * 0.1;        // smoothed wall-clock cadence
    frameMs += (dt - frameMs) * 0.1;
    // vsyncs skipped this frame. Ignore huge gaps (>200ms = the tab was backgrounded,
    // not a render hiccup) so the counter reflects real jank only.
    const missed = dt > 200 ? 0 : Math.max(0, Math.round(dt / TARGET_MS) - 1);
    droppedFrames += missed;
    dropFlash = missed > 0 ? 45 : Math.max(0, dropFlash - 1);   // keep the warning lit ~0.75s after a drop
  }
  lastFrame = t;

  // automatic mode: one Rider step per frame, until paused or finished
  if (auto && !gameEnded(currentRider())) advance();

  const t0 = performance.now();
  render(currentRider());
  renderMs += (performance.now() - t0 - renderMs) * 0.1;        // smoothed render cost
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
