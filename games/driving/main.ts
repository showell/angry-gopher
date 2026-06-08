// =============================================================================
// main — canvas. The frame loop is: take the current RiderState, build the
// Rider-relative scene (view.ts), and draw it. The Rider is advanced EXPLICITLY
// by getNextRiderState (model.ts) before drawing — that next RiderState is what
// gets passed into the rendering code.
//
//   ArrowUp   : getNextRiderState -> push the next RiderState onto the history
//   ArrowDown : pop back to the previous RiderState
// =============================================================================
import { initialRiderState, getNextRiderState, riderHeading, leanFor, MAX_LEAN, gazeAngle } from './model.ts';
import type { RiderState } from './model.ts';
import { buildWorld } from './road_segment.ts';
import { buildScene } from './view.ts';
import { drawHorizon } from './horizon.ts';
import { DETAIL_DIST, NEAR, groundDrop } from './scenery.ts';
import type { Project, RiderPt, Quad, Poly3 } from './scenery.ts';

// The page is a near-empty shell (the Go /driving route or the standalone
// index.html), so we build our own DOM here — the host ships no markup or CSS.
// A fixed 960x600 canvas centred on a dark page, with a one-line controls hint.
document.body.style.cssText =
  'margin:0;background:#0b0b0d;height:100vh;display:flex;align-items:center;' +
  'justify-content:center;font-family:ui-monospace,Menlo,monospace;color:#cfd2d6';

const wrap = document.createElement('div');
wrap.style.position = 'relative';
document.body.appendChild(wrap);

const canvas = document.createElement('canvas');
canvas.width = 960;
canvas.height = 600;
canvas.style.cssText = 'display:block;background:#000;box-shadow:0 10px 40px rgba(0,0,0,0.6)';
wrap.appendChild(canvas);

const hint = document.createElement('div');
hint.textContent = '↑ drive forward · ↓ back up · SPACE auto';
hint.style.cssText =
  'position:absolute;left:50%;top:10px;transform:translateX(-50%);padding:6px 14px;' +
  'background:rgba(0,0,0,0.45);border:1px solid rgba(255,255,255,0.15);border-radius:4px;' +
  'font-size:12px;color:#e6e8eb;letter-spacing:0.4px;pointer-events:none;white-space:nowrap';
wrap.appendChild(hint);

const ctx = canvas.getContext('2d') as CanvasRenderingContext2D;
const W = canvas.width;
const H = canvas.height;

// ---- camera ----
const FOV = 70;
const FOCAL = (W / 2) / Math.tan((FOV / 2) * Math.PI / 180);   // base focal, looking straight ahead
const EYE_H = 1.2;
const MIN_SCENERY_PX = 4;   // skip scenery that would project shorter than this (far AND short)

// The Rider's focal point pulls IN as he leans into a turn — he's watching the corner he's
// executing, not the far mountains. We measure the lean as a fraction of the enforced
// MAX_LEAN (the route never banks past it; see model.ts + test_model), and pull the focal
// from full FOCAL down toward MIN_FOCAL_FACTOR·FOCAL, accelerating (squared) so the focus
// snaps in hard at the deepest part of a turn. The floor keeps it well clear of a degenerate
// zero. `camFocal` is the live camera focal, recomputed from the roll each frame; the whole
// projection reads it.
const MIN_FOCAL_FACTOR = 0.35;   // focal at full lean, as a fraction of FOCAL (never 0)
let camFocal = FOCAL;
const focalForLean = (lean: number): number => {
  const frac = Math.min(Math.abs(lean) / MAX_LEAN, 1);   // 0 straight … 1 at MAX_LEAN
  return FOCAL * (1 - (1 - MIN_FOCAL_FACTOR) * frac * frac);
};

// the rider also turns his HEAD into the corner — a subtle view-only yaw, 15% of the lean angle.
const HEAD_YAW_FRAC = 0.15;

