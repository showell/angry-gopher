// farm_critter — the roadside farm animals on each segment: a cow herd (a bull leading 10 cows and
// 4 calves) early on the left, and a row of pigs near the end on the right. Placement is fully
// deterministic — a staggered grid with sine/cosine jitter, no randomness.

import type { Critter } from './critter.ts';

const COW_HEIGHT = 1.4;
const CALF_HEIGHT = COW_HEIGHT / 2;
const BULL_HEIGHT = COW_HEIGHT * 1.15;   // a touch bigger than a cow
const PIG_HEIGHT = 1.1;

const HERD_ROAD_OFFSET = 10;       // cows graze this far beyond the lane edge
const BULL_DIST = 24;              // the bull stands here (~the 4th tree); the herd is just behind
const BULL_TREE_GAP = 0.5;         // the bull's rear sits this far back from the tree line
const HERD_GAP_BEHIND_BULL = 6;    // the rest of the herd starts this far behind the bull
const HERD_COL_SPACING = 6;        // along-spacing of the herd scatter
const HERD_ROW_STAGGER = 2;        // along-stagger between herd rows
const HERD_ROW_DEPTH = 5;          // across-spacing (depth) of the herd scatter
const HERD_JITTER_ALONG = 1.5;     // deterministic wobble of the scatter, along
const HERD_JITTER_ACROSS = 1.2;    // deterministic wobble of the scatter, across
const PIG_DIST_BEFORE_END = 60;    // pigs gather this far before the next intersection
const PIG_BACK_ROW_OFFSET = 6;     // the extra back row of pigs sits this much further from the road

// The farm critters lining a segment: the cow herd near the start (left), the pigs near the end
// (right). `treeLineOffset` is how far roadside trees sit beyond the lane edge — the bull lines its
// rear up with that tree line.
export function farmCritters(length: number, laneHalfWidth: number, treeLineOffset: number): Critter[] {
  return [...cowHerd(laneHalfWidth, treeLineOffset), ...pigRow(length, laneHalfWidth + HERD_ROAD_OFFSET)];
}

// 15 cows early in the segment: a BULL at the front (lowest along — seen first as you leave the
// corner), bigger than the rest and facing the opposite way, then 10 full-size cows + 4 half-size
// calves just behind it in a loose staggered grid with deterministic jitter.
function cowHerd(hw: number, treeLineOffset: number): Critter[] {
  const out: Critter[] = [];
  const edge = hw + HERD_ROAD_OFFSET;     // the cows graze well off the road
  const treeX = hw + treeLineOffset;      // the roadside tree line (left side = -treeX)
  out.push({ along: BULL_DIST, across: -(treeX + BULL_HEIGHT / 2 + BULL_TREE_GAP), emoji: '🐂', height: BULL_HEIGHT, faceRight: false });
  for (let i = 0; i < 14; i++) {
    const col = Math.floor(i / 3), row = i % 3;
    const along = BULL_DIST + HERD_GAP_BEHIND_BULL + col * HERD_COL_SPACING + (row - 1) * HERD_ROW_STAGGER + HERD_JITTER_ALONG * Math.sin(i * 2.7);
    const across = -(edge + row * HERD_ROW_DEPTH + HERD_JITTER_ACROSS * Math.cos(i * 1.9));
    const calf = i % 4 === 1;   // i = 1,5,9,13 -> 4 calves at half size
    out.push({ along, across, emoji: '🐄', height: calf ? CALF_HEIGHT : COW_HEIGHT, faceRight: true });
  }
  return out;
}

// 10 pigs near the end of the segment, on the right: a front row of 4 at the road's edge, and a
// back row of 6 sitting further off the road.
function pigRow(length: number, edge: number): Critter[] {
  const out: Critter[] = [];
  const base = length - PIG_DIST_BEFORE_END;
  const pig = (d: number, across: number): void => {
    out.push({ along: base + d, across, emoji: '🐖', height: PIG_HEIGHT, faceRight: false });
  };
  for (const d of [-6, -2, 2, 6]) pig(d, edge);                                 // front row of 4
  for (const d of [-10, -6, -2, 2, 6, 10]) pig(d, edge + PIG_BACK_ROW_OFFSET);  // back row of 6, further out
  return out;
}
