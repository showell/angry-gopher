// =============================================================================
// tree — the roadside trees: where they stand on a segment (with a clear zone
// near intersections), their colour by scheme, their size by position parity, and
// how they're drawn (a tiered conifer). The rest of the app just asks a segment
// for its trees and throws the drawn shapes on the canvas.
// =============================================================================
import type { Project, Ctx, Scenery } from './scenery.ts';

// A segment's tree theme. ALL_GREEN: all green. YELLOW_GREEN / RED_GREEN: green
// alternating with a golden / red accent. Every tree is a conifer either way.
export type Scheme = 'ALL_GREEN' | 'YELLOW_GREEN' | 'RED_GREEN';

// A tree in its SEGMENT's frame: `along` the segment, `across` from the centre.
export interface Tree { along: number; across: number; color: string; height: number }

// A tree placed in the scene, measured FROM THE RIDER and ready to draw.
export interface TreeView { at: { right: number; forward: number }; color: string; height: number }

// Wrap a placed tree as Scenery: cheap all-flat conifer far off, and up close the form
// whose lowest tier is a real 3D cone (drawTreeNear). The renderer picks by DETAIL_DIST.
export function treeScenery(view: TreeView): Scenery {
  return {
    forward: view.at.forward,
    height: view.height,
    drawAsNear: (ctx: Ctx, project: Project): void => drawTreeNear(ctx, view, project),
    drawAsFar: (ctx: Ctx, project: Project): void => drawTree(ctx, view, project),
  };
}

// ---- dimensions (metres) ----
const SMALL_HEIGHT = 4.5;                 // odd-parity conifers (the established small size)
const BIG_SCALE = 1.3;                    // even-parity conifers stand this much taller
const DIST_BETWEEN_TREES = 20;            // tree spacing along a segment
export const TREE_ROAD_OFFSET = 1.5;      // a tree stands this far beyond the lane edge (the bull lines up with it)
const TREE_INTERSECTION_CLEARANCE = 6;    // no trees within this of an intersection

const CONIFER_GREEN = '#1c5a22';   // green conifer (every even tree)
const CONIFER_GOLD = '#cf9a18';    // golden (autumn) accent conifer
const CONIFER_RED = '#b23a2a';     // red accent conifer
const TRUNK = '#5a3e22';

// ---- where the trees are ----

// Both rows of trees along a segment. `entryTan`/`exitTan` are how far the turns
// at each end intrude into the straight; we keep that PLUS a clearance clear, so
// no tree lands on the adjoining road or right at a segment's start/end. Trees
// alternate by parity: even = green and 1.3x tall, odd = the accent colour and small.
export function segmentTrees(length: number, entryTan: number, exitTan: number,
                             scheme: Scheme, laneHalfWidth: number): Tree[] {
  const trees: Tree[] = [];
  const startAlong = entryTan + TREE_INTERSECTION_CLEARANCE;
  const endAlong = length - exitTan - TREE_INTERSECTION_CLEARANCE;
  const treeLine = laneHalfWidth + TREE_ROAD_OFFSET;   // the default tree line, each side of the road
  let k = 0;
  for (let along = startAlong; along <= endAlong; along += DIST_BETWEEN_TREES, k++) {
    const even = k % 2 === 0;
    const color = even ? CONIFER_GREEN : accentColor(scheme);
    let height = even ? SMALL_HEIGHT * BIG_SCALE : SMALL_HEIGHT;
    let x = treeLine;
    if (color === CONIFER_RED) height *= 2;   // red trees: twice as big in every dimension
    if (color === CONIFER_GOLD) {             // yellow trees: 3x as big, set ~4x further off the road
      height *= 3;
      x = laneHalfWidth + 4 * TREE_ROAD_OFFSET;
    }
    trees.push({ along, across: -x, color, height });
    trees.push({ along, across: x, color, height });
  }
  return trees;
}

