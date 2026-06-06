// =============================================================================
// road_segment — the ROAD NETWORK: the RoadSegment type, the relational chain of
// segments (World), the builder that authors the route, and the pure per-segment
// queries (turn sign, safe turn speed). No Rider, no canvas — this is the road the
// Rider moves OVER, so it never references RiderState; model.ts (the Rider's
// motion) and view.ts (the scene) build on these types, not the other way round.
//
// Intersections are still IMPLICIT — an exit on one segment plus the entry it
// feeds the next. They have no type of their own yet; giving them first-class
// treatment is the next step toward a true node/edge graph.
// =============================================================================

import { segmentCritters, intersectionCritters } from './critter.ts';
import type { Critter } from './critter.ts';
import { segmentTrees, TREE_ROAD_OFFSET } from './tree.ts';
import type { Scheme, Tree } from './tree.ts';

// ---- road dimensions (metres) ----
const LANE_WIDTH = 4;       // a single lane
const TURN_RADIUS = 2;      // sets the tree clear-zone tangent at each corner (R*tan(THETA/2))

// ----------------------------------------------------------------------------
// World — a relational chain of segments. Scalars only; never coordinates.
// ----------------------------------------------------------------------------
export type SegId = string;
export type TurnDir = 'left' | 'right';

export interface RoadSegment {
  id: SegId;
  length: number;
  width: number;
  scheme: Scheme;                // visual theme; drives the tree colours
  trees: Tree[];
  critters: Critter[];      // roadside, along the segment (cows/pigs)
  exitCritters: Critter[];  // at the exit intersection (elephants); shared with the next segment
  exit: { dir: TurnDir; to: SegId; radius: number; angle: number } | null;
  // derived relational scalars (filled by buildWorld)
  exitSign: number;     // +1 right, -1 left, 0 none
  exitAngle: number;    // turn angle THETA (0 if none)
  exitTan: number;      // R * tan(THETA/2): the clear zone trees keep near the exit corner
  entryTan: number;     // the clear zone trees keep near the entry corner
  straightenStart: number;   // length - hw/tan(THETA): where the Rider crosses the next segment's inner edge
  entryAngle: number;        // the turn angle that FEEDS this segment (0 if none) — its entry runs negative-along
  northHeading: number;      // heading relative to north (seg1 = 0), radians — the one absolute orientation we keep
}

export interface World {
  segments: Record<SegId, RoadSegment>;
  start: SegId;
  order: SegId[];
}

const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);
const segNumber = (id: SegId): number => Number(id.slice(3));   // "seg12" -> 12

export function buildWorld(): World {
  const DEG = Math.PI / 180;

  const seg = (id: SegId, length: number, scheme: Scheme,
               exit: RoadSegment['exit']): RoadSegment => {
    const tan = exit ? exit.radius * Math.tan(exit.angle / 2) : 0;
    return {
      id, length, width: LANE_WIDTH, scheme,
      trees: [],   // filled below, once entry/exit tangents are known
      critters: segmentCritters(length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
      exitCritters: exit ? intersectionCritters(length, signOf(exit.dir), segNumber(id), LANE_WIDTH / 2) : [],
      exit,
      exitSign: exit ? signOf(exit.dir) : 0,
      exitAngle: exit ? exit.angle : 0,
      exitTan: tan,
      entryTan: 0,
      straightenStart: exit ? length - (LANE_WIDTH / 2) / Math.tan(exit.angle) : length,
      entryAngle: 0,
      northHeading: 0,
    };
  };
  const turn = (to: SegId, dir: TurnDir, deg: number): RoadSegment['exit'] =>
    ({ dir, to, radius: TURN_RADIUS, angle: deg * DEG });

  // route is checked non-self-intersecting (no loops) and all-turns-<=-90deg by
  // test/test_model.ts. Hand-authored, opening with a soft S of gentle warm-up turns;
  // every turn is a straighten-out; the last segment has no exit (the final straight).
  const segments: Record<SegId, RoadSegment> = {
    seg1:  seg('seg1', 300, 'ALL_GREEN',     turn('seg2',  'left',   30)),
    seg2:  seg('seg2', 240, 'YELLOW_GREEN',  turn('seg3',  'right',  30)),
    seg3:  seg('seg3', 800, 'RED_GREEN',     turn('seg4',  'right',  50)),
    seg4:  seg('seg4', 320, 'ALL_GREEN',     turn('seg5',  'left',   70)),
    seg5:  seg('seg5', 400, 'YELLOW_GREEN',  turn('seg6',  'right',  20)),
    seg6:  seg('seg6', 200, 'RED_GREEN',     turn('seg7',  'right',  20)),
    seg7:  seg('seg7', 220, 'ALL_GREEN',     turn('seg8',  'left',   70)),
    seg8:  seg('seg8', 240, 'YELLOW_GREEN',  turn('seg9',  'left',   70)),
    seg9:  seg('seg9', 200, 'RED_GREEN',     turn('seg10', 'right',  80)),
    seg10: seg('seg10', 220, 'ALL_GREEN',    turn('seg11', 'right',  20)),
    seg11: seg('seg11', 200, 'YELLOW_GREEN', turn('seg12', 'left',   70)),
    seg12: seg('seg12', 200, 'RED_GREEN',    turn('seg13', 'right',  15)),
    seg13: seg('seg13', 200, 'ALL_GREEN',    turn('seg14', 'right',  15)),
    seg14: seg('seg14', 200, 'YELLOW_GREEN', turn('seg15', 'right',  15)),
    seg15: seg('seg15', 200, 'RED_GREEN',    turn('seg16', 'right',  15)),
    seg16: seg('seg16', 400, 'ALL_GREEN',    null),
  };
  const order: SegId[] = [
    'seg1', 'seg2', 'seg3', 'seg4', 'seg5', 'seg6', 'seg7', 'seg8', 'seg9', 'seg10',
    'seg11', 'seg12', 'seg13', 'seg14', 'seg15', 'seg16',
  ];
  for (const id of order) {
    const s = segments[id];
    if (s.exit) {
      const next = segments[s.exit.to];
      next.entryTan = s.exitTan;
      next.entryAngle = s.exitAngle;
      next.northHeading = s.northHeading + s.exitSign * s.exitAngle;   // accumulate orientation along the route
    }
  }
  // Trees, now that each end's tangent is known (tree.ts keeps a clear zone
  // around each intersection so none land on the adjoining road).
  for (const id of order) {
    const s = segments[id];
    s.trees = segmentTrees(s.length, s.entryTan, s.exitTan, s.scheme, LANE_WIDTH / 2);
  }
  return { segments, start: 'seg1', order };
}
