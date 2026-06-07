// =============================================================================
// road_segment — the ROAD NETWORK: the RoadSegment type (the EDGES of the graph),
// the World that holds the segments + intersections, and buildWorld, which authors
// the route. No Rider, no canvas — this is the road the Rider moves OVER, so it
// never references RiderState; model.ts (the Rider's motion) and view.ts (the
// scene) build on these types, not the other way round.
//
// A segment is the straight part between two intersections. It carries the reverse
// graph refs (entryIxn / exitIxn) into intersection.ts, where the turns actually
// live. The one turn-derived scalar that stays HERE is a position ALONG the segment
// (alongWhereRiderCommitsToTurn) — the segment owns its own length.
// =============================================================================

import { segmentCritters, intersectionCritters } from './critter.ts';
import type { Critter } from './critter.ts';
import { segmentTrees, TREE_ROAD_OFFSET } from './tree.ts';
import type { Scheme, Tree } from './tree.ts';
import type { Intersection, IxnId } from './intersection.ts';

// ---- road dimensions (metres) ----
const LANE_WIDTH = 4;       // a single lane
const TURN_RADIUS = 2;      // sets the tree clear-zone tangent at each corner (R*tan(THETA/2))

// ----------------------------------------------------------------------------
// World — a graph: segments (edges) joined by intersections (nodes). Scalars and
// id refs only; never coordinates.
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
}

export interface World {
  segments: Record<SegId, RoadSegment>;
  intersections: Record<IxnId, Intersection>;
  start: SegId;
  order: SegId[];
}

const signOf = (d: TurnDir): number => (d === 'right' ? 1 : -1);
const segNumber = (id: SegId): number => Number(id.slice(3));   // "seg12" -> 12

export function buildWorld(): World {
  const DEG = Math.PI / 180;

  // ---- author the route ----
  // Each row: a segment's length + scheme, and the exit turn it takes (to / dir / degrees)
  // or null at the end. Checked non-self-intersecting (no loops) and all-turns-<=-90deg by
  // test/test_model.ts. Hand-authored, opening with a soft S of gentle warm-up turns.
  const turn = (to: SegId, dir: TurnDir, deg: number) => ({ to, dir, angle: deg * DEG });
  type Row = { id: SegId; length: number; scheme: Scheme; exit: { to: SegId; dir: TurnDir; angle: number } | null };
  const route: Row[] = [
    { id: 'seg1',  length: 300, scheme: 'ALL_GREEN',    exit: turn('seg2',  'left',  30) },
    { id: 'seg2',  length: 240, scheme: 'YELLOW_GREEN', exit: turn('seg3',  'right', 30) },
    { id: 'seg3',  length: 800, scheme: 'RED_GREEN',    exit: turn('seg4',  'right', 50) },
    { id: 'seg4',  length: 320, scheme: 'ALL_GREEN',    exit: turn('seg5',  'left',  70) },
    { id: 'seg5',  length: 400, scheme: 'YELLOW_GREEN', exit: turn('seg6',  'right', 20) },
    { id: 'seg6',  length: 200, scheme: 'RED_GREEN',    exit: turn('seg7',  'right', 20) },
    { id: 'seg7',  length: 220, scheme: 'ALL_GREEN',    exit: turn('seg8',  'left',  70) },
    { id: 'seg8',  length: 240, scheme: 'YELLOW_GREEN', exit: turn('seg9',  'left',  70) },
    { id: 'seg9',  length: 200, scheme: 'RED_GREEN',    exit: turn('seg10', 'right', 80) },
    { id: 'seg10', length: 220, scheme: 'ALL_GREEN',    exit: turn('seg11', 'right', 20) },
    { id: 'seg11', length: 200, scheme: 'YELLOW_GREEN', exit: turn('seg12', 'left',  70) },
    { id: 'seg12', length: 200, scheme: 'RED_GREEN',    exit: turn('seg13', 'right', 15) },
    { id: 'seg13', length: 200, scheme: 'ALL_GREEN',    exit: turn('seg14', 'right', 15) },
    { id: 'seg14', length: 200, scheme: 'YELLOW_GREEN', exit: turn('seg15', 'right', 15) },
    { id: 'seg15', length: 200, scheme: 'RED_GREEN',    exit: turn('seg16', 'right', 15) },
    { id: 'seg16', length: 400, scheme: 'ALL_GREEN',    exit: null },
  ];
  const order: SegId[] = route.map((r) => r.id);

  // ---- intersections: a turn NODE per exit, plus the TERMINUS node that closes the route.
  // Every segment exits through exactly one of these, so we record each segment's exit (and,
  // for turns, the entry it feeds) up front. ----
  const intersections: Record<IxnId, Intersection> = {};
  const exitIxnOf: Record<SegId, IxnId> = {};
  const entryIxnOf: Record<SegId, IxnId> = {};
  for (const r of route) {
    if (r.exit) {
      const theta = r.exit.angle, sign = signOf(r.exit.dir);
      const id: IxnId = `${r.id}_${r.exit.to}`;
      intersections[id] = {
        id, from: r.id, to: r.exit.to, angle: theta,
        radius: TURN_RADIUS, sign, tan: TURN_RADIUS * Math.tan(theta / 2),
      };
      exitIxnOf[r.id] = id;
      entryIxnOf[r.exit.to] = id;
    } else {
      const id: IxnId = `${r.id}_end`;   // the terminus: the Rider arrives and stops (no fork)
      intersections[id] = { id, from: r.id, to: null, angle: 0, radius: 0, sign: 0, tan: 0 };
      exitIxnOf[r.id] = id;
    }
  }

  // ---- segments ----
  const segments: Record<SegId, RoadSegment> = {};
  for (const r of route) {
    const exit = intersections[exitIxnOf[r.id]];
    const isTurn = exit.to !== null;
    segments[r.id] = {
      id: r.id, length: r.length, width: LANE_WIDTH, scheme: r.scheme,
      trees: [],                // filled once each corner's clear-zone tangent is known
      critters: segmentCritters(r.length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
      exitCritters: isTurn ? intersectionCritters(r.length, exit.sign, segNumber(r.id), LANE_WIDTH / 2) : [],
      entryIxn: entryIxnOf[r.id] ?? null,
      exitIxn: exitIxnOf[r.id],
      // the inner-edge crossing, hw/tan(THETA) before the end (a terminus has no turn -> the end)
      alongWhereRiderCommitsToTurn: isTurn ? r.length - (LANE_WIDTH / 2) / Math.tan(exit.angle) : r.length,
      northHeading: 0,
    };
  }

  // ---- orientation relative to north, accumulated along the route ----
  for (const id of order) {
    const ixn = intersections[segments[id].exitIxn];
    if (ixn.to === null) continue;   // terminus: nothing downstream
    segments[ixn.to].northHeading = segments[id].northHeading + ixn.sign * ixn.angle;
  }

  // ---- trees: a function of each segment's length alone (a fixed clearing before the
  // upcoming intersection keeps them off the corner; turn angle no longer matters) ----
  for (const id of order) {
    const s = segments[id];
    s.trees = segmentTrees(s.length, s.scheme, LANE_WIDTH / 2);
  }

  return { segments, intersections, start: 'seg1', order };
}
