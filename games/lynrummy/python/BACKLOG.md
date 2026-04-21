# Decomposition harness — deferred items

Small parking lot for issues surfaced during the harness
work that we've agreed to revisit later.

## Replay: odd timing jumps

2026-04-20. After fixing the puzzle-session replay baseline,
Steve reports that Instant Replay plays back with "some odd
jumps in time." The baseline itself is now correct; the
animation cadence is what looks off.

Candidate causes to investigate:
- The inter-action beat (the fixed pause between actions in
  replay) may be mis-tuned now that splits carry telemetry
  (previously they fell to the instant-apply + 1s-beat
  branch; now they have a 2-point path and go through the
  same replay pipeline as drags, which may animate too
  quickly for clicks).
- Gaps between consecutive timestamps across actions — the
  replay may be using absolute timestamps within a path but
  wall-clock pauses between paths, which can read as a jerk
  when the gestures are themselves short.
- MouseUp telemetry added mid-work may have landed a sample
  far in time from the preceding MouseMove, causing the
  final leg of an animation to compress or extend oddly.
