// blitter — the ONLY non-zig piece of the Safari camera, and deliberately dumb.
// It owns no logic: it loads safari.wasm, calls renderFrame(camera pose), and fills
// the polygons zig wrote into linear memory. Every coordinate, color, and paint-order
// decision is zig's; this just walks [color u32][nPoints u32][x f32][y f32]… and fills.
// Plain hand-written JS (no TS, no bundler) — there is nothing here worth typing.

const W = 960, H = 600;

// the static background zig doesn't own (yet): a sky gradient over a grass band,
// drawn OVERSIZED so the rolled (banked) frame's corners stay filled. The world
// polygons (mountains/road/trees) paint on top, in zig's order.
function drawBackground(ctx) {
  const BIG = W + H;
  const g = ctx.createLinearGradient(0, 0, 0, H / 2);
  g.addColorStop(0, '#7ea6d8');
  g.addColorStop(1, '#cfe0f0');
  ctx.fillStyle = g;
  ctx.fillRect(W / 2 - BIG, H / 2 - BIG, 2 * BIG, BIG);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(W / 2 - BIG, H / 2, 2 * BIG, BIG);
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
  while (w * 4 < len) {
    const tag = u32[w++];
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
  const { renderFrame, bufPtr, memory, advance, back, riderTilt } = instance.exports;

  // The wasm owns the rider state; we drive it. The camera rolls with the bike's lean
  // (riderTilt) — the whole world banks into a turn, like main.ts's ctx.rotate(-tilt).
  let auto = true;

  function draw() {
    const len = renderFrame();
    ctx.save();
    ctx.translate(W / 2, H / 2);
    ctx.rotate(-riderTilt());
    ctx.translate(-W / 2, -H / 2);
    drawBackground(ctx);
    blit(ctx, memory, bufPtr(), len);
    ctx.restore();
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
