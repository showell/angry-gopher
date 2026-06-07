// =============================================================================
// tower — the radio tower that stands beyond each intersection: a tall square-base
// lattice pyramid of metal rods. The first of the "truly 3D" landmarks an
// intersection owns (an intersection is a PLACE, not just a junction). This module
// owns the tower's dimensions and how it draws; the intersection only places it,
// 100m past the corner and dead ahead of the approaching Rider (the same "beyond
// the turn, in his facing direction" spot the corner creatures' baby uses).
//
// Cheap by construction: a see-through wire lattice of flat rod-quads (no solid
// faces, so no back-face culling — you simply see at most two faces), no near-clip
// (it's always far off), and a self-chosen LOD that drops to just the four legs
// beyond TOWER_NEAR_DIST so only the closest tower pays for its cross-beams.
// =============================================================================

import type { Project, Ctx, Scenery, RiderPt } from './scenery.ts';

// ---- dimensions (metres) ----
const TOWER_HEIGHT = 100;              // apex height
const TOWER_HALF = 5;                  // half the 10m square base edge
const TOWER_BEYOND = 100;              // how far past the corner it stands, along the approach direction
const STAGE_HEIGHT = 20;              // a cross-beam ring every this many metres (5 stages => rings at 20/40/60/80)
const ROD_HALF = 0.5;                 // half the 1m rod thickness
const TOWER_YAW = 30 * Math.PI / 180; // turn the square off head-on so the Rider sees two faces, not one

// The renderer's DETAIL_DIST (40m) is tuned for roadside critters; a 100m tower is never that
// close, so the tower picks its OWN level of detail: the full lattice only within this range
// (in practice just the nearest tower), bare legs beyond.
const TOWER_NEAR_DIST = 250;

const LEG_METAL = '#9aa0a8';   // the four sloping legs (a touch darker)
const BEAM_METAL = '#c2c7cf';  // the horizontal cross-beams (brighter)

// a rider-frame point carrying a height off the ground
interface Pt3 { right: number; forward: number; height: number }
interface Rod { pts: Pt3[]; color: string }

// the square's four base corners, in half-base units, before the yaw
const CORNERS = [[-1, -1], [1, -1], [1, 1], [-1, 1]];

// Build the tower standing beyond the intersection whose incoming segment is `fromLength`
// long. `map(a, x)` takes a point in that segment's BL frame (a along, x across-from-left) to
// the Rider's frame — the same mapper the intersection uses for its other scenery.
export function towerScenery(map: (a: number, x: number) => RiderPt, fromLength: number, hw: number): Scenery {
  const a0 = fromLength + TOWER_BEYOND;   // dead ahead of the corner, in the approach direction
  const x0 = hw;                          // centred on the lane (BL across = the road half-width)
  const cy = Math.cos(TOWER_YAW), sy = Math.sin(TOWER_YAW);

  // corner k of the cross-section at height h, in the Rider's frame. The square shrinks
  // linearly to a point at the apex, and is yawed about the vertical axis.
  const at = (k: number, h: number): Pt3 => {
    const s = TOWER_HALF * (1 - h / TOWER_HEIGHT);
    const du = CORNERS[k][0] * s, dv = CORNERS[k][1] * s;
    const ru = du * cy - dv * sy, rv = du * sy + dv * cy;   // yaw
    const p = map(a0 + rv, x0 + ru);
    return { right: p.right, forward: p.forward, height: h };
  };

  // a rod as a flat 1m-wide ribbon between two points. Near-vertical legs take their width
  // horizontally (offset in `right`); horizontal beams take it vertically (offset in height) —
  // whichever direction reads as thickness from the road.
  const legRod = (a: Pt3, b: Pt3): Rod => ({ color: LEG_METAL, pts: [
    { right: a.right - ROD_HALF, forward: a.forward, height: a.height },
    { right: b.right - ROD_HALF, forward: b.forward, height: b.height },
    { right: b.right + ROD_HALF, forward: b.forward, height: b.height },
    { right: a.right + ROD_HALF, forward: a.forward, height: a.height },
  ] });
  const beamRod = (a: Pt3, b: Pt3): Rod => ({ color: BEAM_METAL, pts: [
    { right: a.right, forward: a.forward, height: a.height - ROD_HALF },
    { right: b.right, forward: b.forward, height: b.height - ROD_HALF },
    { right: b.right, forward: b.forward, height: b.height + ROD_HALF },
    { right: a.right, forward: a.forward, height: a.height + ROD_HALF },
  ] });

  const apex = at(0, TOWER_HEIGHT);   // s = 0, so every corner converges here
  const legs: Rod[] = [];
  for (let k = 0; k < 4; k++) legs.push(legRod(at(k, 0), apex));
  const beams: Rod[] = [];
  for (let h = STAGE_HEIGHT; h < TOWER_HEIGHT; h += STAGE_HEIGHT) {
    for (let k = 0; k < 4; k++) beams.push(beamRod(at(k, h), at((k + 1) % 4, h)));
  }

  // draw the lattice back-to-front so the near face's rods overpaint the far face's.
  const avgF = (r: Rod): number => (r.pts[0].forward + r.pts[1].forward + r.pts[2].forward + r.pts[3].forward) / 4;
  const sortBack = (rods: Rod[]): Rod[] => [...rods].sort((p, q) => avgF(q) - avgF(p));
  const near = sortBack([...legs, ...beams]);
  const far = sortBack(legs);

  const fill = (ctx: Ctx, project: Project, rods: Rod[]): void => {
    for (const rod of rods) {
      ctx.fillStyle = rod.color;
      ctx.beginPath();
      const s0 = project(rod.pts[0].right, rod.pts[0].forward, rod.pts[0].height);
      ctx.moveTo(s0.x, s0.y);
      for (let i = 1; i < rod.pts.length; i++) {
        const s = project(rod.pts[i].right, rod.pts[i].forward, rod.pts[i].height);
        ctx.lineTo(s.x, s.y);
      }
      ctx.closePath();
      ctx.fill();
    }
  };

  const center = map(a0, x0);
  // full lattice only for the nearest tower; bare legs for the rest (see TOWER_NEAR_DIST).
  const draw = (ctx: Ctx, project: Project): void =>
    fill(ctx, project, center.forward < TOWER_NEAR_DIST ? near : far);

  return { forward: center.forward, height: TOWER_HEIGHT, drawAsNear: draw, drawAsFar: draw };
}
