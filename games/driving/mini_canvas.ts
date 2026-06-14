// mini_canvas.ts — a tiny, DEPENDENCY-FREE software rasterizer implementing the subset of
// CanvasRenderingContext2D that the driving game's *isolated* drawing code uses: the affine
// transform stack, path building (move/line/quad/arc), and fill/stroke with solid/rgba colours.
// NO text, gradients, clip, or images — those are the full scene's job and need a browser.
//
// The point: let the REAL drawing code (e.g. cat_anatomy.drawCat) render into an offscreen
// buffer we encode as a PNG, so the cat can be SEEN without a browser (see snap_cat.ts). This
// is NOT a re-implementation of the cat — the cat's own code runs unchanged against this shim.
//
// Pixels accumulate at SS× resolution and box-downsample on toPNG() for anti-aliasing. The
// matrix is the canvas affine [a,b,c,d,e,f]: device = (a·x + c·y + e, b·x + d·y + f).

import zlib from 'node:zlib';

type RGBA = [number, number, number, number];   // 0..255, alpha 0..1
type Pt = [number, number];
type Mat = [number, number, number, number, number, number];

interface State {
  m: Mat;
  fillStyle: string;
  strokeStyle: string;
  lineWidth: number;
  lineJoin: string;   // accepted; always rendered round (good enough for our art)
  lineCap: string;
}

const SS = 4;          // supersample factor (AA via box downsample)
const ARC_SEGS = 64;   // segments per full circle when tessellating an arc
const QUAD_SEGS = 14;  // segments when tessellating a quadratic bezier
const DISC_SEGS = 20;  // polygon sides for a round cap/join disc

function parseColor(s: string): RGBA {
  s = s.trim();
  if (s[0] === '#') {
    let hex = s.slice(1);
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    const n = parseInt(hex, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 1];
  }
  const m = s.match(/rgba?\(([^)]+)\)/);
  if (m) {
    const p = m[1].split(',').map((x) => parseFloat(x));
    return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
  }
  return [0, 0, 0, 1];
}

// quadratic bezier point at t
function quadAt(p0: Pt, p1: Pt, p2: Pt, t: number): Pt {
  const u = 1 - t;
  return [u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]];
}

export class MiniCanvas {
  readonly width: number;
  readonly height: number;
  private dw: number;
  private dh: number;
  private buf: Uint8ClampedArray;   // RGB at device (SS) resolution, opaque
  private st: State;
  private stack: State[] = [];
  private curUser: Pt | null = null;   // current point in USER space (for quad/arc tessellation)
  private subs: Pt[][] = [];           // subpaths, points already in DEVICE space
  private sub: Pt[] | null = null;

  constructor(width: number, height: number, background = '#1b1d22') {
    this.width = width;
    this.height = height;
    this.dw = width * SS;
    this.dh = height * SS;
    this.buf = new Uint8ClampedArray(this.dw * this.dh * 3);
    this.st = { m: [SS, 0, 0, SS, 0, 0], fillStyle: '#000', strokeStyle: '#000', lineWidth: 1, lineJoin: 'round', lineCap: 'round' };
    const [r, g, b] = parseColor(background);
    for (let i = 0; i < this.dw * this.dh; i++) { this.buf[i * 3] = r; this.buf[i * 3 + 1] = g; this.buf[i * 3 + 2] = b; }
  }

  // ---- style (accessor props so `ctx.fillStyle = ...` works) ----
  get fillStyle(): string { return this.st.fillStyle; }
  set fillStyle(v: string) { this.st.fillStyle = v; }
  get strokeStyle(): string { return this.st.strokeStyle; }
  set strokeStyle(v: string) { this.st.strokeStyle = v; }
  get lineWidth(): number { return this.st.lineWidth; }
  set lineWidth(v: number) { this.st.lineWidth = v; }
  get lineJoin(): string { return this.st.lineJoin; }
  set lineJoin(v: string) { this.st.lineJoin = v; }
  get lineCap(): string { return this.st.lineCap; }
  set lineCap(v: string) { this.st.lineCap = v; }

