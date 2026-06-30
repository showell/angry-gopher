// blitter — the ONLY non-zig piece of the Safari camera, and deliberately dumb.
// It owns no logic: it loads safari.wasm, calls renderFrame(camera pose), and fills
// the polygons zig wrote into linear memory. Every coordinate, color, and paint-order
// decision is zig's; this just walks [color u32][nPoints u32][x f32][y f32]… and fills.
// Plain hand-written JS (no TS, no bundler) — there is nothing here worth typing.

const W = 960, H = 600;

// the sky + grass band, drawn OVERSIZED so the rolled (banked) frame's corners stay
// filled. The world polygons (mountains/road/trees) paint on top, in zig's order. zig
// owns the colours: `skyHex` (upper) → `horizonHex` (lower band) dim toward dusk and
// redden at sunset, matching sky.ts's 0/0.2/1 gradient stops. The grass stays constant.
function drawBackground(ctx, skyHex, horizonHex) {
  const BIG = W + H;
  const g = ctx.createLinearGradient(0, 0, 0, H / 2);
  g.addColorStop(0, skyHex);
  g.addColorStop(0.2, skyHex);
  g.addColorStop(1, horizonHex);
  ctx.fillStyle = g;
  ctx.fillRect(W / 2 - BIG, H / 2 - BIG, 2 * BIG, BIG);
  ctx.fillStyle = '#4a8f43';
  // overlap 1px up over the horizon: under the camera roll the two rects' shared edge can
  // rasterize a sky sliver into the grass — drawing grass last + overlapping wins the seam.
  ctx.fillRect(W / 2 - BIG, H / 2 - 1, 2 * BIG, BIG + 1);
}

