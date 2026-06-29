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

// Walk the draw buffer [base, base+len) and fill each polygon. Two views over the
// SAME words: u32 for color/count, f32 for the coordinate bit patterns.
function blit(ctx, mem, base, len) {
  const u32 = new Uint32Array(mem.buffer, base, len / 4);
  const f32 = new Float32Array(mem.buffer, base, len / 4);
  let w = 0;
  while (w * 4 < len) {
    const color = u32[w++];
    const n = u32[w++];
    ctx.fillStyle = hex(color);
    ctx.beginPath();
    ctx.moveTo(f32[w], f32[w + 1]); w += 2;
    for (let i = 1; i < n; i++) { ctx.lineTo(f32[w], f32[w + 1]); w += 2; }
    ctx.closePath();
    ctx.fill();
  }
}

// constant cruise speed (m/s), frame-rate-independent so the velocity is truly
// steady for perception tests — NOT the game's accelerating V_BASE→V_MAX ramp.
const CRUISE_MPS = 30;

async function main() {
  document.body.style.cssText =
    'margin:0;background:#0b0b0d;height:100vh;display:flex;align-items:center;justify-content:center';
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  canvas.style.cssText = 'display:block;background:#000;box-shadow:0 10px 40px rgba(0,0,0,0.6)';
  document.body.appendChild(canvas);
  const ctx = canvas.getContext('2d');

  const { instance } = await WebAssembly.instantiateStreaming(fetch('/driving/safari.wasm'), {});
  const { renderFrame, bufPtr, memory, segLength } = instance.exports;

  // cruise straight down seg1 at a constant velocity, looping at the segment end.
  // The camera pose is just (along, across, yaw); here across=0, yaw=0 — dead level,
  // centred. dt-based advance keeps the speed constant regardless of refresh rate.
  const length = segLength();
  let along = 0, lastT = 0;
  function frame(t) {
    const dt = lastT ? (t - lastT) / 1000 : 0; // seconds since the last frame
    lastT = t;
    along += CRUISE_MPS * dt;
    if (along >= length) along -= length; // loop the straight
    const len = renderFrame(along, 0.0, 0.0);
    drawBackground(ctx);
    blit(ctx, memory, bufPtr(), len);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

main();
