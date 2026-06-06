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

// Wrap a placed tree as Scenery. No up-close detail for now (the needle experiment was
// backed out — it broke the billboard's radial symmetry), so both LOD methods are the
// same draw; the hook stays for when near-detail returns.
export function treeScenery(view: TreeView): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawTree(ctx, view, project);
  return { forward: view.at.forward, drawAsNear: draw, drawAsFar: draw };
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

// the eight stacked tiers, as fractions of the CROWN span: each tier's apex (TOP) and
// base (BOT) heights, and its base half-width (WIDE). Narrow at the apex, widest at the
// bottom — the conifer silhouette.
const TIER_TOP = [0.0, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70];
const TIER_BOT = [0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.0];
const TIER_WIDE = [0.35, 0.44, 0.53, 0.63, 0.72, 0.81, 0.91, 1.0];

const VISIBLE_TRUNK = 0.44;   // visible bare trunk, as a fraction of tree height
const CROWN_H = 0.648;        // crown height, as a fraction of tree height
const CROWN_W = 0.288;        // crown base half-width, as a fraction of tree height

// A tree: a tall, thin trunk rising most of the way up, with an eight-tier conifer crown
// perched ON TOP of it (lowest tier resting on the trunk, apex near the very top). The
// crown doesn't drape to the ground, so the trunk reads tall — the setup for driving
// under a tall tree and looking up into the crown. Trunk length and crown size are
// decoupled so they tune independently. Radially symmetric on purpose: the billboard
// reads the same from any angle. The caller pre-filters by depth.
export function drawTree(ctx: CanvasRenderingContext2D, t: TreeView, project: Project): void {
  const base = project(t.at.right, t.at.forward, 0);
  const top = project(t.at.right, t.at.forward, t.height);
  const ht = base.y - top.y;

  const trunkW = Math.max(1, ht * 0.08);                  // thin; only the length changes
  const trunkH = ht * VISIBLE_TRUNK + ht * 0.05;          // up into the crown a touch, no gap
  ctx.fillStyle = TRUNK;
  ctx.fillRect(base.x - trunkW / 2, base.y - trunkH, trunkW, trunkH);

  const crownBottomY = base.y - ht * VISIBLE_TRUNK;       // crown rests here and grows UP
  const foliage = ht * CROWN_H, apexY = crownBottomY - foliage, w = ht * CROWN_W;
  ctx.fillStyle = t.color;
  for (let k = 0; k < 8; k++) {
    ctx.beginPath();
    ctx.moveTo(base.x, apexY + foliage * TIER_TOP[k]);
    ctx.lineTo(base.x + w * TIER_WIDE[k], apexY + foliage * TIER_BOT[k]);
    ctx.lineTo(base.x - w * TIER_WIDE[k], apexY + foliage * TIER_BOT[k]);
    ctx.closePath();
    ctx.fill();
  }
}
