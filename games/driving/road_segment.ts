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

import { segmentCritters, CornerCreature } from './critter.ts';
import type { Critter } from './critter.ts';
import { segmentTrees, TREE_ROAD_OFFSET } from './tree.ts';
import type { Scheme, Tree } from './tree.ts';
import { buildIntersection, buildTerminus } from './intersection.ts';
import type { Intersection, IxnId, IntersectionConfig } from './intersection.ts';
import { beaconOffsetFor } from './tower.ts';

// ---- road dimensions (metres) ----
const LANE_WIDTH = 4;       // a single lane

// A long, straight stretch is dull, so a road segment longer than this stands its OWN tower
// halfway down (owned by the segment, not an intersection — see view.ts for the placement).
const MID_TOWER_MIN_LENGTH = 1000;

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
  critters: Critter[];      // roadside, along the segment (cows/pigs); the elephants live on the exit Intersection
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

export interface World {
  segments: Record<SegId, RoadSegment>;
  intersections: Record<IxnId, Intersection>;
  start: SegId;
  order: SegId[];
}

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
// bits start empty/neutral: the graph refs, the turn-commit point (defaults to the segment
// end, a terminus), and the north heading (accumulated along the route). buildWorld fills
// those, and the elephants live on the exit Intersection, not here.
export function buildRoadSegment(c: RoadSegmentConfig): RoadSegment {
  return {
    id: c.id,
    length: c.length,
    width: LANE_WIDTH,
    scheme: c.scheme,
    trees: segmentTrees(c.length, c.scheme, LANE_WIDTH / 2),
    critters: segmentCritters(c.length, LANE_WIDTH / 2, TREE_ROAD_OFFSET),
    entryIxn: null,
    exitIxn: '',   // a placeholder: set to the real id when this segment's exit intersection is built
    alongWhereRiderCommitsToTurn: c.length,
    northHeading: 0,
    // long segments earn a mid-road tower; its blink phase is seeded off a shifted segment number
    // so it doesn't pulse in unison with the segment's exit-intersection tower.
    midTower: c.length > MID_TOWER_MIN_LENGTH ? { beaconOffset: beaconOffsetFor(Number(c.id.slice(3)) + 60) } : null,
  };
}

export function buildWorld(): World {
  const DEG = Math.PI / 180;

  // ---- author the route ----
  // Each row: a segment's config (id / length / scheme) and the exit turn it takes
  // (to / dir / degrees) or null at the end. Checked non-self-intersecting (no loops) and
  // all-turns-<=-90deg by test/test_model.ts. Hand-authored; opens straight onto the long
  // seg1 so the sunset is already underway by the first stretch (SUN_START_PX is calibrated to it).
  const turn = (to: SegId, dir: TurnDir, deg: number, creature: CornerCreature = CornerCreature.ELEPHANT): IntersectionConfig =>
    ({ to, dir, angle: deg * DEG, creature });
  type Row = RoadSegmentConfig & { exit: IntersectionConfig | null };
  // Corner creatures are authored explicitly per turn: zebras open the route, elephants take
  // over, then giraffes, then all three intermingle. No runtime scattering — it's all here.
  const Z = CornerCreature.ZEBRA, E = CornerCreature.ELEPHANT, G = CornerCreature.GIRAFFE;
  const route: Row[] = [
    { id: 'seg1',  length: 800, scheme: 'RED_GREEN',    exit: turn('seg2',  'right', 50, E) },
    { id: 'seg2',  length: 320, scheme: 'ALL_GREEN',    exit: turn('seg3',  'left',  70, E) },
    { id: 'seg3',  length: 400, scheme: 'YELLOW_GREEN', exit: turn('seg4',  'right', 20, G) },
    { id: 'seg4',  length: 300, scheme: 'RED_GREEN',    exit: turn('seg5',  'right', 20, G) },
    { id: 'seg5',  length: 300, scheme: 'ALL_GREEN',    exit: turn('seg6',  'left',  70, Z) },
    { id: 'seg6',  length: 300, scheme: 'YELLOW_GREEN', exit: turn('seg7',  'left',  70, G) },
    { id: 'seg7',  length: 1200, scheme: 'RED_GREEN',   exit: turn('seg8',  'right', 80, E) },
    { id: 'seg8',  length: 300, scheme: 'ALL_GREEN',    exit: turn('seg9',  'right', 15, Z) },
    { id: 'seg9',  length: 300, scheme: 'YELLOW_GREEN', exit: turn('seg10', 'left',  70, G) },
    { id: 'seg10', length: 800, scheme: 'RED_GREEN',    exit: turn('seg11', 'right', 15, E) },
    { id: 'seg11', length: 300, scheme: 'ALL_GREEN',    exit: turn('seg12', 'right', 15, Z) },
    { id: 'seg12', length: 300, scheme: 'YELLOW_GREEN', exit: turn('seg13', 'right', 15, G) },
    { id: 'seg13', length: 300, scheme: 'RED_GREEN',    exit: turn('seg14', 'right', 15, E) },
    { id: 'seg14', length: 400, scheme: 'ALL_GREEN',    exit: turn('seg15', 'left',  50, Z) },
    { id: 'seg15', length: 300, scheme: 'YELLOW_GREEN', exit: turn('seg16', 'right', 50, G) },
    { id: 'seg16', length: 300, scheme: 'RED_GREEN',    exit: turn('seg17', 'left',  50, E) },
    { id: 'seg17', length: 300, scheme: 'ALL_GREEN',    exit: turn('seg18', 'right', 50, Z) },
    { id: 'seg18', length: 300, scheme: 'YELLOW_GREEN', exit: turn('seg19', 'left',  50, G) },
    { id: 'seg19', length: 300, scheme: 'RED_GREEN',    exit: null },
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
      const ixn = buildIntersection(from, to, r.exit.dir, r.exit.angle, r.exit.creature);
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

  return { segments, intersections, start: 'seg1', order };
}
