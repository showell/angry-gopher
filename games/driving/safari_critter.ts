// safari_critter — the big animals parked AT a corner (elephant, giraffe, zebra): an adult standing
// just past the far edge as if it had crossed, and its baby ahead in the Rider's path. Placement is
// one shared rule; only the per-species dimensions differ, so a new species is just a SPECIES entry.

import type { Critter } from './critter.ts';

export const CornerCreature = { ELEPHANT: 'ELEPHANT', GIRAFFE: 'GIRAFFE', ZEBRA: 'ZEBRA' } as const;
export type CornerCreature = typeof CornerCreature[keyof typeof CornerCreature];

interface CornerSpecies {
  emoji: string;
  adultHeight: number;   // metres — giraffes stand taller than elephants
  babyRatio: number;     // baby height as a fraction of the adult
  babyBeyond: number;    // how far past the turn the baby stands, in the Rider's path
  giantScale: number;    // cartoonish late-route upsizing...
  giantFromSeg: number;  // ...applied on segments numbered above this (the late-route corners)
}
const SPECIES: Record<CornerCreature, CornerSpecies> = {
  ELEPHANT: { emoji: '🐘', adultHeight: 2.8, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
  GIRAFFE:  { emoji: '🦒', adultHeight: 4.5, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
  ZEBRA:    { emoji: '🦓', adultHeight: 1.6, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
};

// The two creatures AT a segment's exit intersection — they read as having just CROSSED it. The
// adult stands at the FAR corner: for a RIGHT turn its bottom-RIGHT corner sits on EL (end-left),
// facing left; for a LEFT turn (mirror, NOT a flip) its bottom-LEFT corner sits on ER (end-right),
// facing RIGHT. So its centre is half its width beyond that edge — an offset that scales with the
// giant late-route size. The baby stands ahead in the Rider's path, BEYOND the turn. `turnSign` is
// +1 right / -1 left; `hw` is the road half-width; the corners are EL/ER at along=intersectionAlong.
export function cornerCritters(creature: CornerCreature, intersectionAlong: number, turnSign: number, segNum: number, hw: number): Critter[] {
  const spec = SPECIES[creature];
  const scale = segNum > spec.giantFromSeg ? spec.giantScale : 1;
  const adultH = spec.adultHeight * scale, babyH = adultH * spec.babyRatio;
  const faceRight = turnSign < 0;                      // right turn -> faces left; left turn -> faces right
  return [
    { along: intersectionAlong, across: -turnSign * (hw + adultH / 2), emoji: spec.emoji, height: adultH, faceRight },
    { along: intersectionAlong + spec.babyBeyond, across: 0, emoji: spec.emoji, height: babyH, faceRight },
  ];
}
