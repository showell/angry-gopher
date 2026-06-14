// cat_motion.ts — places a cat beside the road and runs its three-phase crossing as the rider nears:
// ENTERS (walk in until the head sphere's centre is over the lane centre), FROZEN (stop dead, the head
// swivels 90° to face us, deer-in-the-headlights), ESCAPES (bolt the rest of the way, clearing the road
// tail-tip and all by the final frame). Two head swivels in all (profile->front, front->profile).
//
// The crossing is clocked in RIDER FRAMES, not metres: it's a pure function of the rider's along-gap to
// the cat and his speed, so a faster rider gives the cat a shorter real distance to cover in the same
// frames, and the whole thing replays cleanly under pause/reverse. The drawing lives in cat_anatomy.ts.

import type { Tree } from './tree.ts';
import type { CatForm } from './cat_anatomy.ts';
import { CAT, CAT_HEAD_X, CAT_TAIL_REACH } from './cat_anatomy.ts';

// ---- types ----

// a cat in its SEGMENT's frame. It crosses from startAcross (right of the road) to endAcross (clear,
// on the left), pausing frozen at midAcross (head centred on the lane). + across = right of centre.
export interface Cat {
  along: number;
  startAcross: number;
  midAcross: number;
  endAcross: number;
  height: number;       // standing height, metres
  faceRight: boolean;
  form: CatForm;
}

// the cat's whole pose this frame: lateral offset, a vertical hop (lift, in cat-heights), the gait phase
// (radians), whether the head faces us (freeze), and the LEAP progress (leapT: -1 = not leaping; 0..1 =
// coil -> airborne stretch -> land).
export interface CatPose { across: number; lift: number; walk: number; headFront: boolean; leapT: number }

// ---- constants ----

// crossing choreography, in rider frames (= steps); the three phases sum to the crossing window.
const ENTERS_ROAD_STEPS = 10;
const FROZEN_STEPS = 24;
const ESCAPES_STEPS = 6;
const CROSS_FRAMES = ENTERS_ROAD_STEPS + FROZEN_STEPS + ESCAPES_STEPS;

// the leap (the escape): the first frame is a COIL (spring compressed, still at mid); then it springs and
// is AIRBORNE, covering the distance to the far side while rising in a parabola, then lands.
const COIL_FRAC = 0.12;         // fraction of the escape spent coiled (≈ the first escape frame)
const LEAP_HEIGHT = 0.46;       // peak hop, in cat-heights — mostly leaping away, only ~half its height up

const ROAD_BUFFER = 3;          // metres of clear road kept between rider and cat — the cat clears with a little room to spare; tunes how close the encounter feels (was 5, then 1; 3 splits the difference)
const STRIDE_STEPS = 5;         // target rider steps per leg cycle (rounded to a whole cycle per phase)

// which segments get a crossing cat (by segment number), and where it spawns / how big it is. The
// cat DEBUTS alone at seg2, then REAPPEARS irregularly on the late NEW segments (13, 19) — never
// every segment (a hazard seen everywhere is only a tax), but more than once so a rider who missed
// it the first time still meets it, and the reappearances stack with those segments' other features
// as the route's complexity ramps up.
const CAT_SEGMENTS = new Set([2, 13, 19]);
const CAT_HEIGHT = 1.7;         // metres, ground to ear tips
const CAT_ALONG = 105;          // desired spot down the road; rounded up to just past a tree
const CAT_ROAD_GAP = 1.5;       // clearance beyond the roadside tree line, each side
const CAT_BEYOND_TREE = 2;      // sits this far past the rounding tree, so the tree reads in front of it

const clamp = (x: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, x));
const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;

// ---- functions ----

// crossing progress 0..1 from the rider's along-gap to the cat (m) and his speed (m/press). The gap is
// measured to a point ROAD_BUFFER short of the cat: 0 until he is CROSS_FRAMES frames from THAT point,
// then linear to 1 as he reaches it — so the cat is clear with road still to spare.
function crossT(gap: number, v: number): number {
  const e = gap - ROAD_BUFFER;
  if (e <= 0) return 1;            // within the buffer — fully across already
  if (v <= 1e-6) return 0;         // stopped: the frame-clock isn't ticking
  return clamp(1 - e / (CROSS_FRAMES * v), 0, 1);
}

// gait phase over a walking phase of `phaseLen` steps at local progress p (0..1): a whole number of leg
// cycles (≈ phaseLen / STRIDE_STEPS, at least one), so the legs start and end the phase at rest.
function gait(p: number, phaseLen: number): number {
  const cycles = Math.max(1, Math.round(phaseLen / STRIDE_STEPS));
  return p * cycles * 2 * Math.PI;
}

