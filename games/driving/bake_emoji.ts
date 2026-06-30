// bake_emoji.ts — bake the safari/farm emoji critters into hard-coded polygons for the zig→WASM port.
//
// The WASM seam to the blitter is POLYGON-ONLY. Emoji used to be the one exception: a tag-2 "billboard"
// command the blitter rasterised with the browser's emoji font (fillText). That tied the look to whatever
// font the browser shipped AND blocked a native (non-browser) renderer. So we retire it: each critter is
// baked from a vendored Fluent Emoji "Flat" SVG (emoji_svg/*.svg, full-body flat fill-only, MIT) into a flat list
// of filled polygons in the SAME UNIT FRAME the cat uses — feet at y = 0, y up, height 1, facing LEFT —
// and emitted as ordinary tag-0 polygons. critter.zig transforms them to the billboard's screen anchor +
// projected height, exactly like cat.zig draws cat_frames. After this the blitter needs zero emoji code.
//
// SVG → polygons: walk the elements in DOCUMENT ORDER (painter's order — a later <path> paints over an
// earlier one, which is how the eyes/spots sit on the body), tessellate cubic/quadratic curves to line
// segments, turn each subpath into one solid polygon of the element's fill colour. (Our vendored Fluent Flat SVGs use no
// transforms, no arcs, no opacity, no strokes — verified — so the parser stays small. Within-path holes
// aren't modelled; they're rare in these animals and the contact sheet flags any that matter.)
//
// Run via ops/bake_emoji. emoji_frames.zig is GENERATED + committed (like a gold file); re-run after
// changing the vendored SVGs. A validation contact sheet is written to snap/emoji_baked.png — every
// critter should be recognisable (an elephant is an elephant).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { MiniCanvas } from './mini_canvas.ts';

export type Pt = [number, number];
export interface Stop { off: number; rgba: number } // rgba = 0xAARRGGBB (alpha top byte)
// A gradient fill, geometry in whatever coord space the poly's pts are in (SVG, then normalized in lockstep).
// kind 1 = linear (a→b endpoints); kind 2 = radial (unit circle at centre c, mapped to an ellipse by axes u,v).
export interface Grad {
  kind: 1 | 2; s0: Stop; s1: Stop;
  ax: number; ay: number; bx: number; by: number; // linear endpoints
  cx: number; cy: number; ux: number; uy: number; vx: number; vy: number; // radial centre + axes
}
export interface RawPoly { color: number; pts: Pt[]; grad?: Grad } // color 0xRRGGBB (solid), or grad

// the 8 critters, codepoint → zig identifier (must match the codepoints in safari_critter.zig / world.zig).
const CRITTERS: { cp: number; file: string; name: string }[] = [
  { cp: 0x1f986, file: '1f986', name: 'duck' },
  { cp: 0x1f418, file: '1f418', name: 'elephant' },
  { cp: 0x1f992, file: '1f992', name: 'giraffe' },
  { cp: 0x1f993, file: '1f993', name: 'zebra' },
  { cp: 0x1f98f, file: '1f98f', name: 'rhino' },
  { cp: 0x1f402, file: '1f402', name: 'bull' },
  { cp: 0x1f404, file: '1f404', name: 'cow' },
  { cp: 0x1f416, file: '1f416', name: 'pig' },
];

// kept modest: these are tiny on screen (a critter is tens of px tall), so coarse tessellation is
// indistinguishable from fine — and every extra point is a word in the bounded paint buffer at runtime.
const CUBIC_SEGS = 6;
const QUAD_SEGS = 5;
const CIRCLE_SEGS = 16;

function cubic(out: Pt[], x0: number, y0: number, x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): void {
  for (let k = 1; k <= CUBIC_SEGS; k++) {
    const t = k / CUBIC_SEGS, u = 1 - t;
    const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    out.push([a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3]);
  }
}
function quad(out: Pt[], x0: number, y0: number, x1: number, y1: number, x2: number, y2: number): void {
  for (let k = 1; k <= QUAD_SEGS; k++) {
    const t = k / QUAD_SEGS, u = 1 - t;
    out.push([u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2]);
  }
}

