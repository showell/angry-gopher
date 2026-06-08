// =============================================================================
// horizon — far scenery as layered silhouettes. Everything here is at infinity:
// apparent position depends only on which way the Rider FACES, not where it is.
// So each layer is a pure function from absolute bearing (radians, 0 = north,
// + = clockwise / to the Rider's right) to a height in pixels above the horizon.
//
//   groundBase  — a gentle roll present at EVERY bearing (the sloped horizon)
//   northRange  — a tall range centred on north (drawn snowcapped)
//   westRange   — a second range to the west, with the sun setting over it
//
// drawHorizon(ctx, heading, W, H, FOCAL) is the only export: it composites the
// sun, the ranges, and the land onto the canvas for the Rider's heading.
// =============================================================================

function wrap(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

// We have a western range of mountains that the sun sets behind.
const WEST_RANGE_BEARING = -2.094;
export const SUN_BEARING = -2.27;

const SNOWLINE = 95;                 // px above the horizon; the north range is snowcapped above this

// One mountain range: a smooth envelope (tallest at its centre, tapering to open
// sky at its edges) times a fixed rugged ridge line.
function range(bearing: number, center: number, half: number, peak: number,
               freqA: number, freqB: number): number {
  const b = wrap(bearing - center);
  const t = b / half;                                  // -1..1 across the range
  if (Math.abs(t) >= 1) return 0;                      // open sky beyond it
  const envelope = Math.cos(t * Math.PI / 2);          // smooth taper to 0 at the edges
  const ridge = 0.6 + 0.24 * Math.cos(b * freqA) + 0.16 * Math.cos(b * freqB + 1.0);
  return peak * envelope * ridge;
}

// The whole horizon gently rolls even between the ranges — never a flat line.
function groundBase(bearing: number): number {
  return 18 + 12 * Math.sin(wrap(bearing) * 0.9 + 1.9);   // ~6..30px, long wavelength
}

const northRange = (bearing: number): number => range(bearing, 0, 0.95, 150, 8, 21);
const westRange = (bearing: number): number => range(bearing, WEST_RANGE_BEARING, 0.72, 120, 11, 27);

// ---- the sun as a clock: it SETS over the ride ----
// The sun's height above the horizon drops linearly with the STEP — a pure function of it (like the
// beacon clock), so it scrubs on reverse and freezes on pause. We work in PIXELS at the base focal
// (the frame the mountain silhouettes are authored in), so the sun and the ranges compare directly
// and the seg9 sunset behaviour is checkable in the model test. Near the horizon px ~= focal*angle,
// so a constant px/step is essentially the constant DEG/step world-rotation. SUN_START_PX is a
// one-time calibration: the sun is part-behind the western range as the Rider turns onto seg9 and
// its centre is still above the range by seg9's end — enforced by test_model.
export const SUN_RADIUS_PX = 46;                                    // the sun disc's radius (px at base focal)
const SUN_START_PX = 146;                                          // sun height above the horizon at step 0 (higher, to keep seg9)
const SUN_DROP_PX_PER_STEP = 0.24 * (2 * SUN_RADIUS_PX) / 625;     // 24% of the disc diameter over seg9's ~625 steps (50% faster)
export function sunHeightPx(step: number): number {
  return SUN_START_PX - SUN_DROP_PX_PER_STEP * step;
}
// How far "dusk" has progressed (0 = day, 1 = night), driving the sky colour. While ANY of the
// disc — and the ambient light it bends over the mountains — is still up, dusk creeps in at HALF
// speed; once the sun is TRULY below the horizon (whole disc under it) the remaining ambient fades
// the rest of the way. The slow phase is the 2x-slower darkening the dusk wanted.
export function sunSetFraction(step: number): number {
  const h = sunHeightPx(step);
  const trulyBelow = -SUN_RADIUS_PX;                                   // the whole disc is under the horizon here
  const slowEnd = 0.5 * (SUN_START_PX - trulyBelow) / SUN_START_PX;    // dusk reached by the time it's truly below
  if (h >= trulyBelow) return Math.max(0, (SUN_START_PX - h) / (SUN_START_PX - trulyBelow) * slowEnd);
  return Math.min(1, slowEnd + (trulyBelow - h) / SUN_RADIUS_PX * (1 - slowEnd));
}
// the tallest horizon silhouette at a given bearing — the effective occluder of the sun there.
export function horizonCrestPx(bearing: number): number {
  return Math.max(westRange(bearing), northRange(bearing), groundBase(bearing));
}

// ---- drawing ----
const ROCK = '#5b6a8f';        // northern range
const ROCK_WEST = '#39435f';   // westward range, darker — backlit by the sunset
const SNOW_DAY = [238, 243, 248];   // bright daytime snowcaps (#eef3f8)
const SNOW_NIGHT = [70, 84, 104];   // heavily dimmed at dusk — the glare goes as the light does
const LAND = '#4a8f43';        // foreground rolling land (matches the grass)

// The snowcaps lose their glare through the ride. (The rock fades on its own as the sky darkens
// toward it — nice, free atmospheric perspective — but bright snow would stay jarring without this.)
function snowColor(step: number): string {
  const t = sunSetFraction(step);
  const c = (i: number): number => Math.round(SNOW_DAY[i] + (SNOW_NIGHT[i] - SNOW_DAY[i]) * t);
  return `rgb(${c(0)},${c(1)},${c(2)})`;
}

// A gently curved snowline (px above the horizon) at a bearing — the cap's base, instead of a
// dead-flat horizontal line. A broad, low-amplitude undulation, a pure function of bearing so it
// holds still in the world as the Rider turns.
const SNOW_CURVE_AMP = 8;
const SNOW_CURVE_FREQ = 1.5;
const snowlineAt = (bearing: number): number => SNOWLINE + SNOW_CURVE_AMP * Math.sin(bearing * SNOW_CURVE_FREQ);

// Draw the whole horizon for the Rider's heading: the setting sun + glow (behind),
// the westward and (snowcapped) northern ranges, and the rolling foreground land.
// Needs the canvas ctx and the camera (W, H, FOCAL) to turn bearings into columns.
export function drawHorizon(ctx: CanvasRenderingContext2D, heading: number,
                            W: number, H: number, FOCAL: number, overscan = 0, vScale = 1,
                            step = 0): void {
  // each screen column is a viewing ray at this absolute bearing. FOCAL is the LIVE focal, so a
  // pulled-in (leaning) camera spreads bearings horizontally; vScale = focal/baseFocal applies the
  // SAME squeeze vertically, since the silhouette heights are authored in pixels at the base focal.
  const bearingAt = (x: number): number => heading + Math.atan((x - W / 2) / FOCAL);
  // fill the band between height f(bearing) above the horizon and a bottom line.
  // `overscan` widens the band past the screen edges so a rolled (leaning) camera
  // still finds land all the way out to the rotated corners.
  const silhouette = (f: (b: number) => number, bottomY: number): void => {
    ctx.beginPath();
    ctx.moveTo(-overscan, bottomY);
    for (let x = -overscan; x <= W + overscan; x += 2) ctx.lineTo(x, H / 2 - f(bearingAt(x)) * vScale);
    ctx.lineTo(W + overscan, bottomY);
    ctx.closePath();
    ctx.fill();
  };

  // the setting sun + its glow, clipped to the sky, behind the ranges (its vertical offset and
  // radii scale with vScale too, so it squeezes with the ranges on a lean).
  const rel = wrap(SUN_BEARING - heading);
  if (Math.abs(rel) < 1.4) {
    const sx = W / 2 + Math.tan(rel) * FOCAL, sy = H / 2 - sunHeightPx(step) * vScale;   // height set by the sunset clock
    ctx.save();
    ctx.beginPath(); ctx.rect(0, 0, W, H / 2); ctx.clip();   // sky only — the ground occludes the rest
    const glow = ctx.createRadialGradient(sx, sy, 8 * vScale, sx, sy, 340 * vScale);
    glow.addColorStop(0, 'rgba(255,201,128,0.85)');
    glow.addColorStop(0.4, 'rgba(255,150,92,0.32)');
    glow.addColorStop(1, 'rgba(255,150,92,0)');
    ctx.fillStyle = glow; ctx.fillRect(0, 0, W, H / 2);
    const sun = ctx.createRadialGradient(sx, sy, 4 * vScale, sx, sy, SUN_RADIUS_PX * vScale);
    sun.addColorStop(0, '#ffe6a3'); sun.addColorStop(1, '#ff9d5c');
    ctx.fillStyle = sun;
    ctx.beginPath(); ctx.arc(sx, sy, SUN_RADIUS_PX * vScale, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }

  ctx.fillStyle = ROCK_WEST; silhouette(westRange, H / 2);                          // westward range, over the sun
  ctx.fillStyle = ROCK; silhouette(northRange, H / 2);                              // northern range
  // snowcaps: the north range ABOVE a gently CURVED snowline. Clip to the band above that curve and
  // paint the range in the (dusk-dimmed) snow colour. The curved clip base avoids the old
  // max()-with-flat-bottom trick, whose sub-pixel slivers showed against a dark sky.
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(-overscan, 0);
  ctx.lineTo(W + overscan, 0);
  for (let x = W + overscan; x >= -overscan; x -= 2) ctx.lineTo(x, H / 2 - snowlineAt(bearingAt(x)) * vScale);
  ctx.closePath();
  ctx.clip();
  ctx.fillStyle = snowColor(step); silhouette(northRange, H / 2);
  ctx.restore();
  ctx.fillStyle = LAND; silhouette(groundBase, H / 2);                              // rolling land, in front
}
