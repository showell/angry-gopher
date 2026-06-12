// SANDBOX — time-optimal (bang-bang) steering for the lateral triple integrator, validated against a
// brute-force oracle before it goes anywhere near the game. Run: node test/bangbang.ts
//
// Lateral dynamics (small-angle), matching simulateRiderStep's per-frame integration:
//   theta_{k+1} = theta_k + u        (u = tilt step, |u| <= U)
//   psi_{k+1}   = psi_k + c*theta_{k+1}
//   x_{k+1}     = x_k + v*sin(psi)   (small-angle ~ v*psi)
// Chained, x is the 3rd integral of u: a triple integrator. State for the controller is
//   (p, q, r) = (across - x*, v*psi, v*c*theta)   so  p'=q, q'=r, r' = (v*c)*u,  |u|<=U.
// Control-on-r bound A = v*c*U. Target: (p,q,r) = (0,0,0) (centred-ish, aligned, upright).

const YAW_PER_TILT = 0.1;
const U = 1 * Math.PI / 180;          // max tilt step per frame (rad)

// ---- continuous-time arc propagation (constant jerk w over duration t) ----
interface S3 { p: number; q: number; r: number }
function arc(s: S3, w: number, t: number): S3 {
  return {
    r: s.r + w * t,
    q: s.q + s.r * t + w * t * t / 2,
    p: s.p + s.q * t + s.r * t * t / 2 + w * t * t * t / 6,
  };
}
// propagate a 3-arc bang-bang (controls +/-A alternating, first sign sg) with durations a,b,cc
function prop3(s0: S3, A: number, sg: number, a: number, b: number, cc: number): S3 {
  let s = arc(s0, sg * A, a);
  s = arc(s, -sg * A, b);
  s = arc(s, sg * A, cc);
  return s;
}

// ---- analytic solve: durations (a,b,cc) >=0 of the 3-arc bang-bang that zeroes the state ----
// b is pinned by the r-equation: r0 + sg*A*(a - b + cc) = 0  =>  b = a + cc + r0/(sg*A).
// Then drive (q,p)->0 over (a,cc) by 2D Newton (numeric Jacobian; a few iterations, O(1)).
function solve3(s0: S3, A: number, sg: number): { a: number; b: number; cc: number; T: number } | null {
  const bOf = (a: number, cc: number) => a + cc + s0.r / (sg * A);
  const resid = (a: number, cc: number): [number, number] => {
    const s = prop3(s0, A, sg, a, bOf(a, cc), cc);
    return [s.q, s.p];
  };
  let best: { a: number; b: number; cc: number; T: number } | null = null;
  // dense multi-start, collect ALL feasible roots, keep the MIN-TIME one
  const grid = [0, 0.5, 1, 2, 5, 10, 20, 35, 50, 80];
  for (const ia of grid) for (const ic of grid) {
    let a = ia, cc = ic, ok = false;
    for (let it = 0; it < 80; it++) {
      const [f0, g0] = resid(a, cc);
      if (Math.abs(f0) < 1e-9 && Math.abs(g0) < 1e-9) { ok = true; break; }
      const h = 1e-6;
      const [fa, ga] = resid(a + h, cc), [fc, gc] = resid(a, cc + h);
      const j11 = (fa - f0) / h, j12 = (fc - f0) / h, j21 = (ga - g0) / h, j22 = (gc - g0) / h;
      const det = j11 * j22 - j12 * j21;
      if (Math.abs(det) < 1e-16) break;
      a -= (j22 * f0 - j12 * g0) / det;
      cc -= (-j21 * f0 + j11 * g0) / det;
      if (!Number.isFinite(a) || !Number.isFinite(cc) || Math.abs(a) > 1e7) break;
    }
    if (!ok) continue;
    const b = bOf(a, cc);
    if (a >= -1e-6 && b >= -1e-6 && cc >= -1e-6) {
      const T = Math.max(a, 0) + Math.max(b, 0) + Math.max(cc, 0);
      if (!best || T < best.T) best = { a: Math.max(a, 0), b: Math.max(b, 0), cc: Math.max(cc, 0), T };
    }
  }
  return best;
}
// the time-optimal FIRST control at a state: try both first-signs, take the feasible min-time one.
function minTime(s0: S3, A: number): { u: number; a: number; b: number; cc: number; T: number } | null {
  let best: { u: number; a: number; b: number; cc: number; T: number } | null = null;
  for (const sg of [1, -1]) {
    const sol = solve3(s0, A, sg);
    if (sol && (best === null || sol.T < best.T)) best = { u: sg * A, ...sol };
  }
  return best;
}

