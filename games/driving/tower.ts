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
// DETAIL_DIST: a full perspective lattice within TOWER_NEAR_DIST, and beyond that the SAME four
// faces drawn as a flat billboard (project the base corners + apex, interpolate the rest in 2D).
// A far tower has no perceptible depth, so the flat version reads identically — and because it
// keeps all four faces, the back leg doesn't pop into view as a tower crosses the threshold. The
// flat path also skips the per-vertex frame-mapping and near-clip the 3D one needs.
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

// Beyond this range a tower switches from the perspective lattice to the flat billboard. Both
// draw all four faces, so nothing pops — the only thing lost is parallax, imperceptible this far off.
const TOWER_NEAR_DIST = 400;

const TOWER_METAL = '#9aa0a8';   // every rod — legs, rings, and braces — one darker gray

// ---- the beacon at the apex ----
const BEACON_PERIOD = 240;       // frames for a full invisible -> bright -> invisible cycle
const BEACON_RADIUS = 2.5;       // 5m-diameter sphere, drawn as a flat disc
const BEACON_COLOR = '#ff2fe6';  // vivid pink

// The blink is a pure function of the step (used as a clock), so it's identical on pause and
// runs backwards on reverse — no wall-clock state. Each tower gets an authored phase offset so
// they don't blink in unison. brightness: 0 (invisible) at the cycle ends, 1 (full) at the middle.
export function beaconOffsetFor(segNum: number): number {
  return (segNum * 37) % BEACON_PERIOD;   // 37 is coprime to 120 — spreads the offsets, all distinct
}
function beaconBrightness(step: number): number {
  const phase = ((step % BEACON_PERIOD) + BEACON_PERIOD) % BEACON_PERIOD;
  return (1 - Math.cos(2 * Math.PI * phase / BEACON_PERIOD)) / 2;
}

// a rider-frame point carrying a height off the ground
interface Pt3 { right: number; forward: number; height: number }
interface Rod { pts: Pt3[]; color: string }
interface Pt2 { x: number; y: number }   // a projected screen point (the flat path works in 2D)

// ---- local ground curvature (proof of concept: towers only) ----
// The greater world (mountains, sun, horizon) sits on a flat plane, so the true horizon is at eye
// level and never moves. The LOCAL ground is a spherical plateau of radius EARTH_RADIUS: it drops
// d^2/(2R) below the Rider's tangent plane at horizontal distance d. A tower that far out gets BOTH
// effects: its whole height is lowered by that drop (it stands on lower ground), AND the part now
// below the horizon is clipped (hidden behind the bulge). Net: the visible tower rises from the
// horizon line with its apex pulled down. Small R = exaggerated.
const EARTH_RADIUS = 5000;
function groundDrop(p: RiderPt): number {
  return (p.right * p.right + p.forward * p.forward) / (2 * EARTH_RADIUS);
}
// project with the tower lowered by its ground drop, so the apex sinks and the clipped base lands
// on the horizon line (render-height 0).
function lowered(project: Project, drop: number): Project {
  return (right, forward, height) => project(right, forward, height - drop);
}

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

// Clip a rod polygon to the part at or above `minH` — the bottom hidden by the ground bulge.
function clipAbove(pts: Pt3[], minH: number): Pt3[] {
  const out: Pt3[] = [];
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length];
    const aIn = a.height >= minH, bIn = b.height >= minH;
    if (aIn) out.push(a);
    if (aIn !== bIn) {
      const f = (minH - a.height) / (b.height - a.height);
      out.push({
        right: a.right + f * (b.right - a.right),
        forward: a.forward + f * (b.forward - a.forward),
        height: minH,
      });
    }
  }
  return out;
}

// the square's four base corners, in half-base units, before the yaw
const CORNERS = [[-1, -1], [1, -1], [1, 1], [-1, 1]];