// The sun SETS over the ride: its elevation drops a fixed amount per STEP — a pure function of the
// step, like the beacon clock, so it scrubs cleanly on reverse and freezes on pause. The HEADLINE
// effect is the SKY dimming with it (skyColor, below); the disc itself is secondary. Rate doubles
// the original calibration (16% of the sun's 7.678deg diameter over the 625-step seg9 traversal,
// the route's most direct approach toward the sun); start elevation is ~2x as high to match.
const SUN_SET_DEG_PER_STEP = 0.16 * 7.678 / 625;   // = 0.001966 deg/step (2x)
const SUN_ELEV_START_DEG = 13.3;                   // ~2x as high (often off-screen on the early segments)
const sunHeightPx = (step: number): number =>
  FOCAL * Math.tan((SUN_ELEV_START_DEG - SUN_SET_DEG_PER_STEP * step) * Math.PI / 180);

// The sky DIMS as the sun sets — the main effect. Lerp the whole sky colour from day to a dusk
// blue as the sun descends from its start elevation toward the horizon (t = the fraction it has
// fallen). Darkening ALL channels (not just B) keeps it reading blue rather than fading to grey.
const DAY_SKY = [142, 202, 230];    // #8ecae6 (the established daytime sky)
const DUSK_SKY = [36, 58, 94];      // deep dusk blue
const skyColor = (step: number): string => {
  const elev = SUN_ELEV_START_DEG - SUN_SET_DEG_PER_STEP * step;
  const t = Math.max(0, Math.min(1, 1 - elev / SUN_ELEV_START_DEG));   // 0 at the start, 1 once the sun reaches the horizon
  const ch = (i: number): number => Math.round(DAY_SKY[i] + (DUSK_SKY[i] - DAY_SKY[i]) * t);
  return `rgb(${ch(0)},${ch(1)},${ch(2)})`;
};

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

// The scene only needs redrawing when something CHANGES — the Rider advancing or
// stepping. While paused and idle the picture is identical frame to frame, so we skip
// the render entirely (and the HUD/stats hold still — there are no new frames to
// report). `dirty` marks a pending redraw; it's set wherever the Rider's state changes.
let dirty = true;
let auto = false;

// Raw per-frame instrumentation for the CURRENT auto run, with NO smoothing: one entry
// per rendered frame — { step, dt (wall-clock frame interval, ms), render (our own draw
// cost, ms) }. Reset when auto starts; dumped as a JSON string to the console on stop.
let trace: Array<{ step: number; dt: number; render: number }> = [];

// Start/stop automatic mode and the trace side effects: a fresh buffer on start, a JSON
// dump on stop. No-op when already in the requested state.
function setAuto(on: boolean): void {
  if (on === auto) return;
  if (on) trace = [];
  else if (trace.length) console.log(JSON.stringify(trace));
  auto = on;
  dirty = true;
}

// advance the Rider one frame and remember it (a no-op once it stops moving — game over)
function advance(): void {
  const rider = currentRider();
  const next = getNextRiderState(rider, world);
  if (next.segment !== rider.segment || next.along !== rider.along || next.across !== rider.across) {
    riderHistory.push(next);
    dirty = true;
  }
}

// SPACE toggles automatic mode (advance every frame, so you needn't hold the up arrow);
// the arrows always take manual control, stopping auto so you can walk frame by frame
// (UP = step forward, DOWN = step back). Holding an arrow repeats; holding space doesn't.
window.addEventListener('keydown', (e) => {
  if (e.code === 'Space') {
    if (!e.repeat) setAuto(!auto);
    e.preventDefault();
  } else if (e.code === 'ArrowUp') {
    setAuto(false);
    advance();
    e.preventDefault();
  } else if (e.code === 'ArrowDown') {
    setAuto(false);
    if (riderHistory.length > 1) { riderHistory.pop(); dirty = true; }
    e.preventDefault();
  }
});

