// bench_timing.ts — Stable timing primitive for the BFS solver.
//
// Single source of truth for gen_baseline_board.ts (gold capture) and
// check_baseline_timing.ts (regression check). Both must use identical
// methodology or gold and check disagree on noise.
//
// Methodology:
//
// 1. **Warmup pass**: one solver invocation before measuring. V8 lazily
//    optimizes hot functions; the first run pays JIT-tier costs the
//    measured runs shouldn't.
//
// 2. **GC control**: V8 doesn't expose generational-GC toggling like
//    CPython does. We invoke `global.gc()` between runs when Node was
//    started with `--expose-gc`; otherwise we rely on min-of-N to
//    dodge GC noise. Run with `node --expose-gc` for the tightest
//    timings.
//
// 3. **process.hrtime() not Date.now()**: hrtime() is monotonic and
//    nanosecond-precision; Date.now() is millisecond-precision and can
//    jump backward on NTP. We do NOT separate user vs wall time
//    (Python uses process_time(); Node has no equivalent that excludes
//    only kernel scheduler jitter cleanly). On a quiet machine the
//    difference is negligible.
//
// 4. **Min of N**: minimum is the right statistic — best-case
//    represents the work the code actually has to do; outliers above
//    represent contention or transient system state, not the solver
//    itself.

import type { Card } from "../core/card.ts";
import { solveBoard, type PlanLine } from "../bfs/engine_v2.ts";

interface TimingResult {
  readonly plan: readonly PlanLine[] | null;
  readonly bestMs: number;
}

function maybeGc(): void {
  const g = (globalThis as { gc?: () => void }).gc;
  if (typeof g === "function") g();
}

function nowMs(): number {
  const [s, ns] = process.hrtime();
  return s * 1000 + ns / 1e6;
}

/**
 * Time `solveBoard(board)` and return `{ plan, bestMs }`. One warmup
 * pass + `nRuns` measured invocations; min wins.
 */
export function timeSolver(
  board: readonly (readonly Card[])[],
  nRuns: number = 20,
): TimingResult {
  // Warmup.
  let result = solveBoard(board);

  let bestMs = Infinity;
  for (let i = 0; i < nRuns; i++) {
    maybeGc();
    const t0 = nowMs();
    result = solveBoard(board);
    const elapsed = nowMs() - t0;
    if (elapsed < bestMs) bestMs = elapsed;
  }
  return { plan: result === null ? null : result.plan, bestMs };
}
