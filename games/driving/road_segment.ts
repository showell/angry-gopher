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
import { buildIntersection, buildTerminus } from './intersection.ts';
import type { Intersection, IxnId, IntersectionConfig } from './intersection.ts';

// ---- road dimensions (metres) ----
const LANE_WIDTH = 4;       // a single lane

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

const segNumber = (id: SegId): number => Number(id.slice(3));   // "seg12" -> 12

// The AUTHORED spec for a segment: its id, length, and tree scheme. Everything else a
// RoadSegment carries is either intrinsic (built here) or depends on the bracketing
// intersections (wired once those exist).
export interface RoadSegmentConfig {
  id: SegId;
  length: number;
  scheme: Scheme;
}

// Build a segment's INTRINSIC state from its config: dimensions, roadside trees, and the
// along-the-road critters — all a function of length/scheme alone. The intersection-derived
// bits start empty/neutral: exitCritters (the elephants, added by addElephants once the exit
// turn is known), the graph refs, the turn-commit point (defaults to the segment end, a
// terminus), and the north heading (accumulated along the route). buildWorld fills those.
export function buildRoadSegment(c: RoadSegmentConfig): RoadSegment {
  return {
    id: c.id,
    length: c.length,
    width: LANE_WIDTH,
    scheme: c.scheme,
    trees: segmentTrees(c.length, c.scheme, LANE_WIDTH / 2),
    critters: segmentCritters(c.length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
    exitCritters: [],
    entryIxn: null,
    exitIxn: '',   // a placeholder: set to the real id when this segment's exit intersection is built
    alongWhereRiderCommitsToTurn: c.length,
    northHeading: 0,
  };
}

// Park the exit-intersection elephants on a segment, now that its exit turn is known. A
// terminus has no turn, so it gets none. (The elephants live ON the segment for now; the
// intersection will OWN them in a later step — that's why this is its own pass.)
export function addElephants(seg: RoadSegment, exit: Intersection): void {
  if (exit.to === null) return;
  seg.exitCritters = intersectionCritters(seg.length, exit.sign, segNumber(seg.id), seg.width / 2);
}

export function buildWorld(): World {
  const DEG = Math.PI / 180;

  // ---- author the route ----
  // Each row: a segment's config (id / length / scheme) and the exit turn it takes
  // (to / dir / degrees) or null at the end. Checked non-self-intersecting (no loops) and
  // all-turns-<=-90deg by test/test_model.ts. Hand-authored, opening with a soft S of gentle
  // warm-up turns.
  const turn = (to: SegId, dir: TurnDir, deg: number): IntersectionConfig => ({ to, dir, angle: deg * DEG });
  type Row = RoadSegmentConfig & { exit: IntersectionConfig | null };
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

  // ---- segments: each fully built EXCEPT the bits that need the intersections ----
  const segments: Record<SegId, RoadSegment> = {};
  for (const r of route) segments[r.id] = buildRoadSegment({ id: r.id, length: r.length, scheme: r.scheme });

  // ---- intersections: a turn NODE per exit + the TERMINUS that closes the route. Each is
  // wired into the segments it joins: the graph refs both ways, and (at a turn) the arriving
  // segment's turn-commit point — the inner-edge crossing hw/tan(THETA) before its end. ----
  const intersections: Record<IxnId, Intersection> = {};
  for (const r of route) {
    const from = segments[r.id];
    if (r.exit) {
      const to = segments[r.exit.to];
      const ixn = buildIntersection(from, to, r.exit.dir, r.exit.angle);
      intersections[ixn.id] = ixn;
      from.exitIxn = ixn.id;
      to.entryIxn = ixn.id;
      from.alongWhereRiderCommitsToTurn = r.length - (from.width / 2) / Math.tan(r.exit.angle);
    } else {
      const ixn = buildTerminus(from);   // the Rider arrives and stops; commit point stays at the end
      intersections[ixn.id] = ixn;
      from.exitIxn = ixn.id;
    }
  }

  // ---- orientation relative to north, accumulated along the route ----
  for (const id of order) {
    const ixn = intersections[segments[id].exitIxn];
    if (ixn.to === null) continue;   // terminus: nothing downstream
    segments[ixn.to].northHeading = segments[id].northHeading + ixn.sign * ixn.angle;
  }

  // ---- elephants at each segment's exit turn (none at the terminus) ----
  for (const id of order) addElephants(segments[id], intersections[segments[id].exitIxn]);

  return { segments, intersections, start: 'seg1', order };
}