// Parse one SVG path `d` into subpaths (each a closed-ish ring of points). Supports M/L/H/V/C/S/Q/T/Z
// (absolute + relative); no A (verified absent in our vendored SVGs). Implicit command repetition is handled.
export function parsePath(d: string): Pt[][] {
  const toks: (string | number)[] = [];
  const re = /([A-Za-z])|(-?(?:\d*\.\d+|\d+\.?)(?:[eE][+-]?\d+)?)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(d))) toks.push(m[1] ? m[1] : parseFloat(m[2]));

  const subs: Pt[][] = [];
  let cur: Pt[] = [];
  let cx = 0, cy = 0, sx = 0, sy = 0; // current point, subpath start
  let px = 0, py = 0; // last cubic control (for S reflection)
  let qx = 0, qy = 0; // last quad control (for T reflection)
  let prev = '';
  let i = 0;
  const n = () => toks[i++] as number;

  while (i < toks.length) {
    let cmd: string;
    if (typeof toks[i] === 'string') cmd = toks[i++] as string;
    else cmd = prev === 'M' ? 'L' : prev === 'm' ? 'l' : prev; // implicit repeat
    const rel = cmd >= 'a';
    const C = cmd.toUpperCase();
    if (C === 'Z') {
      if (cur.length) { cur.push([sx, sy]); subs.push(cur); cur = []; }
      cx = sx; cy = sy; prev = cmd; continue;
    }
    if (C === 'M') {
      let x = n(), y = n(); if (rel) { x += cx; y += cy; }
      if (cur.length) subs.push(cur);
      cx = x; cy = y; sx = x; sy = y; cur = [[x, y]];
    } else if (C === 'L') {
      let x = n(), y = n(); if (rel) { x += cx; y += cy; }
      cx = x; cy = y; cur.push([x, y]);
    } else if (C === 'H') {
      let x = n(); if (rel) x += cx; cx = x; cur.push([cx, cy]);
    } else if (C === 'V') {
      let y = n(); if (rel) y += cy; cy = y; cur.push([cx, cy]);
    } else if (C === 'C') {
      let x1 = n(), y1 = n(), x2 = n(), y2 = n(), x = n(), y = n();
      if (rel) { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy; }
      cubic(cur, cx, cy, x1, y1, x2, y2, x, y); px = x2; py = y2; cx = x; cy = y;
    } else if (C === 'S') {
      let x2 = n(), y2 = n(), x = n(), y = n();
      if (rel) { x2 += cx; y2 += cy; x += cx; y += cy; }
      let x1 = cx, y1 = cy;
      if (prev.toUpperCase() === 'C' || prev.toUpperCase() === 'S') { x1 = 2 * cx - px; y1 = 2 * cy - py; }
      cubic(cur, cx, cy, x1, y1, x2, y2, x, y); px = x2; py = y2; cx = x; cy = y;
    } else if (C === 'Q') {
      let x1 = n(), y1 = n(), x = n(), y = n();
      if (rel) { x1 += cx; y1 += cy; x += cx; y += cy; }
      quad(cur, cx, cy, x1, y1, x, y); qx = x1; qy = y1; cx = x; cy = y;
    } else if (C === 'T') {
      let x = n(), y = n(); if (rel) { x += cx; y += cy; }
      let x1 = cx, y1 = cy;
      if (prev.toUpperCase() === 'Q' || prev.toUpperCase() === 'T') { x1 = 2 * cx - qx; y1 = 2 * cy - qy; }
      quad(cur, cx, cy, x1, y1, x, y); qx = x1; qy = y1; cx = x; cy = y;
    } else break; // unknown — bail rather than loop
    prev = cmd;
  }
  if (cur.length) subs.push(cur);
  return subs;
}

export function parseColor(s: string | undefined): number {
  // We bake only SOLID hex fills. fill="none", a url(#gradient), or a named colour returns the skip
  // sentinel — NOT a silent black (a gradient source then visibly loses shapes, so it's obvious the seam
  // can't reproduce it, rather than baking a black blob). The seam is flat polygons: no gradients.
  const m = s?.trim().match(/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/);
  if (!m) return -1;
  let h = m[1];
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
  return parseInt(h, 16) & 0xffffff;
}

function attr(tag: string, name: string): string | undefined {
  const m = tag.match(new RegExp(`${name}\\s*=\\s*"([^"]*)"`));
  return m ? m[1] : undefined;
}