// Build the tower standing beyond the intersection whose incoming segment is `fromLength`
// long. `map(a, x)` takes a point in that segment's BL frame (a along, x across-from-left) to
// the Rider's frame — the same mapper the intersection uses for its other scenery. `step` is the
// frame clock and `beaconOffset` this tower's authored blink phase (see beaconBrightness).
export function towerScenery(map: (a: number, x: number) => RiderPt, fromLength: number, hw: number, step: number, beaconOffset: number): Scenery {
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
  const center = map(a0, x0);

  // ---- NEAR: the full perspective lattice (built lazily — a far tower never pays for it) ----
  // Four sloping legs, horizontal cross-beam rings (the top stage tapers to the apex, so no ring
  // there), and X-braces on the bottom BRACE_STAGES stage faces, both diagonals crossing into an X.
  const lattice = (): Rod[] => {
    const rods: Rod[] = [];
    for (let k = 0; k < 4; k++) rods.push(barH(at(k, 0), apex, TOWER_METAL));
    for (let h = STAGE_HEIGHT; h < TOWER_HEIGHT; h += STAGE_HEIGHT) {
      for (let k = 0; k < 4; k++) rods.push(barV(at(k, h), at((k + 1) % 4, h), TOWER_METAL));
    }
    for (let h = 0; h < BRACE_STAGES * STAGE_HEIGHT; h += STAGE_HEIGHT) {
      const hi = h + STAGE_HEIGHT;
      for (let k = 0; k < 4; k++) {
        const j = (k + 1) % 4;
        rods.push(barH(at(k, h), at(j, hi), TOWER_METAL));
        rods.push(barH(at(j, h), at(k, hi), TOWER_METAL));
      }
    }
    return rods;
  };
  // back-to-front so the near face's rods overpaint the far face's.
  const avgF = (r: Rod): number => (r.pts[0].forward + r.pts[1].forward + r.pts[2].forward + r.pts[3].forward) / 4;
  const sortBack = (rods: Rod[]): Rod[] => [...rods].sort((p, q) => avgF(q) - avgF(p));

  const drawNear = (ctx: Ctx, project: Project, clipH: number): void => {
    for (const rod of sortBack(lattice())) {
      // near-clip (a rod straddling the near plane would streak across the view), then clip off
      // the bottom hidden by the ground bulge.
      const pts = clipAbove(clipNear(rod.pts), clipH);
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

  // ---- FAR: the same four faces, flat. Project the base corners + apex once, then derive every
  // ring corner by 2D interpolation up the legs (the cross-section shrinks linearly to the apex).
  // No parallax, but all four faces, so the back leg is present at the threshold just like near. ----
  const ROD_W = ROD_HALF * 2;
  const drawFlat = (ctx: Ctx, project: Project, clipH: number): void => {
    const ps = (p: Pt3): Pt2 => project(p.right, p.forward, p.height);
    const baseS = [ps(at(0, 0)), ps(at(1, 0)), ps(at(2, 0)), ps(at(3, 0))];
    const apexS = ps(apex);
    const wpx = ROD_W * (project(1, center.forward, 0).x - project(0, center.forward, 0).x);   // rod width in px at this depth
    const lerp = (a: Pt2, b: Pt2, t: number): Pt2 => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });
    const ring = (k: number, h: number): Pt2 => lerp(baseS[k], apexS, h / TOWER_HEIGHT);   // screen point of corner k at world height h
    const bar = (A: Pt2, B: Pt2): void => {   // a thick screen-space line as a filled quad
      const dx = B.x - A.x, dy = B.y - A.y, len = Math.hypot(dx, dy) || 1;
      const ox = -dy / len * wpx / 2, oy = dx / len * wpx / 2;
      ctx.beginPath();
      ctx.moveTo(A.x + ox, A.y + oy); ctx.lineTo(B.x + ox, B.y + oy);
      ctx.lineTo(B.x - ox, B.y - oy); ctx.lineTo(A.x - ox, A.y - oy);
      ctx.closePath();
      ctx.fill();
    };
    ctx.fillStyle = TOWER_METAL;
    for (let k = 0; k < 4; k++) bar(ring(k, clipH), apexS);                            // legs (from the drop height up)
    for (let h = STAGE_HEIGHT; h < TOWER_HEIGHT; h += STAGE_HEIGHT) {
      if (h <= clipH) continue;                                                        // ring hidden by the bulge
      for (let k = 0; k < 4; k++) bar(ring(k, h), ring((k + 1) % 4, h));               // rings
    }
    for (let h = 0; h < BRACE_STAGES * STAGE_HEIGHT; h += STAGE_HEIGHT) {
      const hi = h + STAGE_HEIGHT;
      if (hi <= clipH) continue;                                                       // whole stage hidden
      const f = (Math.max(h, clipH) - h) / STAGE_HEIGHT;                               // where each diagonal meets the drop height
      for (let k = 0; k < 4; k++) {
        const j = (k + 1) % 4;
        bar(lerp(ring(k, h), ring(j, hi), f), ring(j, hi));                            // diagonal k.bottom -> j.top, clipped
        bar(lerp(ring(j, h), ring(k, hi), f), ring(k, hi));                            // diagonal j.bottom -> k.top, clipped
      }
    }
  };

  // ---- the apex beacon: a glowing pink disc whose SIZE scales with distance but whose
  // BRIGHTNESS (alpha) does not — a depthless glow that blinks on the step clock. ----
  const beacon = beaconBrightness(step + beaconOffset);
  const drawBeacon = (ctx: Ctx, project: Project): void => {
    if (beacon < 0.02) return;   // skip the invisible part of the cycle
    if (apex.forward < NEAR) return;
    const s = project(apex.right, apex.forward, apex.height);
    const r = BEACON_RADIUS * (project(1, apex.forward, 0).x - project(0, apex.forward, 0).x);
    ctx.globalAlpha = beacon;
    ctx.fillStyle = BEACON_COLOR;
    ctx.beginPath();
    ctx.arc(s.x, s.y, r, 0, 2 * Math.PI);
    ctx.fill();
    ctx.globalAlpha = 1;
  };

  const draw = (ctx: Ctx, project: Project): void => {
    const drop = groundDrop(center);    // how far the local ground has fallen at this tower
    if (drop >= TOWER_HEIGHT) return;   // the whole tower has sunk below the horizon
    const lp = lowered(project, drop);  // lower the tower by the drop; clipping at `drop` then lands its base on the horizon
    (center.forward < TOWER_NEAR_DIST ? drawNear : drawFlat)(ctx, lp, drop);
    drawBeacon(ctx, lp);   // the apex (always above the drop) lowers with the tower
  };

  return { forward: center.forward, height: TOWER_HEIGHT, drawAsNear: draw, drawAsFar: draw };
}
