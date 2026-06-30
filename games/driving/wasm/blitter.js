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
  ctx.fillRect(W / 2 - BIG, H / 2, 2 * BIG, BIG);
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

// shade a 0xRRGGBB by a brightness factor (clamped) -> "rgb(r,g,b)".
function shade(c, f) {
  const r = Math.min(255, Math.round(((c >> 16) & 255) * f));
  const g = Math.min(255, Math.round(((c >> 8) & 255) * f));
  const b = Math.min(255, Math.round((c & 255) * f));
  return `rgb(${r},${g},${b})`;
}

// Emoji are expensive to rasterise every frame, so render each glyph ONCE to an
// offscreen sprite (keyed by codepoint) and reuse it — drawImage beats fillText.
const spriteCache = new Map();
function emojiSprite(cp) {
  let c = spriteCache.get(cp);
  if (c) return c;
  c = document.createElement('canvas');
  c.width = 96; c.height = 96;
  const g = c.getContext('2d');
  g.font = Math.round(96 * 0.8) + 'px serif';
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText(String.fromCodePoint(cp), 48, 48 + 96 * 0.06);
  spriteCache.set(cp, c);
  return c;
}

// Walk the draw buffer [base, base+len). Views over the SAME words: u32 for
// tag/color/count, f32 for coordinate bit patterns. tag 0 = solid polygon; tag 1 =
// round-gradient polygon (cylinder/cone shading); tag 2 = emoji billboard.
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
    if (tag === 2) {
      const cp = u32[w++], flip = u32[w++];
      const x = f32[w++], y = f32[w++], size = f32[w++];
      if (size >= 1) {
        ctx.save();
        ctx.translate(x, y);
        if (flip) ctx.scale(-1, 1); // most animal emoji face left by default
        ctx.drawImage(emojiSprite(cp), -size / 2, -size, size, size); // square, bottom on the ground
        ctx.restore();
      }
      continue;
    }
    const color = u32[w++];
    const n = u32[w++];
    const start = w;
    if (tag === 1) {
      let minX = Infinity, maxX = -Infinity;
      for (let i = 0; i < n; i++) { const x = f32[start + i * 2]; if (x < minX) minX = x; if (x > maxX) maxX = x; }
      if (maxX - minX < 1) {
        ctx.fillStyle = hex(color);
      } else {
        const g = ctx.createLinearGradient(minX, 0, maxX, 0);
        g.addColorStop(0, shade(color, 0.6));
        g.addColorStop(0.5, shade(color, 1.25));
        g.addColorStop(1, shade(color, 0.6));
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

function drawHud(ctx, bufBytes, bufCap, cmds) {
  // always on for now — hiding it is polish for when the port is close to done.
  // Color the total line by the RATE of missed frames, not the single worst one: a lone
  // GC/jank spike shouldn't pin it red for the whole window. green = no misses; amber =
  // occasional (≤20%, likely jank); red = consistently over budget (a real problem).
  const totMax = hudMax(hud.total);
  let overCount = 0;
  for (const v of hud.total) if (v > BUDGET_MS) overCount++;
  const frac = hud.total.length ? overCount / hud.total.length : 0;
  const fill = bufCap ? (bufBytes / bufCap) : 0;
  const lines = [
    `wasm ${hudAvg(hud.wasm).toFixed(2)}ms  blit ${hudAvg(hud.blit).toFixed(2)}ms`,
    `total ${hudAvg(hud.total).toFixed(2)}ms  max ${totMax.toFixed(2)}  over ${overCount}/${hud.total.length} (${BUDGET_MS.toFixed(2)})`,
    `cmds ${cmds}   buf-peak ${(bufBytes / 1024).toFixed(1)}/${(bufCap / 1024).toFixed(0)} KiB (${(fill * 100).toFixed(0)}%)`,
  ];
  const totColor = frac === 0 ? '#9be29b' : frac <= 0.2 ? '#ffd166' : '#ff6b6b';
  ctx.save();
  ctx.font = '12px ui-monospace,Menlo,monospace';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  ctx.fillStyle = 'rgba(0,0,0,0.55)';
  ctx.fillRect(8, 8, 290, 8 + lines.length * 16 + 4);
  for (let i = 0; i < lines.length; i++) {
    ctx.fillStyle = (i === 1) ? totColor
      : (i === 2 && fill > 0.9) ? '#ffd166'
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
  hint.textContent = 'SPACE pause/resume · ↑ step forward · ↓ step back';
  hint.style.cssText = 'margin-top:10px;font-size:12px;color:#9aa0a6;letter-spacing:0.4px';
  document.body.appendChild(hint);
  const ctx = canvas.getContext('2d');

  const { instance } = await WebAssembly.instantiateStreaming(fetch('/driving/safari.wasm'), {});
  const { renderFrame, bufPtr, memory, advance, back, riderTilt, bufHighWater, bufCap,
          skyTop, skyHorizon, sunVisible, sunX, sunY, sunScale } = instance.exports;
  const capBytes = bufCap();

  // The wasm owns the rider state; we drive it. The camera rolls with the bike's lean
  // (riderTilt) — the whole world banks into a turn, like main.ts's ctx.rotate(-tilt).
  let auto = true;

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
    drawHud(ctx, bufHighWater(), capBytes, cmds); // unrolled overlay, on top
  }
  function loop() {
    if (auto) { advance(); draw(); }
    requestAnimationFrame(loop);
  }

  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') { auto = !auto; e.preventDefault(); }
    else if (e.code === 'ArrowUp') { auto = false; advance(); draw(); e.preventDefault(); }
    else if (e.code === 'ArrowDown') { auto = false; back(); draw(); e.preventDefault(); }
  });

  draw();
  requestAnimationFrame(loop);
}

main();