// ---- gradients (Fluent Color: 2-stop linear w/ endpoints, or radial = unit circle + gradientTransform) ----
type Mat = [number, number, number, number, number, number]; // (x,y) -> (a x + c y + e, b x + d y + f)
function matmul(m: Mat, n: Mat): Mat {
  return [
    m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
  ];
}
function parseTransform(s: string | undefined): Mat {
  let M: Mat = [1, 0, 0, 1, 0, 0];
  if (!s) return M;
  for (const t of s.matchAll(/(\w+)\s*\(([^)]*)\)/g)) {
    const n = t[2].trim().split(/[\s,]+/).map(Number);
    let m: Mat;
    if (t[1] === 'translate') m = [1, 0, 0, 1, n[0] || 0, n[1] || 0];
    else if (t[1] === 'scale') m = [n[0], 0, 0, n[1] ?? n[0], 0, 0];
    else if (t[1] === 'rotate') { const r = (n[0] || 0) * Math.PI / 180, c = Math.cos(r), si = Math.sin(r); m = [c, si, -si, c, 0, 0]; }
    else if (t[1] === 'matrix') m = n as Mat;
    else m = [1, 0, 0, 1, 0, 0];
    M = matmul(M, m); // SVG applies the list left-to-right (first listed = outermost)
  }
  return M;
}
function toRgba(hex: string | undefined, opacity: string | undefined): number {
  const c = parseColor(hex); // -1 if not a clean hex
  const rgb = c < 0 ? 0 : c;
  const a = Math.round((opacity === undefined ? 1 : +opacity) * 255) & 255;
  return ((a << 24) | rgb) >>> 0;
}
function parseStops(body: string): [Stop, Stop] {
  const raw = [...body.matchAll(/<stop\b([^>]*?)\/?>/g)].map((m, i) => ({
    off: (() => { const o = attr(m[1], 'offset'); return o === undefined ? i : +o; })(),
    rgba: toRgba(attr(m[1], 'stop-color'), attr(m[1], 'stop-opacity')),
  }));
  raw.sort((p, q) => p.off - q.off);
  const s0 = raw[0], s1 = raw[raw.length - 1];
  s0.off = Math.max(0, Math.min(1, s0.off));
  s1.off = Math.max(s0.off + 1e-4, Math.min(1, s1.off));
  return [s0, s1];
}
// id -> gradient in SVG coords. Linear keeps endpoints; radial resolves the unit circle through its transform.
function parseDefs(svg: string): Map<string, Grad> {
  const defs = new Map<string, Grad>();
  for (const g of svg.matchAll(/<(linear|radial)Gradient\b([^>]*)>([\s\S]*?)<\/\1Gradient>/g)) {
    const id = attr(g[2], 'id'); if (!id) continue;
    const [s0, s1] = parseStops(g[3]);
    if (g[1] === 'linear') {
      defs.set(id, {
        kind: 1, s0, s1,
        ax: +(attr(g[2], 'x1') ?? 0), ay: +(attr(g[2], 'y1') ?? 0),
        bx: +(attr(g[2], 'x2') ?? 1), by: +(attr(g[2], 'y2') ?? 0),
        cx: 0, cy: 0, ux: 0, uy: 0, vx: 0, vy: 0,
      });
    } else { // radial: cx=cy=0,r=1 then gradientTransform -> ellipse (centre + axis vectors)
      const M = parseTransform(attr(g[2], 'gradientTransform'));
      defs.set(id, {
        kind: 2, s0, s1, ax: 0, ay: 0, bx: 0, by: 0,
        cx: M[4], cy: M[5], ux: M[0], uy: M[1], vx: M[2], vy: M[3],
      });
    }
  }
  return defs;
}