// the setting sun: a warm radial glow plus the disc, clipped to the sky (top half) so the
// ground occludes the rest, at the screen centre + scale zig computed (sun.ts's drawSun,
// minus the placement math). Painted before the buffer, so the mountain polys — first in
// the buffer — occlude it: the sun sets BEHIND the ranges, exactly as horizon.ts layers.
const SUN_RADIUS_PX = 46; // matches sky.zig SUN_RADIUS_PX; the gradient recipe lives here
function drawSun(ctx, x, y, scale) {
  ctx.save();
  ctx.beginPath(); ctx.rect(0, 0, W, H / 2); ctx.clip(); // sky only
  const glow = ctx.createRadialGradient(x, y, 8 * scale, x, y, 340 * scale);
  glow.addColorStop(0, 'rgba(255,201,128,0.85)');
  glow.addColorStop(0.4, 'rgba(255,150,92,0.32)');
  glow.addColorStop(1, 'rgba(255,150,92,0)');
  ctx.fillStyle = glow; ctx.fillRect(0, 0, W, H / 2);
  const disc = ctx.createRadialGradient(x, y, 4 * scale, x, y, SUN_RADIUS_PX * scale);
  disc.addColorStop(0, '#ffe6a3'); disc.addColorStop(1, '#ff9d5c');
  ctx.fillStyle = disc;
  ctx.beginPath(); ctx.arc(x, y, SUN_RADIUS_PX * scale, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
}

// 0xRRGGBB -> "#rrggbb"
function hex(c) {
  return '#' + (c & 0xffffff).toString(16).padStart(6, '0');
}

// 0xAARRGGBB -> "rgba(r,g,b,a)" — the translucent colour for the gradient-polygon lights (tag 4).
function rgba(c) {
  return `rgba(${(c >> 16) & 255},${(c >> 8) & 255},${c & 255},${((c >>> 24) & 255) / 255})`;
}

// clamp a gradient stop offset to [0,1], and to >= a lower bound so a 2-stop pair stays ascending.
function stopAt(o, lo = 0) { return Math.max(lo, Math.min(1, o)); }

// shade a 0xRRGGBB by a brightness factor (clamped) -> "rgb(r,g,b)".
function shade(c, f) {
  const r = Math.min(255, Math.round(((c >> 16) & 255) * f));
  const g = Math.min(255, Math.round(((c >> 8) & 255) * f));
  const b = Math.min(255, Math.round((c & 255) * f));
  return `rgb(${r},${g},${b})`;
}

// Walk the draw buffer [base, base+len). Views over the SAME words: u32 for
// tag/color/count, f32 for coordinate bit patterns. tag 0 = solid polygon; tag 1 =
// round-gradient polygon (cylinder/cone shading). The critters used to be tag-2 emoji
// glyphs the browser font rasterised; they are now baked to tag-0 polygons (emoji_frames.zig),
// so this blitter draws no glyphs — it's purely polygons + gradients + the beacon disc.
function blit(ctx, mem, base, len) {
  const u32 = new Uint32Array(mem.buffer, base, len / 4);
  const f32 = new Float32Array(mem.buffer, base, len / 4);
  let w = 0;
  let cmds = 0;
  while (w * 4 < len) {
    cmds++;
    const tag = u32[w++];
    if (tag === 3) {
      // alpha disc: a tower beacon's blinking glow, composited at the alpha zig computed.
      const color = u32[w++];
      const x = f32[w++], y = f32[w++], r = f32[w++], alpha = f32[w++];
      if (r >= 0.5 && alpha >= 0.02) {
        ctx.globalAlpha = alpha;
        ctx.fillStyle = hex(color);
        ctx.beginPath();
        ctx.arc(x, y, r, 0, Math.PI * 2);
        ctx.fill();
        ctx.globalAlpha = 1;
      }
      continue;
    }
    if (tag === 4) {
      // radial-gradient polygon: the truck's headlight beams + brake glow. Fill the polygon path with a
      // radial gradient centred at (cx,cy) radius r — bright translucent core fading to the edge colour.
      const cCol = u32[w++], eCol = u32[w++];
      const cx = f32[w++], cy = f32[w++], r = f32[w++], n = u32[w++];
      ctx.beginPath();
      ctx.moveTo(f32[w], f32[w + 1]); w += 2;
      for (let i = 1; i < n; i++) { ctx.lineTo(f32[w], f32[w + 1]); w += 2; }
      ctx.closePath();
      if (r >= 0.5) {
        const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
        g.addColorStop(0, rgba(cCol));
        g.addColorStop(1, rgba(eCol));
        ctx.fillStyle = g;
        ctx.fill();
      }
      continue;
    }
    if (tag === 5) {
      // 2-stop LINEAR-gradient polygon (the bull's flat shading panels): stop 0 at (ax,ay), stop 1 at (bx,by).
      const c0 = u32[w++], c1 = u32[w++], o0 = f32[w++], o1 = f32[w++];
      const ax = f32[w++], ay = f32[w++], bx = f32[w++], by = f32[w++], n = u32[w++];
      ctx.beginPath();
      ctx.moveTo(f32[w], f32[w + 1]); w += 2;
      for (let i = 1; i < n; i++) { ctx.lineTo(f32[w], f32[w + 1]); w += 2; }
      ctx.closePath();
      const g = ctx.createLinearGradient(ax, ay, bx, by);
      g.addColorStop(stopAt(o0), rgba(c0));
      g.addColorStop(stopAt(o1, o0), rgba(c1));
      ctx.fillStyle = g;
      ctx.fill();
      continue;
    }
    if (tag === 6) {
      // 2-stop RADIAL-gradient polygon (the bull's rounded muscle shading): a unit circle at (cx,cy) mapped
      // to an ellipse by axes u,v. Clip to the path, map unit space → the ellipse, fill a unit radial gradient.
      const c0 = u32[w++], c1 = u32[w++], o0 = f32[w++], o1 = f32[w++];
      const cx = f32[w++], cy = f32[w++], ux = f32[w++], uy = f32[w++], vx = f32[w++], vy = f32[w++], n = u32[w++];
      ctx.beginPath();
      ctx.moveTo(f32[w], f32[w + 1]); w += 2;
      for (let i = 1; i < n; i++) { ctx.lineTo(f32[w], f32[w + 1]); w += 2; }
      ctx.closePath();
      if (Math.abs(ux * vy - uy * vx) < 1e-4) { ctx.fillStyle = rgba(c0); ctx.fill(); continue; } // degenerate → solid
      ctx.save();
      ctx.clip();
      ctx.transform(ux, uy, vx, vy, cx, cy); // unit space → screen ellipse
      const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
      g.addColorStop(stopAt(o0), rgba(c0));
      g.addColorStop(stopAt(o1, o0), rgba(c1));
      ctx.fillStyle = g;
      ctx.fillRect(-1e4, -1e4, 2e4, 2e4); // clipped to the path; beyond r=1 the gradient clamps to stop 1
      ctx.restore();
      continue;
    }
    const color = u32[w++];
    const strength = tag === 1 ? f32[w++] : 0; // tag 1 carries a per-poly shade strength (0..1)
    const n = u32[w++];
    const start = w;
    if (tag === 1 && strength > 0) {
      let minX = Infinity, maxX = -Infinity;
      for (let i = 0; i < n; i++) { const x = f32[start + i * 2]; if (x < minX) minX = x; if (x > maxX) maxX = x; }
      if (maxX - minX < 1) {
        ctx.fillStyle = hex(color);
      } else {
        // strength scales the shade: 1 -> 0.6/1.25 (full), 0 -> flat. Lets crown shading fade with distance.
        const g = ctx.createLinearGradient(minX, 0, maxX, 0);
        g.addColorStop(0, shade(color, 1 - 0.4 * strength));
        g.addColorStop(0.5, shade(color, 1 + 0.25 * strength));
        g.addColorStop(1, shade(color, 1 - 0.4 * strength));
        ctx.fillStyle = g;
      }
    } else {
      ctx.fillStyle = hex(color);
    }
    ctx.beginPath();
    ctx.moveTo(f32[w], f32[w + 1]); w += 2;
    for (let i = 1; i < n; i++) { ctx.lineTo(f32[w], f32[w + 1]); w += 2; }
    ctx.closePath();
    ctx.fill();
  }
  return cmds;
}

// The frame-budget HUD: zig can't time itself (no clock in wasm-freestanding), so the
// only place to measure the 16.7ms/60fps budget is here, where performance.now() lives
// and where BOTH halves — wasm geometry compute and canvas blit — can be timed. We keep
// a rolling window so the displayed max catches the worst recent frame, not just now.
const BUDGET_MS = 1000 / 60;
const WINDOW = 90; // ~1.5s of frames
const hud = { wasm: [], blit: [], total: [] };
function hudPush(arr, v) { arr.push(v); if (arr.length > WINDOW) arr.shift(); }
function hudMax(arr) { let m = 0; for (const v of arr) if (v > m) m = v; return m; }
function hudAvg(arr) { if (!arr.length) return 0; let s = 0; for (const v of arr) s += v; return s / arr.length; }

function drawHud(ctx, bufBytes, bufCap, cmds, step, seg, debug) {
  // Off by default — prod is completely clean (nothing drawn). D toggles the dev
  // overlay on; the bottom-of-page hint is where it stays discoverable.
  if (!debug) return;
  ctx.save();
  ctx.font = '12px ui-monospace,Menlo,monospace';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  // Color the total line by the RATE of missed frames, not the single worst one: a lone
  // GC/jank spike shouldn't pin it red for the whole window. green = no misses; amber =
  // occasional (≤20%, likely jank); red = consistently over budget (a real problem).
  const totMax = hudMax(hud.total);
  let overCount = 0;
  for (const v of hud.total) if (v > BUDGET_MS) overCount++;
  const frac = hud.total.length ? overCount / hud.total.length : 0;
  const fill = bufCap ? (bufBytes / bufCap) : 0;
  const lines = [
    `t ${step}   seg ${seg}/19`,
    `wasm ${hudAvg(hud.wasm).toFixed(2)}ms  blit ${hudAvg(hud.blit).toFixed(2)}ms`,
    `total ${hudAvg(hud.total).toFixed(2)}ms  max ${totMax.toFixed(2)}  over ${overCount}/${hud.total.length} (${BUDGET_MS.toFixed(2)})`,
    `${cmds} draw-calls   buf-peak ${(bufBytes / 1024).toFixed(1)}/${(bufCap / 1024).toFixed(0)} KiB (${(fill * 100).toFixed(0)}%)`,
    `D · hide debug`,
  ];
  const totColor = frac === 0 ? '#9be29b' : frac <= 0.2 ? '#ffd166' : '#ff6b6b';
  ctx.fillStyle = 'rgba(0,0,0,0.55)';
  ctx.fillRect(8, 8, 290, 8 + lines.length * 16 + 4);
  for (let i = 0; i < lines.length; i++) {
    ctx.fillStyle = (i === 0) ? '#ffe14d'      // the step `t`, highlighted — it's what Steve reports
      : (i === 2) ? totColor                   // the total-frame-time line, coloured by miss rate
      : (i === 3 && fill > 0.9) ? '#ffd166'     // the buffer line, amber when nearly full
      : (i === 4) ? '#8a93a0'                   // the dim D-toggle hint
      : '#cfe0f0';
    ctx.fillText(lines[i], 14, 14 + i * 16);
  }
  ctx.restore();
}

async function main() {
  document.body.style.cssText =
    'margin:0;background:#0b0b0d;height:100vh;display:flex;flex-direction:column;' +
    'align-items:center;justify-content:center;font-family:ui-monospace,Menlo,monospace;color:#cfd2d6';
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  canvas.style.cssText = 'display:block;background:#000;box-shadow:0 10px 40px rgba(0,0,0,0.6)';
  document.body.appendChild(canvas);
  const hint = document.createElement('div');
  hint.textContent = 'SPACE pause/resume · ↑/↓ step · J next intersection · D debug overlay';
  hint.style.cssText = 'margin-top:10px;font-size:12px;color:#9aa0a6;letter-spacing:0.4px';
  document.body.appendChild(hint);
  const ctx = canvas.getContext('2d');

  // a loading spinner over the canvas while the wasm loads + the first frames warm up (see the warmup
  // before the loop). The cold first frames blow the 16.7ms budget, which read as a stutter at startup.
  const spinStyle = document.createElement('style');
  spinStyle.textContent = '@keyframes sg-spin{to{transform:rotate(360deg)}}';
  document.head.appendChild(spinStyle);
  const spinner = document.createElement('div');
  spinner.style.cssText = 'position:fixed;inset:0;z-index:10;display:flex;flex-direction:column;gap:16px;' +
    'align-items:center;justify-content:center;background:#0b0b0d;color:#9aa0a6;' +
    'font-family:ui-monospace,Menlo,monospace;font-size:13px;letter-spacing:0.5px';
  spinner.innerHTML = '<div style="width:42px;height:42px;border:4px solid #2a2c30;' +
    'border-top-color:#cfd2d6;border-radius:50%;animation:sg-spin 0.8s linear infinite"></div>' +
    '<div>Warming up the drive…</div>';
  document.body.appendChild(spinner);

  const { instance } = await WebAssembly.instantiateStreaming(fetch('/driving/safari.wasm'), {});
  const { renderFrame, bufPtr, memory, advance, back, riderTilt, bufHighWater, bufCap,
          skyTop, skyHorizon, sunVisible, sunX, sunY, sunScale, clock, riderSeg } = instance.exports;
  const capBytes = bufCap();

  // The wasm owns the rider state; we drive it. The camera rolls with the bike's lean
  // (riderTilt) — the whole world banks into a turn, like main.ts's ctx.rotate(-tilt).
  let auto = true;
  let debug = false; // the dev overlay (frame-budget HUD) — off by default (prod is clean); D toggles it.

  function draw() {
    // time the two halves separately: wasm geometry compute, then canvas blit.
    const t0 = performance.now();
    const len = renderFrame();
    const t1 = performance.now();
    ctx.save();
    ctx.translate(W / 2, H / 2);
    ctx.rotate(-riderTilt());
    ctx.translate(-W / 2, -H / 2);
    drawBackground(ctx, hex(skyTop()), hex(skyHorizon()));
    if (sunVisible()) drawSun(ctx, sunX(), sunY(), sunScale());
    const cmds = blit(ctx, memory, bufPtr(), len);
    ctx.restore();
    const t2 = performance.now();
    hudPush(hud.wasm, t1 - t0);
    hudPush(hud.blit, t2 - t1);
    hudPush(hud.total, t2 - t0);
    drawHud(ctx, bufHighWater(), capBytes, cmds, clock(), riderSeg() + 1, debug); // unrolled overlay, on top
  }
  function loop() {
    if (auto) { advance(); draw(); }
    requestAnimationFrame(loop);
  }

  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') { auto = !auto; e.preventDefault(); }
    else if (e.code === 'ArrowUp') { auto = false; advance(); draw(); e.preventDefault(); }
    else if (e.code === 'ArrowDown') { auto = false; back(); draw(); e.preventDefault(); }
    else if (e.code === 'KeyJ') {
      // jump one intersection: run the REAL drive (advance steps) until the rider crosses into the next
      // segment, landing at its start — velocity, acceleration, and the day→dusk dimming all faithful, as
      // if actually ridden. Repeated presses walk the route a segment at a time; pause after so you can
      // inspect (e.g. the truck close-up once it's night). Mirrors the J hotkey in main.ts.
      if (!e.repeat) {
        auto = false;
        const from = riderSeg();
        let guard = 0;
        while (riderSeg() === from && guard++ < 200000) advance();
        draw();
      }
      e.preventDefault();
    } else if (e.code === 'KeyD') {
      // toggle the dev overlay (frame-budget HUD). Off by default; redraw now so it
      // responds even while paused.
      if (!e.repeat) { debug = !debug; draw(); }
      e.preventDefault();
    }
  });

  // Warm the JIT + canvas BEFORE the live loop and behind the spinner: the first few frames are cold
  // (gradient objects, first paints) and overshoot the 16.7ms budget, which looked like a startup stutter.
  // Render the opening frame across a few rAF ticks (so the spinner keeps spinning) until one comes in
  // under budget — then reveal and start. draw() doesn't advance, so no animation is skipped.
  await new Promise((resolve) => {
    let i = 0;
    (function warm() {
      const t = performance.now();
      draw();
      const dt = performance.now() - t;
      if (++i >= 30 || (i >= 4 && dt < 12)) resolve();
      else requestAnimationFrame(warm);
    })();
  });
  spinner.remove();

  draw();
  requestAnimationFrame(loop);
}

main();