// ---- projection (Rider frame -> screen) ----
interface V3 { right: number; forward: number; height: number }
function project(p: V3): { x: number; y: number } {
  return { x: W / 2 + (p.right / p.forward) * camFocal, y: H / 2 - ((p.height - EYE_H) / p.forward) * camFocal };
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
  // the ground is curved: lower each vertex by its distance's curvature drop (the road then bends
  // toward a finite horizon). Tessellated road quads make the bend smooth rather than a tilt.
  const verts: V3[] = q.pts.map((p: RiderPt) => ({ right: p.right, forward: p.forward, height: -groundDrop(p.right, p.forward) }));
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

// a raised polygon (guard rail) — same near-clip + project + fill as a road quad, but its
// corners already carry their own heights (off the ground).
function drawPoly3(p: Poly3): void {
  const clipped = clipNear(p.pts);
  if (clipped.length < 3) return;
  const pts = clipped.map(project);
  ctx.fillStyle = p.color;
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
  ctx.closePath();
  ctx.fill();
}

// frame timing, smoothed. fps/frameMs are the WALL-CLOCK cadence (how fast the browser
// actually calls us); renderMs is how long our own draw takes. At 60Hz a healthy frame
// is one vsync — TARGET_MS (16.67ms). A gap of ~2x means a vsync was missed (dropped).
const TARGET_MS = 1000 / 60;   // 60Hz vsync budget (the ideal we display against)
let fps = 60, renderMs = 0, frameMs = TARGET_MS, droppedFrames = 0, dropFlash = 0;

function drawHud(rider: RiderState): void {
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(12, 12, 510, 74);
  ctx.font = 'bold 13px ui-monospace, monospace';
  ctx.textAlign = 'left';

  const phase = rider.turn ? rider.turn.phase : 'cruise';
  const headingDeg = rider.angle * 180 / Math.PI;
  const tiltDeg = currentLean() * 180 / Math.PI;

  // line 1: segment + phase + step, then the mode badge (green AUTO / amber PAUSED)
  const l1 = `${rider.segment}  ·  ${phase}  ·  step ${riderHistory.length - 1}  ·  `;
  ctx.fillStyle = '#fff';
  ctx.fillText(l1, 22, 31);
  ctx.fillStyle = auto ? '#7cfc7c' : '#e6c64f';
  ctx.fillText(auto ? 'AUTO' : 'PAUSED', 22 + ctx.measureText(l1).width, 31);

  // line 2: ALWAYS-on rider state — position (x = across, y = along), heading relative to
  // the segment's direction, camera tilt, and speed. (These used to vanish during turns.)
  ctx.fillStyle = '#9fe6a0';
  const gazeDeg = gazeAngle(rider) * 180 / Math.PI;
  ctx.fillText(`x ${rider.across.toFixed(2)}  y ${rider.along.toFixed(1)}  heading ${headingDeg.toFixed(1)}deg  tilt ${tiltDeg.toFixed(1)}deg  gaze ${gazeDeg.toFixed(0)}deg  v ${rider.v.toFixed(2)}`, 22, 50);

  // line 3: frame HEALTH — wall-clock cadence vs the 60Hz budget; turns red while dropping
  ctx.fillStyle = dropFlash > 0 ? '#ff6b6b' : '#9fe6a0';
  ctx.fillText(`${fps.toFixed(0)} fps  ·  frame ${frameMs.toFixed(1)}/${TARGET_MS.toFixed(1)}ms  ·  render ${renderMs.toFixed(1)}ms  ·  dropped ${droppedFrames}`, 22, 69);
}

// draw one frame for the given RiderState (handed in by the loop)
function render(rider: RiderState): void {
  // the lean drives camera roll, the focal pull-in, AND a subtle head-yaw into the corner; compute
  // it first so the scene is built already looking slightly into the turn.
  const lean = currentLean();
  const headYaw = HEAD_YAW_FRAC * lean;
  // the step IS the clock for view-only animation (beacon blink, sunset): a pure function of it,
  // so it freezes on pause and runs backwards on reverse. It's the same step the HUD shows.
  const step = riderHistory.length - 1;
  const scene = buildScene(rider, world, step, headYaw);

  // CAMERA ROLL: the rider banks into the turn, so the whole world — horizon included
  // — rotates about the screen centre by his lean. The HUD/overlay (below) stay level.
  // The same lean also pulls the focal point in (see focalForLean); set it before any
  // projection this frame so the road, scenery, and horizon all share one camera.
  camFocal = focalForLean(lean);
  ctx.save();
  ctx.translate(W / 2, H / 2);
  ctx.rotate(-lean);
  ctx.translate(-W / 2, -H / 2);

  // sky above / grass below, drawn oversized so the rolled frame's corners stay filled
  // (two fillRects — cheap at any size).
  const BIG = W + H;
  ctx.fillStyle = skyColor(step);
  ctx.fillRect(W / 2 - BIG, H / 2 - BIG, 2 * BIG, BIG);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(W / 2 - BIG, H / 2, 2 * BIG, BIG);

  // the horizon silhouettes ARE expensive (a per-column trig loop), so overscan them
  // by only what THIS lean exposes at the frame's corners — ~0 going straight (no
  // wasted columns), a little when banked. (Was a flat W+H, redrawn every frame.)
  const overscan = Math.abs(Math.sin(lean)) * H / 2 + 16;
  // the gaze yaws the view, so the far scenery shifts with it too (he's looking off-axis). The
  // lean pulls camFocal in, which squeezes the horizon horizontally; pass camFocal/FOCAL as the
  // vertical scale so it squeezes vertically by the same factor (it's a real focal change).
  drawHorizon(ctx, riderHeading(rider, world) + gazeAngle(rider) + headYaw, W, H, camFocal, overscan, camFocal / FOCAL, sunHeightPx(step));

  for (const q of scene.quads) drawQuad(q);
  for (const p of scene.polys) drawPoly3(p);   // guard rails, raised above the pavement

  // scenery (trees + critters) drawn back-to-front so a nearer one occludes a farther
  // one. The renderer owns the near/far POLICY; each object owns how it draws at each
  // detail level (drawAsNear within DETAIL_DIST, drawAsFar beyond). Cull anything that
  // would project shorter than MIN_SCENERY_PX — a single test that drops the far AND short
  // (a tall tree stays in until it's very distant; a short critter drops out sooner).
  scene.scenery
    .filter((s) => s.forward > NEAR && (s.height / s.forward) * camFocal >= MIN_SCENERY_PX)
    .sort((a, b) => b.forward - a.forward)
    .forEach((s) => (s.forward < DETAIL_DIST ? s.drawAsNear : s.drawAsFar)(ctx, screenOf));

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
  // automatic mode: one Rider step per frame, until paused or finished (sets `dirty`)
  if (auto && !gameEnded(currentRider())) advance();

  // ONLY redraw when the picture changed. Paused & idle => nothing to draw, so the HUD
  // and its stats freeze (no phantom frames re-reporting the same scene).
  if (dirty) {
    const dt = lastFrame ? t - lastFrame : 0;
    // fps / cadence / drops are a CONTINUOUS-rate notion — only meaningful while auto-
    // running. Compare each frame to the RECENT cadence (frameMs), not a fixed 16.67, so
    // a steady rate (whatever it is) never false-alarms; only a genuine stall does.
    if (auto && lastFrame) {
      fps += (1000 / Math.max(1, dt) - fps) * 0.1;
      if (dt > frameMs * 1.8) { droppedFrames += Math.round(dt / frameMs) - 1; dropFlash = 30; }
      frameMs += (dt - frameMs) * 0.1;
    }
    if (auto && dropFlash > 0) dropFlash--;

    const t0 = performance.now();
    render(currentRider());
    const r = performance.now() - t0;
    renderMs += (r - renderMs) * 0.1;   // smoothed render cost (for the HUD)

    // raw, unsmoothed sample into the trace buffer (auto frames with a valid prior time)
    if (auto && lastFrame) {
      trace.push({ step: riderHistory.length - 1, dt: Math.round(dt * 100) / 100, render: Math.round(r * 100) / 100 });
    }
    dirty = false;
  }
  lastFrame = auto ? t : 0;   // paused => drop the baseline so auto restarts cadence cleanly
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
