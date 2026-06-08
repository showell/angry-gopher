// horizon — the far backdrop, drawn for the Rider's heading: the setting sun behind the ranges,
// then the snowcapped mountains and rolling land in front. Pure glue over sun.ts and mountain.ts;
// the two meet only at the horizon, where the sun sets behind the western range (a coupling the
// model test enforces).

import { drawSun } from './sun.ts';
import { drawMountains } from './mountain.ts';

// `heading` is the Rider's absolute look direction; FOCAL is the LIVE focal (a leaning camera
// pulls it in); overscan widens the fills past the rolled screen edges; vScale = focal/baseFocal
// squeezes the heights to match the lean; step drives the sunset clock.
export function drawHorizon(ctx: CanvasRenderingContext2D, heading: number,
                            W: number, H: number, FOCAL: number, overscan = 0, vScale = 1,
                            step = 0): void {
  drawSun(ctx, heading, W, H, FOCAL, vScale, step);
  drawMountains(ctx, heading, W, H, FOCAL, overscan, vScale, step);
}
