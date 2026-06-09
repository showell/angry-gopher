// crocodile.ts — the crocodile corner: a little lagoon just BEYOND a right-turn intersection, off to
// the LEFT of the OUTGOING road, with four crocodile emoji on the near bank. Authored in the OUTGOING
// segment's frame — the road the rider continues onto — so the lagoon stretches ~12m along his path
// PAST the turn. (Authoring it in the incoming segment's frame instead looks wrong: a 50° turn sweeps
// "12m beyond the incoming road" mostly sideways, so it barely reaches past the corner.) safari_critter
// hands off here when a corner's creature is CROCODILE.
//
// Frame: a = metres along the OUTGOING road beyond the corner (the rider's new forward), x = across it
// from the left edge (0 = left edge, + = toward/across the road; the lagoon's x is NEGATIVE, out to the
// left — the outer side of the right turn).

import { critterScenery } from './critter.ts';
import type { Scenery, Quad, RiderPt } from './scenery.ts';

// ---- types ----

// maps an outgoing-road point (a along, x across) into the Rider's frame.
export type RoadMap = (along: number, across: number) => RiderPt;
type P = readonly [number, number];

// ---- constants ----

// the lagoon outline, outgoing-road metres [a, x]: a ~12m-square blob off the LEFT of the road, reaching
// from just past the corner (a 2) to ~13m down the road, and 1..13m out to the left.
const LAGOON: P[] = [
  [2, -7], [3.5, -2], [7, -1], [11, -2], [13, -7], [11, -12], [7, -13], [3.5, -12],
];
const LAGOON_WATER = '#2f7e8c';

// the four crocs on the NEAR bank — the lagoon's front edge, toward the corner the rider just rounded —
// side by side across the width, all facing the same way.
const CROC_BANK: P[] = [[1.8, -2.5], [1.6, -5.5], [1.8, -8.5], [2.0, -11.5]];
const CROC_EMOJI = '🐊';
const CROC_FACE_RIGHT = true;       // all four face the same way

const CROC_ADULT_HEIGHT = 1.4;      // metres
const CROC_GIANT_SCALE = 1.7;       // late-route corners upsize, like the other safari critters...
const CROC_GIANT_FROM_SEG = 8;      // ...on segments numbered above this

// ---- functions ----

// The crocodile corner scene: the lagoon (a ground quad) plus the four crocs (emoji billboards), all
// placed in the outgoing road's frame via `road`.
export function crocodileScene(road: RoadMap, segNum: number): { quads: Quad[]; scenery: Scenery[] } {
  const height = CROC_ADULT_HEIGHT * (segNum > CROC_GIANT_FROM_SEG ? CROC_GIANT_SCALE : 1);
  const lagoon: Quad = { pts: LAGOON.map(([a, x]) => road(a, x)), color: LAGOON_WATER };
  const scenery = CROC_BANK.map(([a, x]) =>
    critterScenery({ at: road(a, x), emoji: CROC_EMOJI, height, faceRight: CROC_FACE_RIGHT }));
  return { quads: [lagoon], scenery };
}
