// sky.ts — the sky's colour through the day: a daytime blue that dims to a deep dusk blue as the sun
// sets, and a warm sunset band that reddens near the horizon as the sun crosses it. Pure functions of
// the step (the animation clock), so the sky scrubs on reverse and freezes on pause like everything else.

import { sunSetFraction, sunsetWarmth, SUNSET_RED, SUNSET_GLOW } from './sun.ts';

// ---- constants ----

const DAY_SKY = [142, 202, 230];   // #8ecae6 — the established daytime sky
const DUSK_SKY = [36, 58, 94];     // deep dusk blue

// ---- functions ----

const lerp3 = (a: number[], b: number[], t: number): number[] => a.map((v, i) => Math.round(v + (b[i] - v) * t));
const rgbStr = (c: number[]): string => `rgb(${c[0]},${c[1]},${c[2]})`;

// The upper-sky colour and the warmer horizon-band colour for this step, as CSS rgb() strings. The
// renderer paints a vertical gradient from `sky` (high) down to `horizon` (near the ground): the blue
// darkens all channels toward dusk (so it doesn't grey out), and the red mixes only into the lower band.
export function skyColors(step: number): { sky: string; horizon: string } {
  const sky = lerp3(DAY_SKY, DUSK_SKY, sunSetFraction(step));
  const horizon = lerp3(sky, SUNSET_RED, sunsetWarmth(step) * SUNSET_GLOW);
  return { sky: rgbStr(sky), horizon: rgbStr(horizon) };
}
