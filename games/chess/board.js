// board — the ONLY non-zig piece of the Knight's Tour, and deliberately dumb.
// It owns no search logic: knight.wasm holds the precomputed move graph, the
// DFS machine, and the scrubbable event tape; this just draws the board state
// the wasm exposes (64 bytes of move numbers) and forwards input — click to
// start a tour, hover to see the graph, transport controls to play/scrub.
// Plain hand-written JS (no TS, no bundler).

const SQ = 68, W = SQ * 8;
const LIGHT = '#f0d9b5', DARK = '#b58863';

async function main() {
  document.body.style.cssText =
    'margin:0;background:#0b0b0d;min-height:100vh;display:flex;flex-direction:column;' +
    'align-items:center;justify-content:center;gap:12px;' +
    'font-family:ui-monospace,Menlo,monospace;color:#cfd2d6';

  const title = document.createElement('div');
  title.textContent = "Knight's Tour";
  title.style.cssText = 'font-size:20px;letter-spacing:1px;color:#e8e2d6';
  document.body.appendChild(title);

  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = W;
  canvas.style.cssText = 'display:block;box-shadow:0 10px 40px rgba(0,0,0,0.6);cursor:pointer';
  document.body.appendChild(canvas);
  const ctx = canvas.getContext('2d');

  const status = document.createElement('div');
  status.style.cssText = 'font-size:13px;color:#9aa0a6;min-height:18px';
  document.body.appendChild(status);

  // transport row: rewind ‹ step · play/pause · step › + the speed slider
  const controls = document.createElement('div');
  controls.style.cssText = 'display:flex;align-items:center;gap:8px';
  const btnCss = 'background:#1d1f24;color:#cfd2d6;border:1px solid #33363d;border-radius:4px;' +
    'padding:5px 12px;font:13px ui-monospace,Menlo,monospace;cursor:pointer';
  function button(label, onclick) {
    const b = document.createElement('button');
    b.textContent = label;
    b.style.cssText = btnCss;
    b.addEventListener('click', onclick);
    controls.appendChild(b);
    return b;
  }
  const rewindBtn = button('⏪ rewind', () => setMode(mode === -1 ? 0 : -1));
  button('◂ step', () => { setMode(0); wasm.stepBack(); });
  const playBtn = button('▶ play', () => setMode(mode === 1 ? 0 : 1));
  button('step ▸', () => { setMode(0); wasm.stepForward(); });
  const speed = document.createElement('input');
  speed.type = 'range';
  speed.min = '0'; speed.max = '17'; speed.value = '3'; // steps/s = 2 << value
  speed.style.cssText = 'width:140px;accent-color:#8a93a0';
  const speedLabel = document.createElement('span');
  speedLabel.style.cssText = 'font-size:12px;color:#9aa0a6;width:80px';
  controls.appendChild(speed);
  controls.appendChild(speedLabel);
  document.body.appendChild(controls);

  const hint = document.createElement('div');
  hint.textContent = 'hover · knight moves    click · start a tour there    SPACE play/pause · ←/→ step';
  hint.style.cssText = 'font-size:12px;color:#6d7278;letter-spacing:0.4px';
  document.body.appendChild(hint);
  const legend = document.createElement('div');
  legend.textContent = 'red · a knight was retracted here    indigo · cut off from the tour';
  legend.style.cssText = 'font-size:12px;color:#6d7278;letter-spacing:0.4px';
  document.body.appendChild(legend);

  const { instance } = await WebAssembly.instantiateStreaming(fetch('/chess/knight.wasm'), {});
  const wasm = instance.exports;
  const board = new Int8Array(wasm.memory.buffer, wasm.boardPtr(), 64);
  const deadEnd = new Uint8Array(wasm.memory.buffer, wasm.deadEndPtr(), 64);
  const impossible = new Uint8Array(wasm.memory.buffer, wasm.impossiblePtr(), 64);
  // the precomputed knight graph, read once — the hover highlights ARE this graph
  const stride = wasm.adjStride();
  const adj = new Uint8Array(wasm.memory.buffer, wasm.adjPtr(), 64 * stride);
  const adjCounts = new Uint8Array(wasm.memory.buffer, wasm.adjCountsPtr(), 64);

  let mode = 0; // 0 paused · 1 playing · -1 rewinding
  let hover = -1; // hovered square or -1
  let acc = 0; // fractional steps owed to the clock

  function setMode(m) {
    mode = m;
    acc = 0;
    playBtn.textContent = mode === 1 ? '⏸ pause' : '▶ play';
    rewindBtn.textContent = mode === -1 ? '⏸ pause' : '⏪ rewind';
  }
  function stepsPerSec() { return 2 << Number(speed.value); }

  // square index <-> canvas position (rank 8 drawn at the top, a1 lower-left)
  function sqX(sq) { return (sq % 8) * SQ; }
  function sqY(sq) { return (7 - (sq >> 3)) * SQ; }
  function sqAt(px, py) {
    const c = Math.floor(px / SQ), r = 7 - Math.floor(py / SQ);
    return (c < 0 || c > 7 || r < 0 || r > 7) ? -1 : r * 8 + c;
  }

  function draw() {
    const knights = wasm.piecesOnBoard();
    // squares + coordinates (letters along rank 1, numbers up file a)
    for (let sq = 0; sq < 64; sq++) {
      const x = sqX(sq), y = sqY(sq);
      const light = ((sq >> 3) + (sq & 7)) % 2 === 1;
      ctx.fillStyle = light ? LIGHT : DARK;
      ctx.fillRect(x, y, SQ, SQ);
      ctx.fillStyle = light ? DARK : LIGHT;
      ctx.font = '10px ui-monospace,Menlo,monospace';
      if (sq >> 3 === 0) {
        ctx.textAlign = 'right'; ctx.textBaseline = 'bottom';
        ctx.fillText('abcdefgh'[sq & 7], x + SQ - 3, y + SQ - 2);
      }
      if ((sq & 7) === 0) {
        ctx.textAlign = 'left'; ctx.textBaseline = 'top';
        ctx.fillText(String((sq >> 3) + 1), x + 3, y + 2);
      }
    }
    // failure overlays (see knight.zig computeOverlays): red = a knight was
    // placed here, found doomed, and pulled off — accumulating through
    // removal cascades, cleared only when the search re-enters the square.
    // Indigo = provably unreachable from the head through empty squares —
    // the stronger fact, so it wins where both hold.
    wasm.computeOverlays();
    for (let sq = 0; sq < 64; sq++) {
      if (impossible[sq]) {
        ctx.fillStyle = 'rgba(80,70,190,0.45)';
        ctx.fillRect(sqX(sq), sqY(sq), SQ, SQ);
      } else if (deadEnd[sq]) {
        ctx.fillStyle = 'rgba(190,40,40,0.5)';
        ctx.fillRect(sqX(sq), sqY(sq), SQ, SQ);
      }
    }
    // the head knight's square glows so the search frontier is easy to track
    if (knights > 0) {
      for (let sq = 0; sq < 64; sq++) {
        if (board[sq] === knights - 1) {
          ctx.fillStyle = 'rgba(255,214,102,0.5)';
          ctx.fillRect(sqX(sq), sqY(sq), SQ, SQ);
        }
      }
    }
    // hover: outline the square, mark its graph neighbors (dot = open, ring = occupied)
    if (hover >= 0) {
      ctx.strokeStyle = 'rgba(70,140,220,0.9)';
      ctx.lineWidth = 3;
      ctx.strokeRect(sqX(hover) + 1.5, sqY(hover) + 1.5, SQ - 3, SQ - 3);
      for (let i = 0; i < adjCounts[hover]; i++) {
        const nb = adj[hover * stride + i];
        const cx = sqX(nb) + SQ / 2, cy = sqY(nb) + SQ / 2;
        ctx.beginPath();
        if (board[nb] < 0) {
          ctx.fillStyle = 'rgba(60,160,90,0.9)';
          ctx.arc(cx, cy, SQ * 0.13, 0, Math.PI * 2);
          ctx.fill();
        } else {
          ctx.strokeStyle = 'rgba(200,60,60,0.85)';
          ctx.lineWidth = 3;
          ctx.arc(cx, cy, SQ * 0.3, 0, Math.PI * 2);
          ctx.stroke();
        }
      }
    }
    // the knights, with their move numbers
    for (let sq = 0; sq < 64; sq++) {
      const n = board[sq];
      if (n < 0) continue;
      const x = sqX(sq), y = sqY(sq);
      ctx.fillStyle = n === knights - 1 ? '#7a1f1f' : '#22232a';
      ctx.font = `${Math.round(SQ * 0.72)}px serif`;
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText('♞', x + SQ / 2, y + SQ / 2 + 3);
      ctx.fillStyle = 'rgba(20,20,25,0.65)';
      ctx.font = 'bold 11px ui-monospace,Menlo,monospace';
      ctx.textAlign = 'right'; ctx.textBaseline = 'top';
      ctx.fillText(String(n + 1), x + SQ - 3, y + 2);
    }
    drawStatus(knights);
  }

  function drawStatus(knights) {
    speedLabel.textContent = stepsPerSec().toLocaleString() + '/s';
    if (!wasm.isStarted()) {
      status.textContent = 'click a square to place the first knight';
      return;
    }
    const cur = wasm.cursor(), len = wasm.tapeLen();
    let s = `${knights}/64 knights · step ${cur.toLocaleString()}` +
      (cur < len ? ` / ${len.toLocaleString()}` : '') +
      ` · deepest ${wasm.bestDepth()}`;
    if (cur === len) {
      if (wasm.isSolved()) s += ' — tour complete!';
      else if (wasm.isExhausted()) s += ' — no tour from here (search exhausted)';
    }
    status.textContent = s;
  }

  canvas.addEventListener('mousemove', (e) => {
    const r = canvas.getBoundingClientRect();
    hover = sqAt(e.clientX - r.left, e.clientY - r.top);
  });
  canvas.addEventListener('mouseleave', () => { hover = -1; });
  canvas.addEventListener('click', (e) => {
    const r = canvas.getBoundingClientRect();
    const sq = sqAt(e.clientX - r.left, e.clientY - r.top);
    if (sq < 0) return;
    wasm.init(sq);
    setMode(1);
  });
  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') { setMode(mode === 1 ? 0 : 1); e.preventDefault(); }
    else if (e.code === 'ArrowRight') { setMode(0); wasm.stepForward(); e.preventDefault(); }
    else if (e.code === 'ArrowLeft') { setMode(0); wasm.stepBack(); e.preventDefault(); }
  });

  let lastT = performance.now();
  function loop(t) {
    const dt = Math.min((t - lastT) / 1000, 0.1); // clamp a slept tab's backlog
    lastT = t;
    if (mode !== 0) {
      acc += stepsPerSec() * dt;
      let n = Math.floor(acc);
      acc -= n;
      while (n-- > 0) {
        if (!(mode === 1 ? wasm.stepForward() : wasm.stepBack())) { setMode(0); break; }
      }
    }
    draw();
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
}

main();