// Map the single crossing clock (crossT) onto a step counter 0..CROSS_FRAMES, then split it into the
// three phases. The head swivels to front ONLY in the freeze.
export function catPose(c: Cat, riderAlong: number, v: number): CatPose {
  const step = crossT(c.along - riderAlong, v) * CROSS_FRAMES;
  const freezeAt = ENTERS_ROAD_STEPS;
  const escapeAt = ENTERS_ROAD_STEPS + FROZEN_STEPS;

  if (step <= freezeAt) {                                          // ENTERS: walk in to the lane centre
    const p = freezeAt > 0 ? step / freezeAt : 1;
    return { across: lerp(c.startAcross, c.midAcross, p), lift: 0, walk: gait(p, freezeAt), headFront: false, leapT: -1 };
  }
  if (step <= escapeAt) {                                          // FROZEN: stand dead still, facing us
    return { across: c.midAcross, lift: 0, walk: 0, headFront: true, leapT: -1 };
  }
  // ESCAPES: the LEAP. Coil in place, then spring airborne across the road in a parabola and land.
  const p = clamp((step - escapeAt) / ESCAPES_STEPS, 0, 1);
  if (p < COIL_FRAC) return { across: c.midAcross, lift: 0, walk: 0, headFront: false, leapT: p };
  const q = (p - COIL_FRAC) / (1 - COIL_FRAC);                     // 0..1 over the airborne + landing
  const ease = Math.pow(q, 0.7);                                   // front-loaded: most horizontal momentum right off the launch (low, flat trajectory)
  return {
    across: lerp(c.midAcross, c.endAcross, ease),
    lift: LEAP_HEIGHT * 4 * q * (1 - q),                           // parabola: 0 -> peak -> 0 (lands)
    walk: 0,
    headFront: false,
    leapT: p,
  };
}

// Is the cat still ahead (beyond the buffer) AND inside the crossing window — i.e. crossing in front of
// us right now? While this holds the rider must not accelerate (he sees it and holds off).
function catInDanger(c: Cat, riderAlong: number, v: number): boolean {
  const e = (c.along - riderAlong) - ROAD_BUFFER;
  return e > 0 && e <= CROSS_FRAMES * v;
}

// Any cat on this segment crossing in front of the rider right now? (The model's accel gate.)
export function segmentCatDanger(cats: Cat[], riderAlong: number, v: number): boolean {
  return cats.some((c) => catInDanger(c, riderAlong, v));
}

// the smallest right-side tree `along` at or after `desired` — the cat is tucked just past it. Trees are
// NOT evenly spaced (size/scheme nudges some off the line and the count-per-segment stretches the
// stride), so read the segment's actual trees instead of assuming a regular interval.
function nextTreeAlong(desired: number, trees: Tree[]): number {
  let best = Infinity;
  for (const t of trees) if (t.across > 0 && t.along >= desired && t.along < best) best = t.along;
  return Number.isFinite(best) ? best : desired;
}

// Build a cat of the given size. Size (height in metres) is decoupled from form (the unit-frame
// skeleton), so the same cat can be a kitten or full-grown — only the height changes.
function makeCat(along: number, startAcross: number, midAcross: number, endAcross: number, height: number, faceRight: boolean): Cat {
  return { along, startAcross, midAcross, endAcross, height, faceRight, form: CAT };
}

// The cats on a segment: only CAT_SEGMENTS get one (else none) — a cat that waits beside the road on the
// RIGHT, just past the herd, then crosses to the LEFT as the rider nears.
export function segmentCats(segmentNumber: number, laneHalfWidth: number, treeLineOffset: number, trees: Tree[]): Cat[] {
  if (!CAT_SEGMENTS.has(segmentNumber)) return [];
  const treeX = laneHalfWidth + treeLineOffset;
  const start = treeX + CAT_ROAD_GAP;   // waiting spot, beside the road on the right
  // Freeze spot: the head sphere sits at local x CAT_HEAD_X, which maps to an across offset of
  // CAT_HEAD_X * height from the feet anchor — so to put the head CENTRE on the lane centreline, the
  // anchor sits at -CAT_HEAD_X * height.
  const mid = -CAT_HEAD_X * CAT_HEIGHT;
  // Far side: the sprite reaches CAT_TAIL_REACH * height from its anchor (the tail tip), so to be
  // COMPLETELY clear of the road — tail and all — the anchor sits a full reach (plus the road gap) past
  // the left edge.
  const end = -(laneHalfWidth + CAT_ROAD_GAP + CAT_TAIL_REACH * CAT_HEIGHT);
  // round the along UP to a tree and sit just beyond it, so a tree stands between the rider and the cat.
  const along = nextTreeAlong(CAT_ALONG, trees) + CAT_BEYOND_TREE;
  return [makeCat(along, start, mid, end, CAT_HEIGHT, false)];
}