  // ---- transform ----
  save(): void { this.stack.push({ ...this.st, m: [...this.st.m] as Mat }); }
  restore(): void { const s = this.stack.pop(); if (s) this.st = s; }
  translate(tx: number, ty: number): void {
    const [a, b, c, d, e, f] = this.st.m;
    this.st.m = [a, b, c, d, e + a * tx + c * ty, f + b * tx + d * ty];
  }
  scale(sx: number, sy: number): void {
    const [a, b, c, d, e, f] = this.st.m;
    this.st.m = [a * sx, b * sx, c * sy, d * sy, e, f];
  }
  rotate(r: number): void {
    const cos = Math.cos(r), sin = Math.sin(r);
    const [a, b, c, d, e, f] = this.st.m;
    this.st.m = [a * cos + c * sin, b * cos + d * sin, c * cos - a * sin, d * cos - b * sin, e, f];
  }
  private apply(x: number, y: number): Pt {
    const [a, b, c, d, e, f] = this.st.m;
    return [a * x + c * y + e, b * x + d * y + f];
  }
  private scaleFactor(): number {
    const [a, b, c, d] = this.st.m;
    return Math.sqrt(Math.abs(a * d - b * c));   // device px per user unit (uniform-ish)
  }

  // ---- path ----
  beginPath(): void { this.subs = []; this.sub = null; this.curUser = null; }
  moveTo(x: number, y: number): void { this.sub = [this.apply(x, y)]; this.subs.push(this.sub); this.curUser = [x, y]; }
  lineTo(x: number, y: number): void {
    if (!this.sub) { this.moveTo(x, y); return; }
    this.sub.push(this.apply(x, y));
    this.curUser = [x, y];
  }
  quadraticCurveTo(cx: number, cy: number, x: number, y: number): void {
    const p0 = this.curUser ?? [x, y];
    for (let i = 1; i <= QUAD_SEGS; i++) {
      const p = quadAt(p0, [cx, cy], [x, y], i / QUAD_SEGS);
      this.lineTo(p[0], p[1]);
    }
    this.curUser = [x, y];
  }
  arc(cx: number, cy: number, r: number, a0: number, a1: number, ccw = false): void {
    const full = Math.abs(a1 - a0) >= Math.PI * 2 - 1e-6;
    let span = a1 - a0;
    if (ccw && span > 0) span -= Math.PI * 2;
    if (!ccw && span < 0) span += Math.PI * 2;
    const n = Math.max(2, Math.ceil((Math.abs(span) / (Math.PI * 2)) * ARC_SEGS));
    for (let i = 0; i <= n; i++) {
      const a = a0 + span * (i / n);
      const x = cx + r * Math.cos(a), y = cy + r * Math.sin(a);
      if (i === 0 && !this.sub) this.moveTo(x, y); else this.lineTo(x, y);
    }
    if (full && this.sub) this.sub.push([...this.sub[0]]);   // close the ring for a clean stroke
  }
  closePath(): void { if (this.sub && this.sub.length) this.sub.push([...this.sub[0]]); }

  // ---- paint ----
  fill(): void { this.rasterize(this.subs, parseColor(this.st.fillStyle)); }
  stroke(): void {
    const col = parseColor(this.st.strokeStyle);
    const w = (this.st.lineWidth * this.scaleFactor()) / 2;   // half-width in device px
    if (w <= 0) return;
    for (const sp of this.subs) {
      for (let i = 0; i + 1 < sp.length; i++) this.rasterize([segQuad(sp[i], sp[i + 1], w)], col);
      for (const p of sp) this.rasterize([disc(p, w)], col);   // round caps + joins
    }
  }
  fillRect(x: number, y: number, w: number, h: number): void {
    const poly = [this.apply(x, y), this.apply(x + w, y), this.apply(x + w, y + h), this.apply(x, y + h)];
    this.rasterize([poly], parseColor(this.st.fillStyle));
  }

