// =============================================================================
// world — the ROAD NETWORK as a graph: segments (the straight EDGES, from
// road_segment.ts) joined by intersections (the turn NODES, from intersection.ts).
// buildWorld authors the route from two explicit lists — the segments and the
// intersections between them — and wires them into the graph. No Rider, no canvas:
// model.ts (the Rider's motion) and view.ts (the scene) build on this, not the
// other way round.
// =============================================================================

import { buildRoadSegment } from './road_segment.ts';
import type { RoadSegment, RoadSegmentConfig, SegId, TurnDir } from './road_segment.ts';
import { buildIntersection, buildTerminus } from './intersection.ts';
import type { Intersection, IxnId } from './intersection.ts';
import { CornerCreature } from './safari_critter.ts';

export interface World {
  segments: Record<SegId, RoadSegment>;
  intersections: Record<IxnId, Intersection>;
  start: SegId;
  order: SegId[];
}

const DEG = Math.PI / 180;

// The AUTHORED spec for one turn before it's wired into built segments: which segments it
// joins, its direction + angle, and the creatures at the corner. buildWorld resolves each
// against the two segment objects (mirrors RoadSegmentConfig -> buildRoadSegment).
interface IxnSpec {
  from: SegId;
  to: SegId;
  dir: TurnDir;
  angle: number;
  creature: CornerCreature;
}

// Author one turn. The angle is SIGNED degrees: + turns right, - turns left (matching the
// graph's heading sign, where right is the +rotation). So `intersectionFrom('seg1','seg2',50,E)`
// is a 50deg right turn onto seg2 with elephants at the corner.
const intersectionFrom = (from: SegId, to: SegId, deg: number, creature: CornerCreature): IxnSpec =>
  ({ from, to, dir: deg < 0 ? 'left' : 'right', angle: Math.abs(deg) * DEG, creature });

