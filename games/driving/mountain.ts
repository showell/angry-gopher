// mountain — the far ranges, their snowcaps, and the rolling land, all at infinity: each is a
// pure function from absolute bearing (radians, 0 = north, + = clockwise) to a height in pixels
// above the horizon. The light dims them toward dusk, so we read the sunset clock from sun.ts.

import { sunSetFraction } from './sun.ts';

function wrap(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

const WEST_RANGE_BEARING = -2.0416;   // the range the sun sets behind (near sun.ts's SUN_BEARING)

const ROCK = '#5b6a8f';        // northern range
const ROCK_WEST = '#39435f';   // westward range, darker — backlit by the sunset
const LAND = '#4a8f43';        // foreground rolling land (matches the grass)
const SNOW_DAY = [238, 243, 248];
const SNOW_NIGHT = [70, 84, 104];

const ROCK_NIGHT_DIM = 0.5;   // rock fades to this fraction of its day brightness by night — stays below the snow
const SNOW_THRESHOLD = 124;   // only ridge taller than this gets snow — isolates the single tallest hump
const SNOW_DIP = 10;          // how far the snowline dips under the summit — the snowcap base's curve depth

// One range: a smooth envelope (tallest at centre, tapering to open sky at its edges) times a
// fixed rugged ridge line.
function range(bearing: number, center: number, half: number, peak: number,
               freqA: number, freqB: number): number {
  const b = wrap(bearing - center);
  const t = b / half;
  if (Math.abs(t) >= 1) return 0;
  const envelope = Math.cos(t * Math.PI / 2);
  const ridge = 0.6 + 0.24 * Math.cos(b * freqA) + 0.16 * Math.cos(b * freqB + 1.0);
  return peak * envelope * ridge;
}

// The horizon gently rolls even between the ranges — never a flat line.
function groundBase(bearing: number): number {
  return 18 + 12 * Math.sin(wrap(bearing) * 0.9 + 1.9);
}

const northRange = (bearing: number): number => range(bearing, 0, 0.95, 150, 8, 21);
const westRange = (bearing: number): number => range(bearing, WEST_RANGE_BEARING, 0.72, 120, 11, 27);

// the tallest silhouette at a bearing — the effective occluder of the sun there.
export function horizonCrestPx(bearing: number): number {
  return Math.max(westRange(bearing), northRange(bearing), groundBase(bearing));
}

// The snowcap sits ONLY on the north range's single tallest hump, and its base FOLLOWS the ridge
// (dipping under the summit) so it reads as curved, not a flat line.
const SNOW_PEAK_HEIGHT = (() => {
  let vm = -1;
  for (let b = -0.5; b <= 0.5; b += 0.01) vm = Math.max(vm, northRange(b));
  return vm;
})();
const snowlineAt = (bearing: number): number => {
  const above = Math.max(0, Math.min(1, (northRange(bearing) - SNOW_THRESHOLD) / (SNOW_PEAK_HEIGHT - SNOW_THRESHOLD)));
  return SNOW_THRESHOLD - SNOW_DIP * above;
};

// snow loses its glare through the ride, dimming toward dusk.
function snowColor(step: number): string {
  const t = sunSetFraction(step);
  const c = (i: number): number => Math.round(SNOW_DAY[i] + (SNOW_NIGHT[i] - SNOW_DAY[i]) * t);
  return `rgb(${c(0)},${c(1)},${c(2)})`;
}

// darken a hex toward dusk; the multiplier keeps the rock always below the (also-dimming) snow.
function dimmed(hex: string, step: number): string {
  const f = 1 - ROCK_NIGHT_DIM * sunSetFraction(step);
  const n = parseInt(hex.slice(1), 16);
  const c = (sh: number): number => Math.round(((n >> sh) & 255) * f);
  return `rgb(${c(16)},${c(8)},${c(0)})`;
}

// Paint the westward and (snowcapped) northern ranges and the rolling land for the Rider's
// heading. `overscan` widens the fills past the screen edges so a rolled camera still finds land
// out to the rotated corners; vScale = focal/baseFocal squeezes the heights to match a lean.
export function drawMountains(ctx: CanvasRenderingContext2D, heading: number, W: number, H: number,
                              FOCAL: number, overscan: number, vScale: number, step: number): void {
  const bearingAt = (x: number): number => heading + Math.atan((x - W / 2) / FOCAL);
  const silhouette = (f: (b: number) => number, bottomY: number): void => {
    ctx.beginPath();
    ctx.moveTo(-overscan, bottomY);
    for (let x = -overscan; x <= W + overscan; x += 2) ctx.lineTo(x, H / 2 - f(bearingAt(x)) * vScale);
    ctx.lineTo(W + overscan, bottomY);
    ctx.closePath();
    ctx.fill();
  };

  ctx.fillStyle = dimmed(ROCK_WEST, step); silhouette(westRange, H / 2);
  ctx.fillStyle = dimmed(ROCK, step); silhouette(northRange, H / 2);

  // snowcaps: the north range clipped to the band above its curved snowline, painted in snow.
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(-overscan, 0);
  ctx.lineTo(W + overscan, 0);
  for (let x = W + overscan; x >= -overscan; x -= 2) ctx.lineTo(x, H / 2 - snowlineAt(bearingAt(x)) * vScale);
  ctx.closePath();
  ctx.clip();
  ctx.fillStyle = snowColor(step); silhouette(northRange, H / 2);
  ctx.restore();

  ctx.fillStyle = LAND; silhouette(groundBase, H / 2);
}
