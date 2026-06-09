// crocodile.ts — the crocodile corner: a lagoon just BEYOND a right-turn intersection, off to its LEFT,
// with four crocodile emoji on the near bank. Authored in the INCOMING segment's corner frame (the road
// the rider arrives on). It's drawn LARGE — ~30m across and ~30m beyond — partly because a corner reads
// big up close, and partly to work around the foreshortening a turn puts on it during the approach.
// safari_critter hands off here when a corner's creature is CROCODILE.
//
// Frame: cv = metres BEYOND the incoming segment's end edge (the rider's forward as he arrives), cu =
// metres across from its end-left corner (0 = left edge, + = toward the road; the lagoon's cu is
// NEGATIVE, out to the left — the outer side of the right turn).

import { critterScenery } from './critter.ts';
import type { Scenery, Quad, RiderPt } from './scenery.ts';

// ---- types ----

// maps a corner-frame point (cu across, cv beyond) into the Rider's frame.
export type CornerMap = (cu: number, cv: number) => RiderPt;
type P = readonly [number, number];

// ---- constants ----

// the lagoon outline, corner-frame metres [cu, cv]: a big blob off the LEFT of the road, ~30m across
// (cu -1 -> -31) and reaching ~30m beyond the intersection (cv 3 -> 32). Its near edge (the flat front
// at cv 3) faces the incoming road.
const LAGOON: P[] = [
  [-2, 3], [-28, 3], [-31, 14], [-26, 28], [-15, 32], [-5, 29], [-1, 16],
];
const LAGOON_WATER = '#2f7e8c';

// a 1m khaki mud bank along the water's FAR edge — the shore the crocs sit on. Its inner edge hugs the
// water's far edge (the arc cv 29 -> 32 -> 28), its outer edge is 1m further onto the land.
const MUD_BANK: P[] = [
  [-5, 29], [-15, 32], [-26, 28],   // the water's far edge
  [-26, 29], [-15, 33], [-5, 30],   // 1m back onto the land
];
const MUD_KHAKI = '#c2b280';

// the seven crocs hauled out on the mud bank (the water's far edge + 0.5m), spread across the width, all
// facing the same way.
const CROC_BANK: P[] = [
  [-5, 29.5], [-9, 30.7], [-12, 31.6], [-15, 32.5], [-19, 31.1], [-22, 30], [-26, 28.5],
];
const CROC_EMOJI = '🐊';
const CROC_FACE_RIGHT = true;       // all seven face the same way

const CROC_ADULT_HEIGHT = 2.8;      // metres
const CROC_GIANT_SCALE = 1.7;       // late-route corners upsize, like the other safari critters...
const CROC_GIANT_FROM_SEG = 8;      // ...on segments numbered above this

// ---- functions ----

// The crocodile corner scene: the lagoon (a ground quad) plus the four crocs (emoji billboards), all
// placed in the incoming corner frame via `corner`.
export function crocodileScene(corner: CornerMap, segNum: number): { quads: Quad[]; scenery: Scenery[] } {
  const height = CROC_ADULT_HEIGHT * (segNum > CROC_GIANT_FROM_SEG ? CROC_GIANT_SCALE : 1);
  const lagoon: Quad = { pts: LAGOON.map(([cu, cv]) => corner(cu, cv)), color: LAGOON_WATER };
  const mud: Quad = { pts: MUD_BANK.map(([cu, cv]) => corner(cu, cv)), color: MUD_KHAKI };
  const scenery = CROC_BANK.map(([cu, cv]) =>
    critterScenery({ at: corner(cu, cv), emoji: CROC_EMOJI, height, faceRight: CROC_FACE_RIGHT }));
  return { quads: [lagoon, mud], scenery };
}
