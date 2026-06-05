// =============================================================================
// tree — the roadside trees: where they stand on a segment (with a clear zone
// near intersections), their colour by scheme, their size by position parity, and
// how they're drawn (a tiered conifer). The rest of the app just asks a segment
// for its trees and throws the drawn shapes on the canvas.
// =============================================================================
import type { Project } from './critter.ts';

// A segment's tree theme. ALL_GREEN: all green. YELLOW_GREEN / RED_GREEN: green
// alternating with a golden / red accent. Every tree is a conifer either way.
export type Scheme = 'ALL_GREEN' | 'YELLOW_GREEN' | 'RED_GREEN';

// A tree in its SEGMENT's frame: `along` the segment, `across` from the centre.
export interface Tree { along: number; across: number; color: string; height: number }

// A tree placed in the scene, measured FROM THE RIDER and ready to draw.
export interface TreeView { at: { right: number; forward: number }; color: string; height: number }

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
  const x = laneHalfWidth + TREE_ROAD_OFFSET;   // the tree line, each side of the road
  let k = 0;
  for (let along = startAlong; along <= endAlong; along += DIST_BETWEEN_TREES, k++) {
    const even = k % 2 === 0;
    const color = even ? CONIFER_GREEN : accentColor(scheme);
    const height = even ? SMALL_HEIGHT * BIG_SCALE : SMALL_HEIGHT;
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

// A tree: a trunk, then a tiered conifer crown (three stacked tiers, narrow at the
// apex and widest at the bottom — jagged). The caller pre-filters by depth.
export function drawTree(ctx: CanvasRenderingContext2D, t: TreeView, project: Project): void {
  const base = project(t.at.right, t.at.forward, 0);
  const top = project(t.at.right, t.at.forward, t.height);
  const ht = base.y - top.y;
  const trunkW = Math.max(1, ht * 0.10);
  ctx.fillStyle = TRUNK;
  ctx.fillRect(base.x - trunkW / 2, base.y - ht * 0.42, trunkW, ht * 0.42);

  const apexY = base.y - ht, foliage = ht * 0.90, w = ht * 0.20;
  const tops = [0.0, 0.28, 0.56], bots = [0.46, 0.74, 1.0], wide = [0.5, 0.78, 1.0];
  ctx.fillStyle = t.color;
  for (let k = 0; k < 3; k++) {
    ctx.beginPath();
    ctx.moveTo(base.x, apexY + foliage * tops[k]);
    ctx.lineTo(base.x + w * wide[k], apexY + foliage * bots[k]);
    ctx.lineTo(base.x - w * wide[k], apexY + foliage * bots[k]);
    ctx.closePath();
    ctx.fill();
  }
}
