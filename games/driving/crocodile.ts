// crocodile.ts — the crocodile corner: a little lagoon just BEYOND a (right-turn) intersection, off to
// its LEFT, with four crocodile emoji sunning on the NEAR bank (the shore facing the incoming road).
// safari_critter.ts hands off to this module when a corner's creature is CROCODILE.
//
// Authored in the CORNER frame the intersection hands us: cv = metres BEYOND the end edge (the rider's
// forward direction — the lagoon reaches ~12m this way), cu = metres across from the road's end-left
// corner (0 = left edge, + = toward the road, so the lagoon's cu is NEGATIVE, out to the left).

import { critterScenery } from './critter.ts';
import type { Scenery, Quad, RiderPt } from './scenery.ts';

// ---- types ----

// maps a corner-frame point (cu across, cv beyond) into the Rider's frame.
export type CornerMap = (cu: number, cv: number) => RiderPt;
type P = readonly [number, number];

// ---- constants ----

// the lagoon outline, corner-frame metres: a blob off the LEFT of the road that reaches ~12m beyond the
// intersection (cv 3.5 -> 15.5) and ~12m across (cu -1 -> -13.5). Its near edge (the flat front at cv
// 3.5) faces the incoming road.
const LAGOON: P[] = [
  [-2, 3.5], [-12, 3.5], [-13.5, 9], [-12, 14], [-7, 15.5], [-2.5, 14], [-1, 9],
];
const LAGOON_WATER = '#2f7e8c';

// the four crocs on the NEAR bank: on land just in front of the water (cv 2.5, the near edge is at 3.5),
// spread along the shore, all facing the same way — toward the road.
const CROC_BANK: P[] = [[-3, 2.5], [-5.7, 2.5], [-8.3, 2.5], [-11, 2.5]];
const CROC_EMOJI = '🐊';
const CROC_FACE_RIGHT = true;       // all four face the road

const CROC_ADULT_HEIGHT = 1.4;      // metres
const CROC_GIANT_SCALE = 1.7;       // late-route corners upsize, like the other safari critters...
const CROC_GIANT_FROM_SEG = 8;      // ...on segments numbered above this

// ---- functions ----

// The crocodile corner scene: the lagoon (a ground quad) plus the four crocs (emoji billboards).
export function crocodileScene(corner: CornerMap, segNum: number): { quads: Quad[]; scenery: Scenery[] } {
  const height = CROC_ADULT_HEIGHT * (segNum > CROC_GIANT_FROM_SEG ? CROC_GIANT_SCALE : 1);
  const lagoon: Quad = { pts: LAGOON.map(([cu, cv]) => corner(cu, cv)), color: LAGOON_WATER };
  const scenery = CROC_BANK.map(([cu, cv]) =>
    critterScenery({ at: corner(cu, cv), emoji: CROC_EMOJI, height, faceRight: CROC_FACE_RIGHT }));
  return { quads: [lagoon], scenery };
}
