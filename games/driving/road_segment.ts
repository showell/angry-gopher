// =============================================================================
// road_segment — the RoadSegment type: the straight EDGE of the road graph, and
// buildRoadSegment, which builds one from its config. A segment is the straight
// part between two intersections; it carries reverse graph refs (entryIxn/exitIxn)
// into intersection.ts, where the turns live. world.ts authors the route from these
// and the intersections; model.ts/view.ts build on the type. No Rider, no canvas.
//
// The one turn-derived scalar that lives HERE is a position ALONG the segment
// (alongWhereRiderCommitsToTurn) — the segment owns its own length; world.ts fills
// it once the bracketing intersections exist.
// =============================================================================

import { farmCritters } from './farm_critter.ts';
import type { Critter } from './critter.ts';
import { segmentCats } from './cat_motion.ts';
import type { Cat } from './cat_motion.ts';
import { segmentTrees, TREE_ROAD_OFFSET } from './tree.ts';
import type { Scheme, Tree } from './tree.ts';
import { beaconOffsetFor } from './tower.ts';
import type { IxnId } from './intersection.ts';

export type SegId = string;
export type TurnDir = 'left' | 'right';

// ---- road dimensions (metres) ----
const LANE_WIDTH = 4;       // a single lane

// A long, straight stretch is dull, so a road segment longer than this stands its OWN tower
// halfway down (owned by the segment, not an intersection — see view.ts for the placement).
const MID_TOWER_MIN_LENGTH = 1000;

export interface RoadSegment {
  id: SegId;
  length: number;
  width: number;
  scheme: Scheme;                // visual theme; drives the tree colours
  trees: Tree[];
  critters: Critter[];      // roadside emoji billboards along the segment (cows/pigs); elephants live on the exit Intersection
  cats: Cat[];              // hand-drawn cats that cross the road as the rider nears, opposite the bull
  // graph refs: the intersections bracketing this edge. Every segment EXITS through an
  // intersection (a turn, or the terminus that closes the route), so exitIxn is never null;
  // entryIxn is null only at the route START, where the Rider just spawns (no node there).
  entryIxn: IxnId | null;   // the intersection the Rider ARRIVES FROM (null at the route start)
  exitIxn: IxnId;           // the intersection the Rider DEPARTS THROUGH (a turn, or the terminus)
  // The `along` position at which the Rider leaves this segment for its exit turn: he
  // crosses the extension of the next segment's inner edge here, hw/tan(THETA) BEFORE the
  // segment's geometric end, and commits to the turn. At the terminus it's just the segment
  // end. (Lives on the segment because it's an along-coordinate; the TURN lives on the
  // intersection.)
  alongWhereRiderCommitsToTurn: number;
  northHeading: number;     // heading relative to north (seg1 = 0), radians — the one absolute orientation we keep
  midTower: { beaconOffset: number } | null;   // a tower the segment OWNS, halfway down (long segments only); null otherwise
}

// The AUTHORED spec for a segment: its id, length, and tree scheme. Everything else a
// RoadSegment carries is either intrinsic (built here) or depends on the bracketing
// intersections (wired by world.ts once those exist).
export interface RoadSegmentConfig {
  id: SegId;
  length: number;
  scheme: Scheme;
}

// Build a segment's INTRINSIC state from its config: dimensions, roadside trees, and the
// along-the-road critters — all a function of length/scheme alone. The intersection-derived
// bits start empty/neutral: the graph refs, the turn-commit point (defaults to the segment
// end, a terminus), and the north heading (accumulated along the route). world.ts fills
// those, and the elephants live on the exit Intersection, not here.
export function buildRoadSegment(c: RoadSegmentConfig): RoadSegment {
  const trees = segmentTrees(c.length, c.scheme, LANE_WIDTH / 2);
  return {
    id: c.id,
    length: c.length,
    width: LANE_WIDTH,
    scheme: c.scheme,
    trees,
    critters: farmCritters(c.length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
    cats: segmentCats(LANE_WIDTH / 2, TREE_ROAD_OFFSET, trees),   // the cat rounds its along to a tree
    entryIxn: null,
    exitIxn: '',   // a placeholder: set to the real id when this segment's exit intersection is built
    alongWhereRiderCommitsToTurn: c.length,
    northHeading: 0,
    // long segments earn a mid-road tower; its blink phase is seeded off a shifted segment number
    // so it doesn't pulse in unison with the segment's exit-intersection tower.
    midTower: c.length > MID_TOWER_MIN_LENGTH ? { beaconOffset: beaconOffsetFor(Number(c.id.slice(3)) + 60) } : null,
  };
}
