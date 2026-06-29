// blitter — the ONLY non-zig piece of the Safari camera, and deliberately dumb.
// It owns no logic: it loads safari.wasm, calls renderFrame(camera pose), and fills
// the polygons zig wrote into linear memory. Every coordinate, color, and paint-order
// decision is zig's; this just walks [color u32][nPoints u32][x f32][y f32]… and fills.
// Plain hand-written JS (no TS, no bundler) — there is nothing here worth typing.

const W = 960, H = 600;

// the static background zig doesn't own (yet): a sky gradient over a grass band.
// The world polygons (mountains/road/trees) paint on top, in zig's order.
function drawBackground(ctx) {
  const g = ctx.createLinearGradient(0, 0, 0, H / 2);
  g.addColorStop(0, '#7ea6d8');
  g.addColorStop(1, '#cfe0f0');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, W, H / 2);
  ctx.fillStyle = '#4a8f43';
  ctx.fillRect(0, H / 2, W, H / 2);
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

// Walk the draw buffer [base, base+len) and fill each polygon. Two views over the
// SAME words: u32 for tag/color/count, f32 for the coordinate bit patterns. tag 1 =
// horizontal round gradient (dark edge → bright centre → dark edge) across the
// polygon's x-extent — the cylinder/cone shading; tag 0 = solid.
function blit(ctx, mem, base, len) {
  const u32 = new Uint32Array(mem.buffer, base, len / 4);
  const f32 = new Float32Array(mem.buffer, base, len / 4);
  let w = 0;
  while (w * 4 < len) {
    const tag = u32[w++];
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

// metres advanced per frame — a CONSTANT step (no V_BASE→V_MAX ramp), so it's a
// steady cruise at the display rate (~30 m/s at 60 Hz) and a single arrow press
// nudges exactly one frame. The "frame" is the unit you step with the arrows.
const STEP_M = 0.5;

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
  const { renderFrame, bufPtr, memory, segCount, segLen } = instance.exports;

  // The animation state is (segment, along) down the looping route, so stepping is a
  // pure function of it — no history stack. across=0, yaw=0: dead level, centred,
  // riding each segment's centre line and rolling over to the next at its end.
  const count = segCount();
  let seg = 0;
  let along = 0;
  let auto = true;

  function step(dir) {
    along += dir * STEP_M;
    while (along >= segLen(seg)) { along -= segLen(seg); seg = (seg + 1) % count; }
    while (along < 0) { seg = (seg - 1 + count) % count; along += segLen(seg); }
  }
  function draw() {
    const len = renderFrame(seg, along, 0.0, 0.0);
    drawBackground(ctx);
    blit(ctx, memory, bufPtr(), len);
  }
  function loop() {
    if (auto) { step(1); draw(); }
    requestAnimationFrame(loop);
  }

  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') { auto = !auto; e.preventDefault(); }
    else if (e.code === 'ArrowUp') { auto = false; step(1); draw(); e.preventDefault(); }
    else if (e.code === 'ArrowDown') { auto = false; step(-1); draw(); e.preventDefault(); }
  });

  draw();
  requestAnimationFrame(loop);
}

main();
