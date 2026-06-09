// guard_rail — the metal barrier riding the outer edge of a corner: a single horizontal bar on
// thin upright posts. intersection.ts knows the corner's shape and builds the PATH the rail
// follows on the ground; buildGuardRail raises that path into 3D polygons.

import { clipNear } from './scenery.ts';
import type { RiderPt, Poly3, Project, Ctx } from './scenery.ts';

const RAIL_HEIGHT = 0.5;             // the bar's centre, above the ground (metres)
const RAIL_THICKNESS = 0.1;          // the bar's vertical thickness
const RAIL_POST_WIDTH = 0.02;        // each upright post's width
const RAIL_METAL = '#c2c7cf';        // the bar (bright metallic)
const RAIL_POST_METAL = '#9aa0a8';   // the posts (a touch darker)
export const RAIL_RUNOUT = 10;            // metres the rail runs past the arc along each segment's outer edge
export const RAIL_POST_SPACING_DEG = 5;   // one post every this many degrees of the corner arc

// Raise the rail along `path` (its ground centreline in the Rider's frame, one post per point):
// a single ribbon bar at RAIL_HEIGHT, plus a slim upright post at each point whose width is laid
// along the local run direction, so it reads edge-on from the road.
export function buildGuardRail(path: RiderPt[]): Poly3[] {
  const barTop = RAIL_HEIGHT + RAIL_THICKNESS / 2, barBot = RAIL_HEIGHT - RAIL_THICKNESS / 2;
  const polys: Poly3[] = [];

  const upper = path.map((p) => ({ right: p.right, forward: p.forward, height: barTop }));
  const lower = path.map((p) => ({ right: p.right, forward: p.forward, height: barBot }));
  polys.push({ pts: [...upper, ...lower.reverse()], color: RAIL_METAL });

  const halfPost = RAIL_POST_WIDTH / 2;
  for (let i = 0; i < path.length; i++) {
    const a = path[Math.max(0, i - 1)], b = path[Math.min(path.length - 1, i + 1)];
    const len = Math.hypot(b.right - a.right, b.forward - a.forward) || 1;
    const ox = ((b.right - a.right) / len) * halfPost, of = ((b.forward - a.forward) / len) * halfPost;
    const p = path[i];
    polys.push({ pts: [
      { right: p.right - ox, forward: p.forward - of, height: 0 },
      { right: p.right + ox, forward: p.forward + of, height: 0 },
      { right: p.right + ox, forward: p.forward + of, height: barTop },
      { right: p.right - ox, forward: p.forward - of, height: barTop },
    ], color: RAIL_POST_METAL });
  }
  return polys;
}

// Draw one raised rail polygon (a band or a post): near-clip its corners, project them, fill. Same
// pipeline as a road quad, but the corners already carry their own heights, so it stands above the
// pavement (and is drawn after the road for that reason).
export function drawGuardRail(ctx: Ctx, rail: Poly3, project: Project): void {
  const clipped = clipNear(rail.pts);
  if (clipped.length < 3) return;
  ctx.fillStyle = rail.color;
  ctx.beginPath();
  const p0 = project(clipped[0].right, clipped[0].forward, clipped[0].height);
  ctx.moveTo(p0.x, p0.y);
  for (let i = 1; i < clipped.length; i++) {
    const p = project(clipped[i].right, clipped[i].forward, clipped[i].height);
    ctx.lineTo(p.x, p.y);
  }
  ctx.closePath();
  ctx.fill();
}