// ---- CONTINUOUS oracle: independent min-T over a fine real (a,b) grid (t3 pinned by r3=0), refined ----
// (a separate method from the Newton solve, so agreement is real validation, not self-confirmation)
function oracle(s0: S3, A: number, tMax: number): { T: number; sg: number; a: number; b: number; cc: number } | null {
  let best: { T: number; sg: number; a: number; b: number; cc: number } | null = null;
  for (const sg of [1, -1]) {
    let lo = 0, step = tMax / 200;
    for (let pass = 0; pass < 3; pass++) {       // coarse-to-fine
      let found: { a: number; b: number; cc: number; T: number } | null = null;
      for (let a = 0; a <= tMax; a += step) for (let b = 0; b <= tMax; b += step) {
        const cc = -(s0.r + sg * A * (a - b)) / (sg * A);   // t3 that zeroes r
        if (cc < 0) continue;
        const s = prop3(s0, A, sg, a, b, cc);
        if (Math.abs(s.q) < 1e-3 && Math.abs(s.p) < 5e-3) {
          const T = a + b + cc;
          if (!found || T < found.T) found = { a, b, cc, T };
        }
      }
      if (!found) break;
      lo = found.a; step /= 12;                  // (coarse refine around the band; good enough for a sign/T check)
      if (pass === 2 && (!best || found.T < best.T)) best = { sg, ...found };
    }
  }
  return best;
}

// terminal-region proportional gains (triple poles at -OMEGA): inside the box we use a smooth linear law
// instead of bang-bang, so the control stops flipping +/-U every frame once it's near the target.
let OMEGA = 0.08;
// the per-frame tilt step the controller outputs at a (across, psi, theta) state, speed v, target across x*.
// SATURATED-LINEAR regulator: place triple poles at -OMEGA on the (p,q,r) triple integrator, clamp to +/-U.
// Gentle (no violent min-time excursion), smooth (no bang-bang chatter), O(1). Far out it saturates toward
// the boundary; near the target it eases in continuously.
function control(across: number, psi: number, theta: number, v: number, xStar: number): number {
  const c = YAW_PER_TILT;
  const p = across - xStar, q = v * psi, r = v * c * theta;
  const ctrl = -(OMEGA ** 3 * p + 3 * OMEGA ** 2 * q + 3 * OMEGA * r);   // jerk on r placing triple poles at -OMEGA
  return Math.max(-U, Math.min(U, ctrl / (v * c)));                       // back out the tilt step (clamped to +/-U)
}
// ONE discrete frame of the game's lateral physics (lean-first, mid-heading), v held.
function simStep(st: { across: number; psi: number; theta: number }, u: number, v: number): void {
  st.theta += u;
  const dPsi = YAW_PER_TILT * st.theta;
  st.across += v * Math.sin(st.psi + dPsi / 2);
  st.psi += dPsi;
}