function accentColor(scheme: Scheme): string {
  if (scheme === 'YELLOW_GREEN') return CONIFER_GOLD;
  if (scheme === 'RED_GREEN') return CONIFER_RED;
  return CONIFER_GREEN;   // ALL_GREEN: the "accent" is just more green
}

// ---- drawing ----

// the eight stacked tiers, as fractions of the CROWN span: each tier's apex (TOP) and
// base (BOT) heights, and its base half-width (WIDE). Narrow at the apex, widest at the
// bottom — the conifer silhouette.
const TIER_TOP = [0.0, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70];
const TIER_BOT = [0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.0];
const TIER_WIDE = [0.35, 0.44, 0.53, 0.63, 0.72, 0.81, 0.91, 1.0];

const VISIBLE_TRUNK = 0.44;   // visible bare trunk, as a fraction of tree height
const CROWN_H = 0.648;        // crown height, as a fraction of tree height
const CROWN_W = 0.288;        // crown base half-width, as a fraction of tree height

// the screen-space layout shared by every tree draw: the ground point, total pixel
// height, the crown apex, the foliage span, and the crown base half-width.
interface TreeMetrics { bx: number; by: number; ht: number; apexY: number; foliage: number; w: number }
function metrics(t: TreeView, project: Project): TreeMetrics {
  const base = project(t.at.right, t.at.forward, 0);
  const ht = base.y - project(t.at.right, t.at.forward, t.height).y;
  const foliage = ht * CROWN_H, crownBottomY = base.y - ht * VISIBLE_TRUNK;   // crown rests here, grows UP
  return { bx: base.x, by: base.y, ht, apexY: crownBottomY - foliage, foliage, w: ht * CROWN_W };
}

// shift a #rrggbb by a brightness factor (f > 1 lighter, f < 1 darker), clamped.
function shade(hex: string, f: number): string {
  const n = parseInt(hex.slice(1), 16);
  const c = (v: number): number => Math.max(0, Math.min(255, Math.round(v * f)));
  return `rgb(${c((n >> 16) & 255)},${c((n >> 8) & 255)},${c(n & 255)})`;
}

// a horizontal gradient across [xL, xR] — dark edges, bright centre — the round-tube
// shading that makes a cylinder or cone read as solid (lit from the front, so it's stable
// as the Rider moves rather than depending on a world light direction).
function roundFill(ctx: CanvasRenderingContext2D, xL: number, xR: number, color: string): string | CanvasGradient {
  if (xR - xL < 1) return color;   // too thin to shade
  const g = ctx.createLinearGradient(xL, 0, xR, 0);
  g.addColorStop(0, shade(color, 0.6));
  g.addColorStop(0.5, shade(color, 1.25));
  g.addColorStop(1, shade(color, 0.6));
  return g;
}

// The trunk: a vertical bar. `round` shades it across its width so it reads as a cylinder —
// a cylinder's silhouette is just a rectangle from any side, so only the shading shows round.
function drawTrunk(ctx: CanvasRenderingContext2D, m: TreeMetrics, round: boolean): void {
  const trunkW = Math.max(1, m.ht * 0.08);                 // thin; only the length changes
  const trunkH = m.ht * VISIBLE_TRUNK + m.ht * 0.05;       // up into the crown a touch, no gap
  const x = m.bx - trunkW / 2;
  ctx.fillStyle = round ? roundFill(ctx, x, x + trunkW, TRUNK) : TRUNK;
  ctx.fillRect(x, m.by - trunkH, trunkW, trunkH);
}

// one flat crown tier (the far / cheap form). fillStyle is set by the caller.
function tierTriangle(ctx: CanvasRenderingContext2D, m: TreeMetrics, k: number): void {
  ctx.beginPath();
  ctx.moveTo(m.bx, m.apexY + m.foliage * TIER_TOP[k]);
  ctx.lineTo(m.bx + m.w * TIER_WIDE[k], m.apexY + m.foliage * TIER_BOT[k]);
  ctx.lineTo(m.bx - m.w * TIER_WIDE[k], m.apexY + m.foliage * TIER_BOT[k]);
  ctx.closePath();
  ctx.fill();
}

