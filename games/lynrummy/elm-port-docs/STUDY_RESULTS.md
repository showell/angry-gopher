# LynRummy Gesture Study Results

This document records empirical findings from the deep-study
program. Each experiment is a fresh blind test with Steve as lab
rat, instrumented via the per-trial JSON port to
`localhost:8811/trial`.

The study program supplements `UI_DESIGN.md` (design philosophy)
with **measured** values for ergonomic parameters that can't be
predicted from first principles.

---

## Shipped defaults (as of 2026-04-13)

These values are the cumulative output of experiments 1–3 below.
All measured against Steve as the test player. Used as defaults
for the next gesture's study unless tested otherwise.

| Parameter | Value | Origin |
|---|---|---|
| Lookahead projection | **60 ms** | exp 2 (cond C won on hit + speed) |
| Lock threshold (initial) | **0.50** of zone area | exp 1 baseline, never beaten |
| Unlock threshold (hysteresis) | **0.25** of zone area | exp 3 (deeper stickiness gave no benefit) |
| Hysteresis enabled | **always on** | universal flicker fix from exp 2 → 3 transition |
| Ghost preview opacity | **0.7** | exp 3 (between 0.4 and 0.7, both worked, 0.7 felt better at 100% qualitatively) |
| Velocity smoothing α (EMA) | **0.30** | not formally varied; reasonable default |
| Hand position | **upper-left** | declared rule (mom's convention + R-handed ergonomics) |
| Invalid drop | **snap back** | declared rule (production behavior, no regret) |
| Multi-card stack drag | **rigid, 100% opacity** | declared rule (production behavior) |

---

## Gesture 1 — single card to stack

The first gesture solidified by the program. Three formal experiments.

### Experiment 1 (2026-04-13) — 30 trials, 2 conditions

Goal: does momentum lookahead help at all?

| Cond | Lookahead | Hits |
|---|---|---|
| X | 0 ms (no projection) | 10/10 |
| Y | 150 ms | 8/10 |

**Finding:** 150 ms aggressive projection slightly hurts hit rate.
First 10 trials warmup-discarded. Sample thin (10/arm).

### Experiment 2 (2026-04-13) — 100 trials, 5 conditions

Goal: refine lookahead value across a finer gradient.

| Cond | Mechanism | Hits | Mean dur |
|---|---|---|---|
| A | 0 ms | 17/18 | 1039 ms |
| B | 30 ms | 17/18 | 1171 ms |
| C | **60 ms** | **18/18** | **902 ms** |
| D | 100 ms | 16/18 | 982 ms |
| E | velocity-scaled (0 at rest → 120 at high speed, dead zone < 0.2 px/ms) | 18/18 | 1027 ms |

**Findings:**
- **C wins on both axes.** 60 ms is the sweet spot.
- D too aggressive (16/18, slow). Past ~100 ms, projection overshoots.
- A reliable but slow (no last-5% help).
- E (velocity-scaled) matched C on hits but was 125 ms slower —
  dead zone punishes careful approaches.
- Steve adapted around trial 62 to "release early, trust the
  projection." This adaptation biases later trials toward
  conditions that reward early release. Ecologically valid since
  real users would adapt similarly.
- Trial 45 = pure slip (redacted). Trial 62 = real miss (kept).

### Experiment 3 (2026-04-13) — 50 trials, 4 conditions (2×2)

Goal: tune ghost opacity AND hysteresis depth, on top of the
shipped 60 ms / 0.50 / hand-upper-left baseline. Plus L/R landing
side as a non-tested strategic-engagement axis.

| Cond | Opacity | Unlock ratio (blind) | Hits | Mean dur |
|---|---|---|---|---|
| 1 | 0.4 | 0.25 | 10/10 | 1242 ms |
| 2 | 0.4 | 0.05 | 10/10 | 1184 ms |
| 3 | **0.7** | **0.25** | 10/10 | **1177 ms** |
| 4 | 0.7 | 0.05 | 9/10 | 1243 ms |

**Iteration history within experiment 3:**
- Opacity 10%/20% — abandoned, 10% below visibility floor
- Opacity 20%/50% — abandoned, "needs to be higher"
- Opacity **40%/70%** — final, both clearly visible

**Findings:**
- **Cond 3 wins** — opacity 0.7 + moderate hysteresis (0.25 unlock).
- Very deep hysteresis (0.05 unlock) buys nothing — same mean
  duration as 0.25, plus the only miss in the study.
- Both misses were cond 4 / L side. Trial 9 was a slip (redact).
  Trial 48 was a fatigue slip late in the study (released 31 px
  short at near-zero velocity — not a mechanic failure).
- L/R asymmetry in feel: R drags are 54% faster (peak speed 2.69
  vs 1.75) because they're longer. Steve flagged "too eager on R"
  qualitatively, but it didn't cost hits.
- Duration spread across all conditions was only 65 ms (~5%) —
  we've converged.

---

## Open follow-up questions

Things worth measuring in future experiments:

- **Velocity-capped projection** — clamp the projection offset
  (e.g. max 30 px) so fast R-side drags don't project absurdly far.
  Would address the "too eager on R" feel without sacrificing the
  60 ms ergonomic projection at normal speeds.
- **Card "weight" perception** — does dragging a 3-card stack feel
  heavier? Should lookahead/hysteresis values scale with stack
  size? Planned for the gesture-2 study.
- **Pluck-from-middle** UI — the most fundamentally different
  gesture. Steve flagged this as needing significant UI design
  thought. Not yet studied.

---

## Methodology notes

- Per-trial JSON written to `study_logs/study_*.jsonl` via the
  Python sink at `study_server.py` (port 8811). Rich fields for
  post-hoc analysis.
- Chunked breaks every 10 trials with rotating positive-feedback
  messages — tested as essential for grinds of 30+ reps.
- Conditions interleaved pseudo-randomly via fixed sequences in
  source code (not random per session, so re-runs are repeatable).
- Steve serves as sole lab rat. Findings are anchored to his
  motor/perceptual profile; values may need re-tuning for other
  primary users (especially the tablet-first audience).
