"""bench_timing.py — Stable timing primitive for the BFS solver.

Single source of truth for `gen_baseline_board.py` (gold capture)
and `check_baseline_timing.py` (regression check). Both layers must
use identical methodology or gold and check disagree on noise.

Methodology:

1. **Warmup pass**: one solver invocation before measuring. The lru_caches
   on `classify` / `neighbors` start cold; the warmup pre-populates them
   so the first measured run isn't paying classify-miss costs.

2. **GC disabled during the timed section**: BFS allocates heavily
   (Buckets tuples, descriptor dataclasses, frontier lists). Generational
   GC firing mid-run is the dominant source of pause-noise — captures
   that happen to dodge a collection look 20-30% faster than ones that
   don't. We force a `gc.collect()` before each run, disable GC during
   the timed window, and re-enable + collect after.

3. **Process time, not wall time**: `time.process_time()` measures CPU
   time consumed by the current process — it excludes wall-clock jitter
   from kernel scheduler activity (other processes preempting us). Wall
   time on a multi-tenant system (WSL2 with parent processes) showed
   ±10-25% noise even on idle-looking machines. Process time bands
   tighten to ±2-3%.

4. **Min of N**: minimum is the right statistic — best-case represents
   the work the code actually has to do; outliers above represent
   contention or transient system state, not the solver itself.

Default N=20. Empirically this gives a noise band <3% on the hot
tantalizing cases (2Cp, 2Sp, 3Hp), down from >25% on the previous
min-of-3-no-warmup-no-gc-control-wall-clock methodology.
"""

import gc
import time

import bfs
from buckets import Buckets


def time_solver(state, n_runs=20):
    """Time `bfs.solve_state_with_descs(state, ...)` and return
    (plan_or_None, best_ms). `state` is a `Buckets`."""
    if not isinstance(state, Buckets):
        state = Buckets(*state)

    plan = bfs.solve_state_with_descs(
        state, max_trouble_outer=10, max_states=200000, verbose=False)

    best_ms = float("inf")
    for _ in range(n_runs):
        gc.collect()
        gc.disable()
        try:
            t0 = time.process_time()
            plan = bfs.solve_state_with_descs(
                state, max_trouble_outer=10, max_states=200000,
                verbose=False)
            elapsed_ms = (time.process_time() - t0) * 1000
        finally:
            gc.enable()
        if elapsed_ms < best_ms:
            best_ms = elapsed_ms
    return plan, best_ms