  // scanline fill of the UNION (nonzero winding) of the given device-space polygons.
  private rasterize(polys: Pt[][], col: RGBA): void {
    const [cr, cg, cb, ca] = col;
    if (ca <= 0) return;
    let minY = Infinity, maxY = -Infinity;
    for (const p of polys) for (const v of p) { if (v[1] < minY) minY = v[1]; if (v[1] > maxY) maxY = v[1]; }
    const y0 = Math.max(0, Math.floor(minY)), y1 = Math.min(this.dh - 1, Math.ceil(maxY));
    for (let y = y0; y <= y1; y++) {
      const sy = y + 0.5;
      const xs: { x: number; w: number }[] = [];
      for (const p of polys) {
        const n = p.length;
        for (let i = 0; i < n; i++) {
          const a = p[i], b = p[(i + 1) % n];
          const ay = a[1], by = b[1];
          if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) {
            const t = (sy - ay) / (by - ay);
            xs.push({ x: a[0] + t * (b[0] - a[0]), w: ay < by ? 1 : -1 });
          }
        }
      }
      if (xs.length < 2) continue;
      xs.sort((u, v) => u.x - v.x);
      let acc = 0;
      for (let i = 0; i + 1 < xs.length; i++) {
        acc += xs[i].w;
        if (acc === 0) continue;
        const xa = Math.max(0, Math.ceil(xs[i].x - 0.5));
        const xb = Math.min(this.dw - 1, Math.floor(xs[i + 1].x - 0.5));
        for (let x = xa; x <= xb; x++) {
          const idx = (y * this.dw + x) * 3;
          if (ca >= 1) { this.buf[idx] = cr; this.buf[idx + 1] = cg; this.buf[idx + 2] = cb; }
          else {
            const ia = 1 - ca;
            this.buf[idx] = cr * ca + this.buf[idx] * ia;
            this.buf[idx + 1] = cg * ca + this.buf[idx + 1] * ia;
            this.buf[idx + 2] = cb * ca + this.buf[idx + 2] * ia;
          }
        }
      }
    }
  }

  // ---- output: box-downsample SS→1 and encode a PNG (RGB, color type 2) ----
  toPNG(): Buffer {
    const W = this.width, H = this.height, n = SS * SS;
    const raw = Buffer.alloc(H * (1 + W * 3));
    for (let y = 0; y < H; y++) {
      const rowStart = y * (1 + W * 3);
      raw[rowStart] = 0;   // filter: none
      for (let x = 0; x < W; x++) {
        let r = 0, g = 0, b = 0;
        for (let sy = 0; sy < SS; sy++) {
          for (let sx = 0; sx < SS; sx++) {
            const idx = ((y * SS + sy) * this.dw + (x * SS + sx)) * 3;
            r += this.buf[idx]; g += this.buf[idx + 1]; b += this.buf[idx + 2];
          }
        }
        const o = rowStart + 1 + x * 3;
        raw[o] = Math.round(r / n); raw[o + 1] = Math.round(g / n); raw[o + 2] = Math.round(b / n);
      }
    }
    const idat = zlib.deflateSync(raw);
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;   // 8-bit, RGB
    return Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      pngChunk('IHDR', ihdr), pngChunk('IDAT', idat), pngChunk('IEND', Buffer.alloc(0)),
    ]);
  }
}

// a rectangle (quad) covering the segment A→B with the given half-width
function segQuad(a: Pt, b: Pt, w: number): Pt[] {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const len = Math.hypot(dx, dy) || 1e-6;
  const nx = (-dy / len) * w, ny = (dx / len) * w;
  return [[a[0] + nx, a[1] + ny], [b[0] + nx, b[1] + ny], [b[0] - nx, b[1] - ny], [a[0] - nx, a[1] - ny]];
}

// a filled disc (polygon) for a round cap/join
function disc(c: Pt, r: number): Pt[] {
  const pts: Pt[] = [];
  for (let i = 0; i < DISC_SEGS; i++) {
    const a = (i / DISC_SEGS) * Math.PI * 2;
    pts.push([c[0] + r * Math.cos(a), c[1] + r * Math.sin(a)]);
  }
  return pts;
}

// ---- PNG chunk + CRC32 ----
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function pngChunk(type: string, data: Buffer): Buffer {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}
