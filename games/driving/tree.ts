// =============================================================================
// tree — the roadside trees. This module owns where they stand on a segment
// (with a clear zone near intersections), their autumn-vs-conifer colours, and
// how they're drawn (a round disc or a jagged pine). The rest of the app just
// asks a segment for its trees and throws the drawn shapes on the canvas.
// =============================================================================
import type { Project } from './critter.ts';

// A segment's tree theme: which trees are green (pine) vs an autumn accent.
export type Scheme = 'ALL_GREEN' | 'YELLOW_GREEN' | 'RED_GREEN';

// A tree in its SEGMENT's frame: `along` the segment, `across` from the centre.
export interface Tree { along: number; across: number; color: string; height: number; pine: boolean }

// A tree placed in the scene, measured FROM THE RIDER and ready to draw.
export interface TreeView { at: { right: number; forward: number }; color: string; height: number; pine: boolean }

// ---- dimensions (metres) ----
const TREE_HEIGHT = 5;                   // round (autumn) trees; pines render at half height
const DIST_BETWEEN_TREES = 6;            // tree spacing along a segment
export const TREE_ROAD_OFFSET = 1.5;     // a tree stands this far beyond the lane edge (the bull lines up with it)
const TREE_INTERSECTION_CLEARANCE = 6;   // no trees within this of an intersection

const GREEN = '#2f7a30', YELLOW = '#cf9a18', RED = '#b23a2a';
const PINE = '#1c5a22';     // darker than the round green
const TRUNK = '#5a3e22';

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
    const color = treeColor(scheme, k);   // alternates along the segment
    const pine = color === GREEN;         // green trees are conifers; accent trees are round
    const height = pine ? TREE_HEIGHT / 2 : TREE_HEIGHT;
    trees.push({ along, across: -x, color, height, pine });
    trees.push({ along, across: x, color, height, pine });
  }
  return trees;
}

function treeColor(scheme: Scheme, k: number): string {
  if (scheme === 'ALL_GREEN') return GREEN;
  const accent = scheme === 'YELLOW_GREEN' ? YELLOW : RED;
  return k % 2 === 0 ? GREEN : accent;
}

// ---- drawing ----

// A tree: a trunk, then either a thin jagged conifer (pines, darker green) or a
// round coloured disc (autumn trees). The caller pre-filters by depth.
export function drawTree(ctx: CanvasRenderingContext2D, t: TreeView, project: Project): void {
  const base = project(t.at.right, t.at.forward, 0);
  const top = project(t.at.right, t.at.forward, t.height);
  const ht = base.y - top.y;
  const trunkW = Math.max(1, ht * 0.10);
  ctx.fillStyle = TRUNK;
  ctx.fillRect(base.x - trunkW / 2, base.y - ht * 0.42, trunkW, ht * 0.42);

  if (t.pine) {
    // three stacked tiers, narrow and widest at the bottom — a jagged conifer
    const apexY = base.y - ht, foliage = ht * 0.90, w = ht * 0.20;
    const tops = [0.0, 0.28, 0.56], bots = [0.46, 0.74, 1.0], wide = [0.5, 0.78, 1.0];
    ctx.fillStyle = PINE;
    for (let k = 0; k < 3; k++) {
      ctx.beginPath();
      ctx.moveTo(base.x, apexY + foliage * tops[k]);
      ctx.lineTo(base.x + w * wide[k], apexY + foliage * bots[k]);
      ctx.lineTo(base.x - w * wide[k], apexY + foliage * bots[k]);
      ctx.closePath();
      ctx.fill();
    }
    return;
  }

  ctx.fillStyle = t.color;
  ctx.beginPath();
  ctx.arc(base.x, base.y - ht * 0.62, ht * 0.30, 0, Math.PI * 2);
  ctx.fill();
}
