// =============================================================================
// tree — the roadside trees. This module owns where they stand on a segment
// (with a clear zone near intersections), their colour/species by scheme, and how
// they're drawn. Two kinds: a tiered conifer (green or golden) and a leafy tree
// (brown branches tipped with small red leaves). The rest of the app just asks a
// segment for its trees and throws the drawn shapes on the canvas.
// =============================================================================
import type { Project } from './critter.ts';

// A segment's tree theme. ALL_GREEN: green conifers. YELLOW_GREEN: green + golden
// conifers. RED_GREEN: green conifers alternating with red leafy trees.
export type Scheme = 'ALL_GREEN' | 'YELLOW_GREEN' | 'RED_GREEN';

// How a tree is drawn: a tiered conifer, or a leafy (branches + leaves) tree.
export type TreeKind = 'conifer' | 'leafy';

// A tree in its SEGMENT's frame: `along` the segment, `across` from the centre.
export interface Tree { along: number; across: number; color: string; height: number; kind: TreeKind }

// A tree placed in the scene, measured FROM THE RIDER and ready to draw.
export interface TreeView { at: { right: number; forward: number }; color: string; height: number; kind: TreeKind }

// ---- dimensions (metres) ----
const TREE_HEIGHT = 5;                    // leafy trees; conifers render shorter
const CONIFER_HEIGHT = TREE_HEIGHT / 2;   // conifers are squat next to the leafy trees
const DIST_BETWEEN_TREES = 6;             // tree spacing along a segment
export const TREE_ROAD_OFFSET = 1.5;      // a tree stands this far beyond the lane edge (the bull lines up with it)
const TREE_INTERSECTION_CLEARANCE = 6;    // no trees within this of an intersection

const CONIFER_GREEN = '#1c5a22';   // dark green conifer
const CONIFER_GOLD = '#cf9a18';    // golden (autumn) conifer
const LEAF_RED = '#b23a2a';        // leaves on the red leafy trees
const TRUNK = '#5a3e22';           // trunk + branches

// ---- where the trees are ----

// Both rows of trees along a segment. `entryTan`/`exitTan` are how far the turns
// at each end intrude into the straight; we keep that PLUS a clearance clear, so
// no tree lands on the adjoining road or right at a segment's start/end.
export function segmentTrees(length: number, entryTan: number, exitTan: number,
                             scheme: Scheme, laneHalfWidth: number): Tree[] {
  const trees: Tree[] = [];
  const startAlong = entryTan + TREE_INTERSECTION_CLEARANCE;
  const endAlong = length - exitTan - TREE_INTERSECTION_CLEARANCE;
  const x = laneHalfWidth + TREE_ROAD_OFFSET;   // the tree line, each side of the road
  let k = 0;
  for (let along = startAlong; along <= endAlong; along += DIST_BETWEEN_TREES, k++) {
    const { color, kind } = treeStyle(scheme, k);   // alternates along the segment
    const height = kind === 'conifer' ? CONIFER_HEIGHT : TREE_HEIGHT;
    trees.push({ along, across: -x, color, height, kind });
    trees.push({ along, across: x, color, height, kind });
  }
  return trees;
}

// Every other tree is a green conifer; the alternate is the scheme's accent — a
// golden conifer, a red leafy tree, or (for ALL_GREEN) just another green conifer.
function treeStyle(scheme: Scheme, k: number): { color: string; kind: TreeKind } {
  if (scheme === 'ALL_GREEN' || k % 2 === 0) return { color: CONIFER_GREEN, kind: 'conifer' };
  if (scheme === 'YELLOW_GREEN') return { color: CONIFER_GOLD, kind: 'conifer' };
  return { color: LEAF_RED, kind: 'leafy' };
}

// ---- drawing ----

// A tree: a trunk, then either a tiered conifer or a leafy crown. The caller
// pre-filters by depth.
export function drawTree(ctx: CanvasRenderingContext2D, t: TreeView, project: Project): void {
  const base = project(t.at.right, t.at.forward, 0);
  const top = project(t.at.right, t.at.forward, t.height);
  const ht = base.y - top.y;
  const trunkW = Math.max(1, ht * 0.10);
  ctx.fillStyle = TRUNK;
  ctx.fillRect(base.x - trunkW / 2, base.y - ht * 0.42, trunkW, ht * 0.42);

  if (t.kind === 'conifer') drawConifer(ctx, base.x, base.y, ht, t.color);
  else drawLeafy(ctx, base.x, base.y, ht, t.color);
}

// three stacked tiers, narrow and widest at the bottom — a jagged conifer
function drawConifer(ctx: CanvasRenderingContext2D, cx: number, baseY: number, ht: number, color: string): void {
  const apexY = baseY - ht, foliage = ht * 0.90, w = ht * 0.20;
  const tops = [0.0, 0.28, 0.56], bots = [0.46, 0.74, 1.0], wide = [0.5, 0.78, 1.0];
  ctx.fillStyle = color;
  for (let k = 0; k < 3; k++) {
    ctx.beginPath();
    ctx.moveTo(cx, apexY + foliage * tops[k]);
    ctx.lineTo(cx + w * wide[k], apexY + foliage * bots[k]);
    ctx.lineTo(cx - w * wide[k], apexY + foliage * bots[k]);
    ctx.closePath();
    ctx.fill();
  }
}

// a leafy tree: a few brown branches splaying up from the top of the trunk, each
// tipped with a couple of small pointed leaves.
function drawLeafy(ctx: CanvasRenderingContext2D, cx: number, baseY: number, ht: number, leafColor: string): void {
  const oy = baseY - ht * 0.40;                  // crown origin: top of the trunk
  const blen = ht * 0.50;                         // branch length
  const angles = [-0.95, -0.48, 0, 0.48, 0.95];  // branch splay from vertical (rad)
  ctx.strokeStyle = TRUNK;
  ctx.lineCap = 'round';
  ctx.lineWidth = Math.max(1, ht * 0.045);
  for (const a of angles) {
    ctx.beginPath();
    ctx.moveTo(cx, oy);
    ctx.lineTo(cx + Math.sin(a) * blen, oy - Math.cos(a) * blen);
    ctx.stroke();
  }
  ctx.fillStyle = leafColor;
  const llen = ht * 0.17, lwid = ht * 0.06;
  for (const a of angles) {
    for (const f of [0.7, 1.0]) leaf(ctx, cx + Math.sin(a) * blen * f, oy - Math.cos(a) * blen * f, llen, lwid, a);
  }
}

// one small pointed leaf: base at (x,y), tip `len` out along angle `a` (from
// vertical), bulging `wid` to each side — two quadratic curves meeting at a point.
function leaf(ctx: CanvasRenderingContext2D, x: number, y: number, len: number, wid: number, a: number): void {
  const dx = Math.sin(a), dy = -Math.cos(a);     // along-leaf direction (up & out)
  const px = -dy, py = dx;                         // perpendicular
  const tx = x + dx * len, ty = y + dy * len;      // tip
  const mx = x + dx * len * 0.5, my = y + dy * len * 0.5;
  ctx.beginPath();
  ctx.moveTo(x, y);
  ctx.quadraticCurveTo(mx + px * wid, my + py * wid, tx, ty);
  ctx.quadraticCurveTo(mx - px * wid, my - py * wid, x, y);
  ctx.fill();
}
