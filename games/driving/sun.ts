// sun — the setting sun: a CLOCK (its height drops linearly with the STEP, so it scrubs on
// reverse and freezes on pause) and the disc + glow it paints. Heights are PIXELS at the base
// focal — the frame the mountain silhouettes use — so the two compare directly and the sunset
// is checkable in the model test. Near the horizon px ~= focal*angle, so a constant px/step is
// essentially a constant world-rotation per step.

function wrap(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

export const SUN_BEARING = -2.2176;
export const SUN_RADIUS_PX = 46;
const SUN_START_PX = 194.85;                                    // step-0 height; calibrated to the route's timing (locked by test_model)
const SUN_DROP_PX_PER_STEP = 0.408 * (2 * SUN_RADIUS_PX) / 625; // ~41% of the disc diameter over the long sun-ward stretch
const SUN_FULLY_SET_PX = -SUN_RADIUS_PX;                        // height at which the whole disc has dropped below the horizon
const WARMTH_FALLOFF_PX = 110;                                  // how far from the horizon the sunset-red fades to nothing
const VISIBLE_BEARING_LIMIT = 1.4;                             // beyond this bearing off-heading the sun is off-screen

export function sunHeightPx(step: number): number {
  return SUN_START_PX - SUN_DROP_PX_PER_STEP * step;
}

// How far "dusk" has progressed (0 = day, 1 = night). While the sun is up the darkening is a
// SQUARED ramp — barely moving while the sun is high, accelerating toward sunset — so the sky
// stays bright until around sunset; once the disc is fully set the rest fades linearly.
export function sunSetFraction(step: number): number {
  const h = sunHeightPx(step);
  const duskAtSet = 0.5 * (SUN_START_PX - SUN_FULLY_SET_PX) / SUN_START_PX;
  if (h >= SUN_FULLY_SET_PX) {
    const p = (SUN_START_PX - h) / (SUN_START_PX - SUN_FULLY_SET_PX);
    return Math.max(0, duskAtSet * p * p);
  }
  return Math.min(1, duskAtSet + (SUN_FULLY_SET_PX - h) / SUN_RADIUS_PX * (1 - duskAtSet));
}

// How RED the sunset is (0..1): peaks as the sun crosses the horizon, fades when it is high or
// deep below — drives the warm afterglow band the sky adds near the horizon.
export function sunsetWarmth(step: number): number {
  return Math.max(0, 1 - Math.abs(sunHeightPx(step)) / WARMTH_FALLOFF_PX);
}

// Paint the sun + its glow for the Rider's heading, clipped to the sky (the ground occludes the
// rest). vScale = focal/baseFocal squeezes it vertically to match the ranges on a lean.
export function drawSun(ctx: CanvasRenderingContext2D, heading: number,
                        W: number, H: number, FOCAL: number, vScale: number, step: number): void {
  const rel = wrap(SUN_BEARING - heading);
  if (Math.abs(rel) >= VISIBLE_BEARING_LIMIT) return;
  const sx = W / 2 + Math.tan(rel) * FOCAL, sy = H / 2 - sunHeightPx(step) * vScale;
  ctx.save();
  ctx.beginPath(); ctx.rect(0, 0, W, H / 2); ctx.clip();   // sky only
  const glow = ctx.createRadialGradient(sx, sy, 8 * vScale, sx, sy, 340 * vScale);
  glow.addColorStop(0, 'rgba(255,201,128,0.85)');
  glow.addColorStop(0.4, 'rgba(255,150,92,0.32)');
  glow.addColorStop(1, 'rgba(255,150,92,0)');
  ctx.fillStyle = glow; ctx.fillRect(0, 0, W, H / 2);
  const disc = ctx.createRadialGradient(sx, sy, 4 * vScale, sx, sy, SUN_RADIUS_PX * vScale);
  disc.addColorStop(0, '#ffe6a3'); disc.addColorStop(1, '#ff9d5c');
  ctx.fillStyle = disc;
  ctx.beginPath(); ctx.arc(sx, sy, SUN_RADIUS_PX * vScale, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
}
