// =============================================================================
// tower — the radio tower that stands beyond each intersection: a tall square-base
// lattice pyramid of metal rods. The first of the "truly 3D" landmarks an
// intersection owns (an intersection is a PLACE, not just a junction). This module
// owns the tower's dimensions and how it draws; the intersection only places it, out past the
// corner and off to the right, in the direction the Rider faces as he approaches (the same
// "beyond the turn, in his facing direction" idea the corner creatures' baby uses).
//
// Cheap by construction: a see-through wire lattice of flat rod-quads (no solid faces).
// It picks its OWN level of detail, since a tower is never within the renderer's critter-tuned
// DETAIL_DIST: the full four-faced lattice within TOWER_NEAR_DIST, and beyond that just the two
// faces nearest the Rider — at distance there's no perceptible depth to a 12m-deep tower, so the
// back leg and back-face beams are pure cost. (The earlier far-LOD dropped the beams entirely,
// but their absence read clearly even at range; the front two faces keep them.)
// =============================================================================

import { NEAR } from './scenery.ts';
import type { Project, Ctx, Scenery, RiderPt } from './scenery.ts';

// ---- dimensions (metres) ----
const TOWER_HEIGHT = 80;               // apex height
const TOWER_HALF = 6;                  // half the 12m square base edge
const TOWER_BEYOND = 160;             // how far past the corner it stands, along the approach direction
const TOWER_RIGHT = 20;              // offset to the right of the lane, so you don't bear down on it dead-on
const STAGE_HEIGHT = 20;              // a cross-beam ring every this many metres (rings at 20/40/60)
const BRACE_STAGES = 2;              // X-braces only on the bottom this-many stages (cheaper, and where they matter structurally)
const ROD_HALF = 0.12;               // half the rod thickness
const TOWER_YAW = 30 * Math.PI / 180; // turn the square off head-on so the Rider sees two faces, not one

// Beyond this range a tower drops from the full four-faced lattice to just its two nearest faces
// (no perceptible depth at distance). Both keep their cross-beams, so the threshold is barely
// visible — it only swaps the unseen back of the tower in and out.
const TOWER_NEAR_DIST = 400;

const TOWER_METAL = '#9aa0a8';   // every rod — legs, rings, and braces — one darker gray

// a rider-frame point carrying a height off the ground
interface Pt3 { right: number; forward: number; height: number }
interface Rod { pts: Pt3[]; color: string }

// Clip a rod polygon against the near plane (forward >= NEAR) in 3D, before projecting —
// the same Sutherland-Hodgman the renderer runs on road quads, here on height-carrying points.
function clipNear(pts: Pt3[]): Pt3[] {
  const out: Pt3[] = [];
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length];
    const aIn = a.forward >= NEAR, bIn = b.forward >= NEAR;
    if (aIn) out.push(a);
    if (aIn !== bIn) {
      const f = (NEAR - a.forward) / (b.forward - a.forward);
      out.push({
        right: a.right + f * (b.right - a.right),
        forward: NEAR,
        height: a.height + f * (b.height - a.height),
      });
    }
  }
  return out;
}

// the square's four base corners, in half-base units, before the yaw
const CORNERS = [[-1, -1], [1, -1], [1, 1], [-1, 1]];

