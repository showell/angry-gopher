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

import { solveBucketedState, type PlanLine } from "../bfs/engine_v2.ts";
import {
  classifyBuckets,
  type Buckets,
  type RawBuckets,
} from "../bfs/buckets.ts";

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
 * Time `solveBucketedState(state, ...)` and return
 * `{ plan, bestMs }`. `state` is either a classified `Buckets` or a
 * `RawBuckets`; raw shapes are classified once on the way in so the
 * timed runs see identical work.
 */
export function timeSolver(
  state: Buckets | RawBuckets,
  nRuns: number = 20,
): TimingResult {
  // Pre-classify so every timed run starts from the same shape.
  const buckets: Buckets = isClassified(state)
    ? state
    : classifyBuckets(state as RawBuckets);

  // Warmup.
  let result = solveBucketedState(buckets);

  let bestMs = Infinity;
  for (let i = 0; i < nRuns; i++) {
    maybeGc();
    const t0 = nowMs();
    result = solveBucketedState(buckets);
    const elapsed = nowMs() - t0;
    if (elapsed < bestMs) bestMs = elapsed;
  }
  return { plan: result === null ? null : result.plan, bestMs };
}

function isClassified(state: Buckets | RawBuckets): state is Buckets {
  for (const name of ["helper", "trouble", "growing", "complete"] as const) {
    const bucket = (state as unknown as { [k: string]: unknown })[name];
    if (Array.isArray(bucket) && bucket.length > 0) {
      const first = bucket[0];
      return typeof first === "object" && first !== null && "kind" in first;
    }
  }
  return true;
}