// Walk the SVG elements in document order, each → one or more RawPolys (fill colour OR gradient + SVG ring).
export function svgToPolys(svg: string): RawPoly[] {
  const out: RawPoly[] = [];
  const defs = parseDefs(svg);
  const re = /<(path|circle|ellipse|rect|polygon|polyline)\b([^>]*?)\/?>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(svg))) {
    const kind = m[1], a = m[2];
    const fill = attr(a, 'fill');
    const url = fill?.match(/^url\(#(.+)\)$/);
    const grad = url ? defs.get(url[1]) : undefined;
    const color = grad ? (grad.s0.rgba & 0xffffff) : parseColor(fill);
    if (!grad && color < 0) continue; // fill="none" / unknown — skip (no silent black)
    let rings: Pt[][] = [];
    if (kind === 'path') {
      const d = attr(a, 'd'); if (d) rings = parsePath(d);
    } else if (kind === 'circle') {
      const cx = +attr(a, 'cx')!, cy = +attr(a, 'cy')!, r = +attr(a, 'r')!;
      const ring: Pt[] = [];
      for (let k = 0; k <= CIRCLE_SEGS; k++) { const t = (k / CIRCLE_SEGS) * 2 * Math.PI; ring.push([cx + r * Math.cos(t), cy + r * Math.sin(t)]); }
      rings = [ring];
    } else if (kind === 'ellipse') {
      const cx = +attr(a, 'cx')!, cy = +attr(a, 'cy')!, rx = +attr(a, 'rx')!, ry = +attr(a, 'ry')!;
      const ring: Pt[] = [];
      for (let k = 0; k <= CIRCLE_SEGS; k++) { const t = (k / CIRCLE_SEGS) * 2 * Math.PI; ring.push([cx + rx * Math.cos(t), cy + ry * Math.sin(t)]); }
      rings = [ring];
    } else if (kind === 'rect') {
      const x = +attr(a, 'x')! || 0, y = +attr(a, 'y')! || 0, w = +attr(a, 'width')!, h = +attr(a, 'height')!;
      rings = [[[x, y], [x + w, y], [x + w, y + h], [x, y + h], [x, y]]];
    } else { // polygon / polyline
      const nums = (attr(a, 'points') || '').match(/-?[\d.]+/g)?.map(Number) || [];
      const ring: Pt[] = [];
      for (let k = 0; k + 1 < nums.length; k += 2) ring.push([nums[k], nums[k + 1]]);
      rings = [ring];
    }
    for (const r of rings) if (r.length >= 3) out.push({ color, pts: r, grad });
  }
  return out;
}

// Normalise to the unit frame: feet (max SVG y) at y = 0, y up, height 1, x centred. Mirrors the cat.
// Gradient geometry rides along in lockstep: ENDPOINTS/CENTRE transform like points; AXIS VECTORS like
// vectors (scale only + y-flip, no translate) so a radial's ellipse stays correctly shaped + oriented.
export function normalize(polys: RawPoly[]): RawPoly[] {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const p of polys) for (const [x, y] of p.pts) { if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y; }
  const h = maxY - minY || 1, scale = 1 / h, cxc = (minX + maxX) / 2;
  const r = (v: number) => Math.round(v * 1e4) / 1e4;
  const pt = (x: number, y: number): Pt => [r((x - cxc) * scale), r((maxY - y) * scale)]; // point: translate + y-flip
  const vec = (x: number, y: number): Pt => [r(x * scale), r(-y * scale)];                // vector: scale + y-flip only
  return polys.map(p => {
    let grad: Grad | undefined;
    if (p.grad) {
      const g = p.grad;
      if (g.kind === 1) { const [ax, ay] = pt(g.ax, g.ay), [bx, by] = pt(g.bx, g.by); grad = { ...g, ax, ay, bx, by }; }
      else { const [cx, cy] = pt(g.cx, g.cy), [ux, uy] = vec(g.ux, g.uy), [vx, vy] = vec(g.vx, g.vy); grad = { ...g, cx, cy, ux, uy, vx, vy }; }
    }
    return { color: p.color, grad, pts: p.pts.map(([x, y]) => pt(x, y)) };
  });
}

