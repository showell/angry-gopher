// wasm_check.ts — conformance for the SHIPPED artifact. Instantiates
// delivery/solver.wasm (the module the browser runs), calls solveShift for
// every gold seed, and compares the JSON Plan it emits against BOTH gold
// files: route structure vs solver_gold.json, frames + display numbers vs
// solver_frames_gold.json. Strings/integers strict; trig-derived floats at
// ULP tolerance (wasm ships zig's libm, the golds were minted under V8).
// Run from the repo root (wired into ops/check_delivery):
//
//   delivery/node_modules/.bin/esbuild delivery/wasm_check.ts \
//     --bundle --platform=node --format=esm --outfile=/tmp/wc.mjs && node /tmp/wc.mjs

import { readFileSync } from "node:fs";

const gold = JSON.parse(readFileSync("delivery/solver_gold.json", "utf8"));
const framesGold = JSON.parse(readFileSync("delivery/solver_frames_gold.json", "utf8"));
const wasmBytes = readFileSync("delivery/solver.wasm");

const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const ex = instance.exports as {
  memory: WebAssembly.Memory;
  solveShift: (seed: number) => number;
  outPtr: () => number;
};

let failures = 0;
function fail(msg: string): void {
  failures++;
  console.log(`  FAIL ${msg}`);
}

const close = (a: number, b: number): boolean => Math.abs(a - b) <= 1e-9 + Math.abs(b) * 1e-12;
const deepEq = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);

for (let i = 0; i < gold.shifts.length; i++) {
  const gshift = gold.shifts[i];
  const fshift = framesGold.shifts[i];
  const before = failures;

  const len = ex.solveShift(gshift.seed) >>> 0;
  const plan = JSON.parse(new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ex.outPtr(), len)));

  // Route structure vs the core gold (stops incl. houses + pins, loads).
  plan.routes.forEach((r: any, slot: number) => {
    const g = gshift.routes[slot];
    if (!deepEq(r.stops.map((s: any) => ({ nbhd: s.nbhd, houses: s.houses, ...(s.pin !== undefined ? { pin: s.pin } : {}) })), g.stops)) {
      fail(`S${gshift.shift} truck ${slot + 1}: stops diverge from solver_gold`);
    }
    if (r.orders !== g.orders) fail(`S${gshift.shift} truck ${slot + 1}: orders ${r.orders} vs gold ${g.orders}`);
  });
  if (plan.unrouted.length !== 0) fail(`S${gshift.shift}: ${plan.unrouted.length} unrouted`);

  // Display numbers vs the frames gold.
  fshift.routes.forEach((g: any, slot: number) => {
    const r = plan.routes[slot];
    if (r.travel !== g.travel) fail(`S${gshift.shift} truck ${slot + 1}: travel ${r.travel} vs gold ${g.travel}`);
    if (!close(r.time, g.time)) fail(`S${gshift.shift} truck ${slot + 1}: time ${r.time} vs gold ${g.time}`);
  });
  if (plan.travel !== fshift.travel) fail(`S${gshift.shift}: plan travel diverges`);
  if (plan.service !== fshift.service) fail(`S${gshift.shift}: plan service diverges`);
  for (const k of ["local", "totalTime", "spread"] as const) {
    if (!close(plan[k], fshift[k])) fail(`S${gshift.shift}: plan ${k} ${plan[k]} vs gold ${fshift[k]}`);
  }

  // Frames: labels + touched strict; route snapshots exact.
  if (plan.frames.length !== fshift.frames.length) {
    fail(`S${gshift.shift}: ${plan.frames.length} frames vs gold ${fshift.frames.length}`);
  } else {
    for (let f = 0; f < plan.frames.length; f++) {
      const pf = plan.frames[f];
      const gf = fshift.frames[f];
      if (pf.label !== gf.label) fail(`S${gshift.shift} frame ${f}: label "${pf.label}" vs gold "${gf.label}"`);
      if (!deepEq(pf.touched, gf.touched)) fail(`S${gshift.shift} frame ${f}: touched diverges`);
      if (!deepEq(pf.routes, gf.routes)) fail(`S${gshift.shift} frame ${f}: routes diverge`);
    }
  }

  console.log(`S${gshift.shift} (seed ${gshift.seed}): ${failures === before ? "OK" : "DIVERGED"}`);
}

if (failures > 0) {
  console.log(`\n${failures} DIVERGENCE(S) — the wasm artifact does not match the gold`);
  process.exit(1);
}
console.log(`\nWASM ARTIFACT CONFORMS (${gold.shifts.length} shifts, frames + display included)`);
