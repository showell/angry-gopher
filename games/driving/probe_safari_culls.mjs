// probe_safari_culls.mjs — the Safari render's belt-and-suspenders cull gate. Run by ops/check_safari.
//
// The critters are baked polygon sets (emoji_frames.zig), hundreds of points each, so the render culls
// them two ways: by chain-segment reach (skip far segments before projecting — saves WASM work) and by
// projected pixel size (drop the tiny survivors — saves the bounded paint buffer + blitting). This drives
// the committed safari.wasm across a full course traversal and asserts:
//   1. no frame overflows the draw buffer (peak < cap) — overflow silently drops polygons,
//   2. cull_seg > 0 AND cull_size > 0 over the run — BOTH culls do real work, so neither has gone dead
//      (a reach set so loose the size cull never fires, or so tight segments do everything, is the bug).
// It reads safari.wasm AS COMMITTED (like ops/check_zig guards the bundles) — rebuild it after edits.

import { readFileSync } from 'node:fs';

const wasmPath = new URL('./safari.wasm', import.meta.url);
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
const { advance, renderFrame, bufPtr, memory, bufCap, riderSeg, cullSeg, cullSize } = instance.exports;

const STEPS = 12000;
let peak = 0, totalSeg = 0, totalSize = 0, bad = 0;
const segs = new Set();
for (let i = 0; i < STEPS; i++) {
  advance();
  const len = renderFrame();
  if (len > peak) peak = len;
  totalSeg += cullSeg();
  totalSize += cullSize();
  segs.add(riderSeg());
  // walk the buffer to confirm it's well-formed (no stray tag from a desync / overflow tail)
  const u = new Uint32Array(memory.buffer, bufPtr(), len / 4);
  let w = 0;
  while (w * 4 < len) {
    const tag = u[w++];
    if (tag === 0) { w++; const n = u[w++]; w += n * 2; }
    else if (tag === 1) { w += 2; const n = u[w++]; w += n * 2; } // color + shade strength
    else if (tag === 3) { w += 5; }
    else if (tag === 4) { w += 5; const n = u[w++]; w += n * 2; }
    else if (tag === 5) { w += 8; const n = u[w++]; w += n * 2; }
    else if (tag === 6) { w += 10; const n = u[w++]; w += n * 2; }
    else { bad++; break; }
  }
}

const cap = bufCap();
const fails = [];
if (bad) fails.push(`${bad} malformed frames (buffer desync / overflow)`);
if (peak >= cap) fails.push(`buffer overflow: peak ${peak} >= cap ${cap} (polys silently dropped)`);
if (totalSeg === 0) fails.push(`segment cull never fired — FARM_SEG_REACH/SAFARI_SEG_REACH too loose, or the gate is dead`);
if (totalSize === 0) fails.push(`size cull never fired within reach — MIN_CRITTER_PX too small, or the reaches do all the work`);

console.log(`safari culls: ${segs.size} segments, peak ${peak}/${cap} bytes (${(peak / cap * 100).toFixed(1)}%), ` +
  `seg-culled ${totalSeg}, size-culled ${totalSize} over ${STEPS} frames`);
if (fails.length) {
  console.error('FAIL:\n  - ' + fails.join('\n  - '));
  process.exit(1);
}
console.log('OK: no overflow; both culls live (belt + suspenders).');
