// =============================================================================
// horizon — far scenery as a silhouette. A mountain range sits to the NORTH,
// effectively at infinity: its apparent position depends only on which way the
// car FACES, not where it is (over our route the distance change is negligible).
// So the horizon is a pure function from absolute bearing (radians, 0 = north,
// + = clockwise / to the car's right) to its height in pixels above the horizon.
// =============================================================================

function wrap(a: number): number {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

const RANGE_HALF = 0.95;   // angular half-width of the range (~54deg each side of north)
const PEAK = 150;          // tallest peak, pixels above the horizon line

// Height (px) of the mountain silhouette at the given absolute bearing: a smooth
// envelope (tallest at north, tapering to open sky at the range's edges) times a
// fixed rugged ridge line.
export function horizonHeight(bearing: number): number {
  const b = wrap(bearing);
  const t = b / RANGE_HALF;                                  // -1..1 across the range
  if (Math.abs(t) >= 1) return 0;                            // open sky beyond the range
  const envelope = Math.cos(t * Math.PI / 2);                // smooth taper to 0 at the edges
  const ridge = 0.6 + 0.24 * Math.cos(b * 8) + 0.16 * Math.cos(b * 21 + 1.0);   // rugged peaks
  return PEAK * envelope * ridge;
}
