// farm_critter — the roadside farm animals on a segment: a cow herd (a bull leading 10 cows and
// 4 calves) early on the left — the BORING CONSTANT, on every segment — and, only when the segment
// asks for them, a row of pigs near the end on the right (a rare variety element, off by default).
// Placement is fully deterministic — a staggered grid with sine/cosine jitter, no randomness.

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
const GAZE_PIG_ALONG_OFFSET = 2;   // the one pig the distracted rider fixes on: a front-row pig just past the cluster centre

// The big DISTRACTION herd (the first couple of pig appearances — the legs flagged pigsDistract in world.ts):
// a deep staggered block of pigs, BIG_HERD_COLS along the road x BIG_HERD_ROWS deep, each nudged by a
// deterministic stagger + jitter so it reads as a milling herd rather than a rigid lattice.
const BIG_HERD_COLS = 7;           // pigs along the road; the extra columns extend toward the intersection
const BIG_HERD_ROWS = 7;           // rows of pigs; the extra rows extend the herd away from the road
const PIG_COL_SPACING = 4;         // along-spacing within a row
const PIG_ROW_DEPTH = 6;           // across-spacing between rows (deeper into the field)
const PIG_ROW_STAGGER = 1.5;       // alternate rows nudged along, so columns don't line up rigidly
const PIG_JITTER_ALONG = 1.2;      // deterministic per-pig wobble, along
const PIG_JITTER_ACROSS = 1.0;     // deterministic per-pig wobble, across
const PIG_HERD_FIRST_COL = -6;     // along-offset of each row's near (cluster-front) pig; columns run from here toward the intersection

// The farm critters lining a segment: the cow herd near the start (left), always; and the pigs near the
// end (right) only when `pigs` is set. On a DISTRACTION leg (`bigHerd`, the first couple of pig appearances)
// the pigs are a big staggered block; on the other pig legs they're the small two-row cluster. `treeLineOffset`
// is how far roadside trees sit beyond the lane edge — the bull lines its rear up with that tree line.
export function farmCritters(length: number, laneHalfWidth: number, treeLineOffset: number, pigs: boolean, bigHerd: boolean): Critter[] {
  const herd = cowHerd(laneHalfWidth, treeLineOffset);
  if (!pigs) return herd;
  const edge = laneHalfWidth + HERD_ROAD_OFFSET;
  return [...herd, ...(bigHerd ? pigHerd(length, edge) : pigRow(length, edge))];
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

// The ONE pig the distracted rider fixes his gaze on (rider_gaze.ts) — a real front-row pig (the d=+2 one
// below), so the head-turn always aims at something actually rendered. `laneHalfWidth` matches farmCritters.
export function gazePig(length: number, laneHalfWidth: number): { along: number; across: number } {
  return { along: length - PIG_DIST_BEFORE_END + GAZE_PIG_ALONG_OFFSET, across: laneHalfWidth + HERD_ROAD_OFFSET };
}

// 10 pigs near the end of the segment, on the right: a front row of 4 at the road's edge, and a
// back row of 6 sitting further off the road. The small herd, for the non-distraction pig legs.
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

// The big distraction herd: a BIG_HERD_COLS x BIG_HERD_ROWS block extending toward the intersection (cols)
// and away from the road (rows), staggered + jittered so it mills like a real herd. The gaze still aims at
// the fixed gazePig point near the front, which sits inside this block.
function pigHerd(length: number, edge: number): Critter[] {
  const out: Critter[] = [];
  const base = length - PIG_DIST_BEFORE_END;
  for (let r = 0; r < BIG_HERD_ROWS; r++) {
    for (let c = 0; c < BIG_HERD_COLS; c++) {
      const i = r * BIG_HERD_COLS + c;
      const along = base + PIG_HERD_FIRST_COL + c * PIG_COL_SPACING + (r % 2) * PIG_ROW_STAGGER + PIG_JITTER_ALONG * Math.sin(i * 2.3);
      const across = edge + r * PIG_ROW_DEPTH + PIG_JITTER_ACROSS * Math.cos(i * 1.7);
      out.push({ along, across, emoji: '🐖', height: PIG_HEIGHT, faceRight: false });
    }
  }
  return out;
}