export function buildWorld(): World {
  const Z = CornerCreature.ZEBRA, E = CornerCreature.ELEPHANT, G = CornerCreature.GIRAFFE, C = CornerCreature.CROCODILE;

  // ---- the segments: the straight stretches (id / length / tree scheme / whether pigs gather).
  // The route opens straight onto the long seg1 so the sunset is already underway by the first
  // stretch (horizon.ts's SUN_START_PX is calibrated to it).
  //
  // VARIETY GRAMMAR (random482/483): the baseline is deliberately boring — ALL_GREEN trees, a cow
  // herd, an elephant corner — so the rare departures actually surprise. We FRONT-LOAD novelty so a
  // new player learns the game isn't dull (seg2 cat, then a new element on seg3/4/5), keep the long
  // sunset stretch calm so the sun's arrival lands, then run a NEW / boring / boring rhythm from
  // seg13 on. Features DEBUT once, then reappear irregularly as the route's complexity ramps up.
  //
  // Two motifs that recur enough to become comfortable (not surprises): PIGS — debut alone at seg3,
  // then from seg8 on a near-constant roadside motif (the rider habitually glances at them, rider.ts),
  // with one conspicuous ABSENCE at seg16 as a surprise; and RED TREES — a subtle "watch for new
  // stuff" CLUE, lit on the segments that carry something notable (seg7 sunset, seg13 croc+cat,
  // seg16 zebra+pig-absence, seg19 red+cat finale). YELLOW trees are the one-off first-colour reveal
  // at seg4. Corner-creature departures are in the turns table below. ----
  const segmentConfigs: RoadSegmentConfig[] = [
    { id: 'seg1',  length: 500,  scheme: 'ALL_GREEN',    pigs: false },  // opener: plain road, kept short to reach the action sooner
    { id: 'seg2',  length: 320,  scheme: 'ALL_GREEN',    pigs: false },  // the CAT crossing (cat_motion's CAT_SEGMENTS)
    { id: 'seg3',  length: 400,  scheme: 'ALL_GREEN',    pigs: true  },  // NEW: pigs first appear (alone)
    { id: 'seg4',  length: 300,  scheme: 'YELLOW_GREEN', pigs: false },  // NEW: first new tree colour (golden, one-off)
    { id: 'seg5',  length: 300,  scheme: 'ALL_GREEN',    pigs: false },  // NEW: first giraffe (at its corner)
    { id: 'seg6',  length: 300,  scheme: 'ALL_GREEN',    pigs: false },  // -- seg6-12: boring apart from the sunset --
    { id: 'seg7',  length: 1200, scheme: 'RED_GREEN',    pigs: false },  // the long sun-ward stretch (mid-tower + sunset); red-tree clue
    { id: 'seg8',  length: 300,  scheme: 'ALL_GREEN',    pigs: true  },  // pigs return and settle into a constant motif
    { id: 'seg9',  length: 300,  scheme: 'ALL_GREEN',    pigs: true  },
    { id: 'seg10', length: 800,  scheme: 'ALL_GREEN',    pigs: true  },  // the second sun-ward stretch
    { id: 'seg11', length: 300,  scheme: 'ALL_GREEN',    pigs: true  },
    { id: 'seg12', length: 300,  scheme: 'ALL_GREEN',    pigs: true  },
    { id: 'seg13', length: 300,  scheme: 'RED_GREEN',    pigs: true  },  // NEW: crocodile lagoon + cat; red-tree clue
    { id: 'seg14', length: 400,  scheme: 'ALL_GREEN',    pigs: true  },  // boring
    { id: 'seg15', length: 300,  scheme: 'ALL_GREEN',    pigs: true  },  // boring
    { id: 'seg16', length: 300,  scheme: 'RED_GREEN',    pigs: false },  // NEW: zebra; red-tree clue; SURPRISE — the pigs are gone
    { id: 'seg17', length: 300,  scheme: 'ALL_GREEN',    pigs: true  },  // boring (pigs back)
    { id: 'seg18', length: 300,  scheme: 'ALL_GREEN',    pigs: true  },  // boring
    { id: 'seg19', length: 300,  scheme: 'RED_GREEN',    pigs: true  },  // NEW: red trees + cat, the finale before the terminus
  ];
  const order: SegId[] = segmentConfigs.map((c) => c.id);

  // ---- the intersections: the turn joining each segment to the next (signed degrees, + right /
  // - left). ELEPHANT is the default corner creature; the others are the rare departures that give a
  // segment its character — a GIRAFFE debut (seg5), the CROCODILE lagoon (seg13), a ZEBRA (seg16).
  // Crocodiles only sit at RIGHT turns (their lagoon is on the corner's left = a right turn's outer
  // side; enforced by test_model) — seg13's +15 turn qualifies. The turn ANGLES are unchanged: the
  // early ones are locked by the sunset calibration (seg7/seg10 headings, test_model), so variety
  // rides on the creatures and trees, not the geometry. seg19 has no entry here — it ends at the
  // terminus, derived below as the one segment that never turns out. ----
  const turns: IxnSpec[] = [
    intersectionFrom('seg1',  'seg2',   50, E),
    intersectionFrom('seg2',  'seg3',  -70, E),
    intersectionFrom('seg3',  'seg4',   20, E),
    intersectionFrom('seg4',  'seg5',   20, E),
    intersectionFrom('seg5',  'seg6',  -70, G),   // NEW: first giraffe
    intersectionFrom('seg6',  'seg7',  -70, E),
    intersectionFrom('seg7',  'seg8',   80, E),
    intersectionFrom('seg8',  'seg9',   15, E),
    intersectionFrom('seg9',  'seg10', -70, E),
    intersectionFrom('seg10', 'seg11',  15, E),
    intersectionFrom('seg11', 'seg12',  15, E),
    intersectionFrom('seg12', 'seg13',  15, E),
    intersectionFrom('seg13', 'seg14',  15, C),   // NEW: crocodile lagoon (right turn)
    intersectionFrom('seg14', 'seg15', -50, E),
    intersectionFrom('seg15', 'seg16',  50, E),
    intersectionFrom('seg16', 'seg17', -50, Z),   // NEW: zebra
    intersectionFrom('seg17', 'seg18',  50, E),
    intersectionFrom('seg18', 'seg19', -50, E),
  ];

  // ---- build the segments (intrinsic state only), then wire the graph ----
  const segments: Record<SegId, RoadSegment> = {};
  for (const c of segmentConfigs) segments[c.id] = buildRoadSegment(c);

  // each turn becomes an intersection NODE wired into the two segments it joins: the graph refs
  // both ways, and the arriving segment's turn-commit point (the inner-edge crossing hw/tan(THETA)
  // before its end).
  const intersections: Record<IxnId, Intersection> = {};
  for (const t of turns) {
    const from = segments[t.from], to = segments[t.to];
    const ixn = buildIntersection(from, to, t.dir, t.angle, t.creature);
    intersections[ixn.id] = ixn;
    from.exitIxn = ixn.id;
    to.entryIxn = ixn.id;
    from.alongWhereRiderCommitsToTurn = from.length - (from.width / 2) / Math.tan(t.angle);
  }

  // the TERMINUS closes the route: it's the one segment that no turn leads out of (its exitIxn is
  // still the placeholder). The Rider arrives and stops; its commit point stays at the segment end.
  for (const id of order) {
    if (segments[id].exitIxn) continue;
    const ixn = buildTerminus(segments[id]);
    intersections[ixn.id] = ixn;
    segments[id].exitIxn = ixn.id;
  }

  // ---- orientation relative to north, accumulated along the route ----
  for (const id of order) {
    const ixn = intersections[segments[id].exitIxn];
    if (ixn.to === null) continue;   // terminus: nothing downstream
    segments[ixn.to].northHeading = segments[id].northHeading + ixn.sign * ixn.angle;
  }

  return { segments, intersections, start: order[0], order };
}