// Build the tower standing beyond the intersection whose incoming segment is `fromLength`
// long. `map(a, x)` takes a point in that segment's BL frame (a along, x across-from-left) to
// the Rider's frame — the same mapper the intersection uses for its other scenery.
export function towerScenery(map: (a: number, x: number) => RiderPt, fromLength: number, hw: number): Scenery {
  const a0 = fromLength + TOWER_BEYOND;   // out ahead of the corner, in the approach direction
  const x0 = hw + TOWER_RIGHT;            // and off to the right (BL across = half-width is the centreline)
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

  // a rod as a flat thin ribbon between two points. Sloping rods (legs, diagonal braces) take
  // their width horizontally (offset in `right`); horizontal beams take it vertically (offset in
  // height) — whichever direction reads as thickness from the road.
  const barH = (a: Pt3, b: Pt3, color: string): Rod => ({ color, pts: [
    { right: a.right - ROD_HALF, forward: a.forward, height: a.height },
    { right: b.right - ROD_HALF, forward: b.forward, height: b.height },
    { right: b.right + ROD_HALF, forward: b.forward, height: b.height },
    { right: a.right + ROD_HALF, forward: a.forward, height: a.height },
  ] });
  const barV = (a: Pt3, b: Pt3, color: string): Rod => ({ color, pts: [
    { right: a.right, forward: a.forward, height: a.height - ROD_HALF },
    { right: b.right, forward: b.forward, height: b.height - ROD_HALF },
    { right: b.right, forward: b.forward, height: b.height + ROD_HALF },
    { right: a.right, forward: a.forward, height: a.height + ROD_HALF },
  ] });

  const apex = at(0, TOWER_HEIGHT);   // s = 0, so every corner converges here

  // A face `k` spans corners k and k+1. Build the lattice over a chosen set of legs (corner
  // indices) and faces (face indices) — the whole tower for the near LOD, the two front faces
  // for the far one.
  const lattice = (legCorners: number[], faceKs: number[]): Rod[] => {
    const rods: Rod[] = [];
    for (const k of legCorners) rods.push(barH(at(k, 0), apex, TOWER_METAL));   // sloping legs
    // horizontal cross-beam rings (the top stage tapers to the apex, so no ring there)
    for (let h = STAGE_HEIGHT; h < TOWER_HEIGHT; h += STAGE_HEIGHT) {
      for (const k of faceKs) rods.push(barV(at(k, h), at((k + 1) % 4, h), TOWER_METAL));
    }
    // X-bracing on the bottom BRACE_STAGES stage faces: both diagonals of each, crossing into an X.
    for (let h = 0; h < BRACE_STAGES * STAGE_HEIGHT; h += STAGE_HEIGHT) {
      const hi = h + STAGE_HEIGHT;
      for (const k of faceKs) {
        const j = (k + 1) % 4;
        rods.push(barH(at(k, h), at(j, hi), TOWER_METAL));
        rods.push(barH(at(j, h), at(k, hi), TOWER_METAL));
      }
    }
    return rods;
  };

  // draw the lattice back-to-front so the near face's rods overpaint the far face's.
  const avgF = (r: Rod): number => (r.pts[0].forward + r.pts[1].forward + r.pts[2].forward + r.pts[3].forward) / 4;
  const sortBack = (rods: Rod[]): Rod[] => [...rods].sort((p, q) => avgF(q) - avgF(p));

  // near: the whole tower. far: only the two faces flanking the corner closest to the Rider —
  // those are its three legs and two faces; the back corner and its faces aren't seen at range.
  const near = sortBack(lattice([0, 1, 2, 3], [0, 1, 2, 3]));
  let fc = 0;   // the front (nearest) corner
  for (let k = 1; k < 4; k++) if (at(k, 0).forward < at(fc, 0).forward) fc = k;
  const far = sortBack(lattice([(fc + 3) % 4, fc, (fc + 1) % 4], [(fc + 3) % 4, fc]));

  const fill = (ctx: Ctx, project: Project, rods: Rod[]): void => {
    for (const rod of rods) {
      // near-clip first: a rod that straddles the near plane (one corner beside/behind the
      // Rider on a sharp turn) would otherwise project to a sliver streaking across the view.
      const pts = clipNear(rod.pts);
      if (pts.length < 3) continue;
      ctx.fillStyle = rod.color;
      ctx.beginPath();
      const s0 = project(pts[0].right, pts[0].forward, pts[0].height);
      ctx.moveTo(s0.x, s0.y);
      for (let i = 1; i < pts.length; i++) {
        const s = project(pts[i].right, pts[i].forward, pts[i].height);
        ctx.lineTo(s.x, s.y);
      }
      ctx.closePath();
      ctx.fill();
    }
  };

  const center = map(a0, x0);
  // full four-faced lattice for a near tower; the two front faces for the rest (see TOWER_NEAR_DIST).
  const draw = (ctx: Ctx, project: Project): void =>
    fill(ctx, project, center.forward < TOWER_NEAR_DIST ? near : far);

  return { forward: center.forward, height: TOWER_HEIGHT, drawAsNear: draw, drawAsFar: draw };
}