// ---- bake (runs only when executed directly via ops/bake_emoji, not when imported) ----
const RUN = !!process.argv[1] && process.argv[1].endsWith('bake_emoji.ts');
if (RUN) {
const DIR = new URL('.', import.meta.url).pathname;
const baked: { cp: number; name: string; polys: RawPoly[] }[] = [];
for (const c of CRITTERS) {
  const svg = readFileSync(`${DIR}emoji_svg/${c.file}.svg`, 'utf8');
  const polys = normalize(svgToPolys(svg));
  baked.push({ cp: c.cp, name: c.name, polys });
  const npts = polys.reduce((s, p) => s + p.pts.length, 0);
  console.log(`  ${c.name.padEnd(9)} ${polys.length} polys, ${npts} pts`);
}

// emit emoji_frames.zig
const hex = (c: number) => '0x' + (c >>> 0).toString(16).toUpperCase().padStart(6, '0');
const hex8 = (c: number) => '0x' + (c >>> 0).toString(16).toUpperCase().padStart(8, '0');
const stopZ = (s: Stop) => `.{ .rgba = ${hex8(s.rgba)}, .off = ${s.off} }`;
const gradZ = (g: Grad) => `.{ .kind = ${g.kind}, .s0 = ${stopZ(g.s0)}, .s1 = ${stopZ(g.s1)}, ` +
  `.ax = ${g.ax}, .ay = ${g.ay}, .bx = ${g.bx}, .by = ${g.by}, ` +
  `.cx = ${g.cx}, .cy = ${g.cy}, .ux = ${g.ux}, .uy = ${g.uy}, .vx = ${g.vx}, .vy = ${g.vy} }`;
let zig = `//! emoji_frames — GENERATED by ops/bake_emoji from emoji_svg/*.svg. DO NOT EDIT BY HAND. (Art: vendored
//! Microsoft Fluent Emoji, MIT — Flat variant for the herd, Color variant for the bull; see emoji_svg/README.md.)
//!
//! The safari/farm critters as polygon stills in the UNIT FRAME the cat uses (feet at y = 0, y up,
//! height 1, facing LEFT). critter.zig looks one up by codepoint and transforms its polygons (and any
//! gradient geometry) to the billboard's screen anchor + projected height. Most polys are a SOLID colour
//! (0xRRGGBB); the bull's are gradient-shaded (the Fluent Color art) — a 2-stop linear or radial Grad,
//! rgba 0xAARRGGBB, geometry in the unit frame. Painted in array order (SVG document = painter's order).

pub const Pt = struct { x: f32, y: f32 };
pub const Stop = struct { rgba: u32, off: f32 };
// A 2-stop gradient. kind 1 = linear (a→b); kind 2 = radial (unit circle at c mapped to an ellipse by axes u,v).
pub const Grad = struct {
    kind: u8,
    s0: Stop,
    s1: Stop,
    ax: f32, ay: f32, bx: f32, by: f32, // linear endpoints
    cx: f32, cy: f32, ux: f32, uy: f32, vx: f32, vy: f32, // radial centre + axis vectors
};
pub const Poly = struct { color: u32, grad: ?Grad = null, pts: []const Pt };

`;
for (const b of baked) {
  zig += `const ${b.name} = [_]Poly{\n`;
  for (const p of b.polys) {
    const g = p.grad ? `.grad = ${gradZ(p.grad)}, ` : '';
    zig += `    .{ .color = ${hex(p.color)}, ${g}.pts = &[_]Pt{ ` +
      p.pts.map(([x, y]) => `.{ .x = ${x}, .y = ${y} }`).join(', ') + ` } },\n`;
  }
  zig += `};\n\n`;
}
zig += `/// polysFor: the baked polygons for an emoji codepoint, or null if that codepoint isn't baked.\npub fn polysFor(cp: u32) ?[]const Poly {\n    return switch (cp) {\n`;
for (const b of baked) zig += `        ${hex(b.cp)} => &${b.name},\n`;
zig += `        else => null,\n    };\n}\n`;
writeFileSync(`${DIR}wasm/emoji_frames.zig`, zig);
console.log(`wrote wasm/emoji_frames.zig`);

// validation contact sheet — render each baked critter (unit frame → a cell), feet on the cell baseline.
const COLS = baked.length, CELL = 110, PAD = 12, BASE = CELL - 16;
const sheet = new MiniCanvas(COLS * CELL, CELL, '#9fb6c4');
for (let ci = 0; ci < baked.length; ci++) {
  const ox = ci * CELL + CELL / 2;
  const s = CELL - 2 * PAD; // pixels per unit height
  for (const p of baked[ci].polys) {
    // MiniCanvas is flat-fill; gradient polys get a rough single-colour preview (true gradients render in-browser)
    const col = p.grad ? (p.grad.s0.rgba & 0xffffff) : p.color;
    sheet.fillStyle = '#' + (col >>> 0).toString(16).padStart(6, '0');
    sheet.beginPath();
    p.pts.forEach(([x, y], k) => { const sx = ox + x * s, sy = BASE - y * s; k ? sheet.lineTo(sx, sy) : sheet.moveTo(sx, sy); });
    sheet.closePath(); sheet.fill();
  }
}
mkdirSync(`${DIR}snap`, { recursive: true });
writeFileSync(`${DIR}snap/emoji_baked.png`, sheet.toPNG());
console.log(`wrote snap/emoji_baked.png`);
}