function main(): void {
  const c = YAW_PER_TILT;
  const cases = [
    { v: 1.5, across: 1.0, psi: 0.0, theta: 0.0 },
    { v: 1.5, across: 1.5, psi: -0.1, theta: 0.0 },
    { v: 0.5, across: -1.8, psi: 0.05, theta: 0.2 },    // step-349-like: off left, leaned right, slow
    { v: 0.5, across: 1.9, psi: -0.15, theta: -0.28 },  // step-791-like: off right, leaned left, slow
    { v: 2.0, across: 0.3, psi: 0.0, theta: 0.0 },
    { v: 2.0, across: 0.0, psi: 0.15, theta: 0.0 },     // centred but pointed off
  ];

  console.log('=== analytic min-time  vs  independent continuous oracle ===');
  console.log('  v   across  psi   theta | analytic u,a,b,c (T)       | oracle sg,a,b,c (T)        | sign/T match');
  for (const k of cases) {
    const A = k.v * c * U;
    const s0: S3 = { p: k.across, q: k.v * k.psi, r: k.v * c * k.theta };
    const an = minTime(s0, A), or = oracle(s0, A, 200);
    const aS = an ? `${an.u > 0 ? '+' : '-'} ${an.a.toFixed(1)},${an.b.toFixed(1)},${an.cc.toFixed(1)} (${an.T.toFixed(1)})` : 'NONE';
    const oS = or ? `${or.sg > 0 ? '+' : '-'} ${or.a.toFixed(1)},${or.b.toFixed(1)},${or.cc.toFixed(1)} (${or.T.toFixed(1)})` : 'NONE';
    const m = an && or ? (Math.sign(an.u) === or.sg && Math.abs(an.T - or.T) / or.T < 0.05 ? 'YES' : '** NO **') : '?';
    console.log(`  ${k.v.toFixed(1)} ${k.across.toFixed(1).padStart(5)} ${k.psi.toFixed(2).padStart(5)} ${k.theta.toFixed(2).padStart(5)} | ${aS.padEnd(26)} | ${oS.padEnd(26)} | ${m}`);
  }

  const EPS = 0.04;  // barely-off-centre target, on his own side
  const xs = (a: number) => (a >= 0 ? EPS : -EPS);
  for (const om of [0.05, 0.08, 0.12, 0.18]) {
    OMEGA = om;
    console.log(`\n=== SATURATED-LINEAR regulator, OMEGA=${om} (x*=+/-0.04, his side) ===`);
    console.log('  v   start(across,psi,theta) | settle  max|across|  end(across)   flips');
    for (const k of cases) {
      const xStar = xs(k.across);
      const st = { across: k.across, psi: k.psi, theta: k.theta };
      let maxA = Math.abs(st.across), settle = -1, flips = 0, prevU = 0;
      for (let i = 0; i < 2000; i++) {
        const u = control(st.across, st.psi, st.theta, k.v, xStar);
        if (i > 0 && Math.sign(u) !== Math.sign(prevU) && Math.abs(u) > 1e-9 && Math.abs(prevU) > 1e-9) flips++;
        prevU = u;
        simStep(st, u, k.v);
        maxA = Math.max(maxA, Math.abs(st.across));
        if (settle < 0 && Math.abs(st.across - xStar) < 0.05 && Math.abs(st.psi) < 0.01 && Math.abs(st.theta) < 0.02) settle = i;
      }
      const set = settle >= 0 ? `${settle}` : '>2000';
      const off = maxA > 2.001 ? '  <-- OFF ROAD' : '';
      console.log(`  ${k.v.toFixed(1)} (${k.across.toFixed(2)},${k.psi.toFixed(2)},${k.theta.toFixed(2)})`.padEnd(30) +
        `| ${set.padStart(6)}     ${maxA.toFixed(3).padStart(6)}      ${st.across.toFixed(3).padStart(6)}   ${flips}${off}`);
    }
  }

  // trajectory of the worst case (step-791-like) under the gentle regulator
  OMEGA = 0.08;
  console.log('\n=== trajectory: (1.9,-0.15,-0.28) v=0.5, OMEGA=0.08 — across every 6 frames ===');
  { const st = { across: 1.9, psi: -0.15, theta: -0.28 }; const out: string[] = [];
    for (let i = 0; i < 240; i++) { const u = control(st.across, st.psi, st.theta, 0.5, EPS); simStep(st, u, 0.5); if (i % 6 === 0) out.push(st.across.toFixed(2)); }
    console.log('  ' + out.join(' ')); }
}
main();