// A tree (FAR form): a tall thin trunk with an eight-tier conifer crown on top, every tier
// a flat triangle, flat-shaded — cheap, and indistinguishable from the round form at range.
export function drawTree(ctx: CanvasRenderingContext2D, t: TreeView, project: Project): void {
  const m = metrics(t, project);
  drawTrunk(ctx, m, false);
  ctx.fillStyle = t.color;
  for (let k = 0; k < 8; k++) tierTriangle(ctx, m, k);
}

// A tree (NEAR form): fully ROUND. The trunk is a shaded cylinder and every crown tier is a
// real 3D cone — each tier's base is a circle on the trunk axis, so up close the near side of
// the rim is genuinely nearer than the far side (smaller `forward`), and the perspective
// divide in `project` foreshortens it. NO camera pitch needed; the cones simply have real
// depth. Front-lit round shading on top makes the volume read.
export function drawTreeNear(ctx: CanvasRenderingContext2D, t: TreeView, project: Project): void {
  const m = metrics(t, project);
  drawTrunk(ctx, m, true);
  for (let k = 0; k < 8; k++) tierCone(ctx, t, project, m, k);
}

// a cone-base point nearer than this would cross the near plane and project to infinity,
// so we fall back to the flat triangle for that tier.
const MIN_CONE_FORWARD = 0.4;

// Draw crown tier `k` as a cone: a base circle of world radius R on the trunk axis, rising
// to the tier apex. We project the apex plus a ring of base points (EACH at its own depth)
// and fill their convex hull — which is exactly the cone's silhouette, a cone being convex.
function tierCone(ctx: CanvasRenderingContext2D, t: TreeView, project: Project, m: TreeMetrics, k: number): void {
  const H = t.height, r0 = t.at.right, f0 = t.at.forward;
  const R = CROWN_W * TIER_WIDE[k] * H;                                  // base radius (world m)
  if (f0 - R < MIN_CONE_FORWARD) {                                       // too close — bail to flat
    ctx.fillStyle = t.color;
    tierTriangle(ctx, m, k);
    return;
  }
  const hBase = (VISIBLE_TRUNK + CROWN_H * (1 - TIER_BOT[k])) * H;       // base height (world m)
  const hApex = (VISIBLE_TRUNK + CROWN_H * (1 - TIER_TOP[k])) * H;       // apex height (world m)
  const N = 16;
  const pts: Pt[] = [];
  for (let i = 0; i < N; i++) {
    const a = (i / N) * 2 * Math.PI;
    pts.push(project(r0 + R * Math.cos(a), f0 + R * Math.sin(a), hBase));
  }
  pts.push(project(r0, f0, hApex));                                      // apex on the axis
  const hull = convexHull(pts);
  let minX = Infinity, maxX = -Infinity;
  for (const p of hull) { minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x); }
  ctx.fillStyle = roundFill(ctx, minX, maxX, t.color);
  ctx.beginPath();
  ctx.moveTo(hull[0].x, hull[0].y);
  for (let i = 1; i < hull.length; i++) ctx.lineTo(hull[i].x, hull[i].y);
  ctx.closePath();
  ctx.fill();
}

// convex hull (Andrew's monotone chain) of screen points — the cone's filled silhouette.
type Pt = { x: number; y: number };
function convexHull(pts: Pt[]): Pt[] {
  const p = pts.slice().sort((a, b) => a.x - b.x || a.y - b.y);
  if (p.length < 3) return p;
  const cross = (o: Pt, a: Pt, b: Pt): number => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lower: Pt[] = [];
  for (const q of p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], q) <= 0) lower.pop();
    lower.push(q);
  }
  const upper: Pt[] = [];
  for (let i = p.length - 1; i >= 0; i--) {
    const q = p[i];
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], q) <= 0) upper.pop();
    upper.push(q);
  }
  lower.pop(); upper.pop();
  return lower.concat(upper);
}
