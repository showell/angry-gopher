// safari_critter — the big animals parked AT a corner. Most are emoji billboards (elephant, giraffe,
// zebra): an adult standing just past the far edge as if it had crossed, and its baby ahead in the
// Rider's path; placement is one shared rule, only the per-species dimensions differ. CROCODILE is the
// exception — a hand-drawn lagoon scene — so this module HANDS OFF to crocodile.ts for it.

import type { Critter } from './critter.ts';
import type { Quad, Scenery } from './scenery.ts';
import { crocodileScene } from './crocodile.ts';
import type { CornerMap } from './crocodile.ts';

export const CornerCreature = { ELEPHANT: 'ELEPHANT', GIRAFFE: 'GIRAFFE', ZEBRA: 'ZEBRA', RHINO: 'RHINO', CROCODILE: 'CROCODILE' } as const;
export type CornerCreature = typeof CornerCreature[keyof typeof CornerCreature];

// the EMOJI species — the crocodile is hand-drawn (crocodile.ts), not a billboard, so it's excluded here.
type EmojiCreature = Exclude<CornerCreature, typeof CornerCreature.CROCODILE>;

interface CornerSpecies {
  emoji: string;
  adultHeight: number;   // metres — giraffes stand taller than elephants
  babyRatio: number;     // baby height as a fraction of the adult
  babyBeyond: number;    // how far past the turn the baby stands, in the Rider's path
  giantScale: number;    // cartoonish late-route upsizing...
  giantFromSeg: number;  // ...applied on segments numbered above this (the late-route corners)
}
const SPECIES: Record<EmojiCreature, CornerSpecies> = {
  ELEPHANT: { emoji: '🐘', adultHeight: 2.8, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
  GIRAFFE:  { emoji: '🦒', adultHeight: 4.5, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
  ZEBRA:    { emoji: '🦓', adultHeight: 1.6, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
  RHINO:    { emoji: '🦏', adultHeight: 3.2, babyRatio: 0.5, babyBeyond: 14, giantScale: 1.7, giantFromSeg: 8 },
};

// the adult stands a guard-rail's-worth further off the corner than half its width, so the rail riding
// the outer edge doesn't clip it.
const ADULT_RAIL_BUFFER = 1.5;   // metres

// The two emoji creatures AT a segment's exit intersection — they read as having just CROSSED it. The
// adult stands at the FAR corner: for a RIGHT turn its bottom-RIGHT corner sits on EL (end-left), facing
// left; for a LEFT turn (mirror, NOT a flip) its bottom-LEFT corner sits on ER (end-right), facing RIGHT.
// So its centre is half its width (plus the rail buffer) beyond that edge. The baby stands ahead in the
// Rider's path, BEYOND the turn. `turnSign` is +1 right / -1 left; `hw` is the road half-width. A
// CROCODILE corner has no emoji pair — its lagoon scene comes from cornerCreatureExtras instead.
export function cornerCritters(creature: CornerCreature, intersectionAlong: number, turnSign: number, segNum: number, hw: number): Critter[] {
  if (creature === CornerCreature.CROCODILE) return [];
  const spec = SPECIES[creature];
  const scale = segNum > spec.giantFromSeg ? spec.giantScale : 1;
  const adultH = spec.adultHeight * scale, babyH = adultH * spec.babyRatio;
  const faceRight = turnSign < 0;                      // right turn -> faces left; left turn -> faces right
  return [
    { along: intersectionAlong, across: -turnSign * (hw + ADULT_RAIL_BUFFER + adultH / 2), emoji: spec.emoji, height: adultH, faceRight },
    { along: intersectionAlong + spec.babyBeyond, across: 0, emoji: spec.emoji, height: babyH, faceRight },
  ];
}

// The corner's EXTRA scene beyond the emoji pair: a CROCODILE corner hands off to crocodile.ts for a
// lagoon + four crocs; every other species adds nothing. `corner` maps incoming corner-frame metres (cu
// across, cv beyond) into the Rider's frame; `segNum` drives the same late-route upsizing as the giants.
export function cornerCreatureExtras(creature: CornerCreature | null, segNum: number, corner: CornerMap): { quads: Quad[]; scenery: Scenery[] } {
  if (creature === CornerCreature.CROCODILE) return crocodileScene(corner, segNum);
  return { quads: [], scenery: [] };
}
