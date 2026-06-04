// =============================================================================
// horizon — far scenery as layered silhouettes. Everything here is at infinity:
// apparent position depends only on which way the Rider FACES, not where it is.
// So each layer is a pure function from absolute bearing (radians, 0 = north,
// + = clockwise / to the Rider's right) to a height in pixels above the horizon.
//
//   groundBase  — a gentle roll present at EVERY bearing (the sloped horizon)
//   northRange  — a tall range centred on north (drawn snowcapped)
//   westRange   — a second range to the west, with the sun setting over it
// =============================================================================

function wrap(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

// seg7 faces ~ -120deg (WSW), so centring the westward range there puts it
// straight ahead on seg7. The sun sits a little further south & left (more
// negative bearing), setting over the range's crest.
export const WEST_RANGE_BEARING = -2.094;   // -120deg = seg7's heading
export const SUN_BEARING = -2.27;           // ~ -130deg: a touch south & left of straight-ahead
export const SNOWLINE = 95;                 // px above the horizon; the north range is snowcapped above this

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
export function groundBase(bearing: number): number {
  return 18 + 12 * Math.sin(wrap(bearing) * 0.9 + 1.9);   // ~6..30px, long wavelength
}

export const northRange = (bearing: number): number => range(bearing, 0, 0.95, 150, 8, 21);
export const westRange = (bearing: number): number => range(bearing, WEST_RANGE_BEARING, 0.72, 120, 11, 27);
