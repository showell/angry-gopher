// beast.ts — a hand-drawn cartoon BEAST in profile (no emoji), modelled from simple solids.
//
// A cat standing in profile, built from the parts you'd name pointing at it:
//   • TORSO — a long rounded cylinder (a horizontal capsule) parallel to the ground.
//   • NECK  — a shorter, thick cylinder (a capsule) that connects the head to the torso.
//   • HEAD  — a sphere (a circle), carried forward at the end of the neck.
//   • LEGS  — four articulated chains (upper leg, lower leg, paw) joined by knee/ankle JOINTS that
//             have no size; a POSE is the set of joint ANGLES, walked by forward kinematics.
//   • TAIL  — a tapering chain of capsules off the rump.
// Filled in one colour the capsules and sphere overlap into a single connected body (no smoothed skin
// over them — that was tried and dropped). Everything lives in a frame where the beast stands 1 unit
// tall (feet on y = 0, ear tips at 1), facing LEFT, x toward the tail.
//
// DEBUG (below) swaps in a diagnostic view: the neck solid pink, the other solids as see-through
// outlines, the legs as their raw skeleton — so the underlying construction is visible. Turn it off
// for the finished cat.

import type { Project, Ctx, Scenery } from './scenery.ts';
import type { Tree } from './tree.ts';

const DEBUG = false;   // set true for the diagnostic view (pink neck + skeleton over transparent solids)

// a point in the beast's profile frame: x toward the tail (right), y up, feet at the origin.
type P = readonly [number, number];

// a rigid bone: its permanent length, the RELATIVE angle (radians) of the joint at its proximal end,
// and the taper of its flesh (radius at the proximal end r0, at the distal end r1).
interface Bone { length: number; joint: number; r0: number; r1: number }

// For now a species is just its palette; the skeleton below is the cat's. A second beast will lift
// the skeleton numbers into this form (same anatomy, different proportions).
interface BeastForm {
  palette: { body: string; shadow: string; line: string; eye: string; nose: string };
}

const CAT: BeastForm = {
  // a ginger cat; shadow is the darker tone for the FAR pair of legs.
  palette: { body: '#c8823c', shadow: '#8a571f', line: '#3a2a17', eye: '#15100a', nose: '#b56b6b' },
};

// ---- the cat skeleton ----

// the TORSO: a horizontal capsule (rounded cylinder) from the shoulder to the rump.
const TORSO_A: P = [-0.14, 0.55];
const TORSO_B: P = [0.66, 0.55];
const TORSO_R = 0.13;

// the NECK: a thick capsule connecting the torso (its base, on the front-upper torso) to the head
// (its top, sunk into the back of the head). This is the "cylinder with real weight" between them.
// (15% smaller than the first cut, shrunk about its own centre.)
const NECK_A: P = [-0.178, 0.608];
const NECK_B: P = [-0.382, 0.693];
const NECK_R = 0.102;

// the HEAD: a sphere (circle) carried forward at the end of the neck.
const HEAD = { cx: -0.48, cy: 0.76, r: 0.16, eye: [-0.53, 0.80], nose: [-0.63, 0.74] } as const;

// one leg: upper leg down (and slightly forward), then the knee bends the lower leg down-and-BACK so
// the foot sits behind the knee, then a small forward paw. All four legs share this shape; they
// differ only in where they attach. (joint angles are rest-pose, radians.)
const LEG_BASE_ANGLE = -1.745;                                // upper leg: down, a touch forward
const UPPER_LEG: Bone = { length: 0.24, joint: 0,      r0: 0.050, r1: 0.040 };
const LOWER_LEG: Bone = { length: 0.21, joint: 0.620,  r0: 0.040, r1: 0.032 };
const PAW:       Bone = { length: 0.05, joint: -1.571, r0: 0.034, r1: 0.030 };

// the WALK: each leg swings fore-aft about its hip (thigh) and bends the knee on the forward (lift)
// half of the swing, so it reads as stepping rather than sliding. The four legs run on a diagonal
// gait — near-front pairs with far-hind, near-hind with far-front (half a cycle apart). The gait
// PHASE counts only the steps SPENT WALKING (the freeze doesn't advance it), so the legs hold at rest
// through the freeze and pick the cycle back up on the way out. One full leg cycle per STRIDE_STEPS.
const STRIDE_STEPS = 5;         // rider steps per full leg cycle
const SWING_AMP = 0.40;         // rad — how far the thigh swings fore/aft
const KNEE_AMP = 0.55;          // rad — extra knee bend at the top of the forward swing

// where the legs attach to the torso (near pair, in front; far pair set back a touch and drawn in
// shade behind the body, so all four legs read).
const FRONT_HIP: P = [-0.10, 0.46];
const HIND_HIP: P = [0.58, 0.46];
const FAR_SETBACK = 0.06;   // the far leg of each pair sits this much further toward the tail

// two triangular ears, seen in PROFILE: the near ear stands on top of the head; the far ear sits a
// little behind it and lower, so (drawn behind the head, in shade) only its tip peeks out.
const NEAR_EAR = { a: [-0.53, 0.84], tip: [-0.53, 1.04], b: [-0.43, 0.87] } as const;
const FAR_EAR = { a: [-0.45, 0.86], tip: [-0.43, 1.00], b: [-0.35, 0.85] } as const;

// the two ears seen FRONT-ON (during the freeze): symmetric triangles atop the head, about HEAD.cx.
const FRONT_EAR_L = { a: [HEAD.cx - 0.15, 0.86], tip: [HEAD.cx - 0.10, 1.03], b: [HEAD.cx - 0.02, 0.88] } as const;
const FRONT_EAR_R = { a: [HEAD.cx + 0.02, 0.88], tip: [HEAD.cx + 0.10, 1.03], b: [HEAD.cx + 0.15, 0.86] } as const;

// the long tail off the rump, sweeping back and curling up at the tip — capsules between the nodes.
const TAIL_NODES: P[] = [[0.72, 0.52], [0.94, 0.50], [1.08, 0.58], [1.14, 0.73]];
const TAIL_RADII = [0.060, 0.050, 0.038, 0.022];

const LINE_WIDTH = 0.012;   // outline weight, in standing-height units (scales with distance)

// diagnostic colours
const GHOST = '#7fa8c9';    // see-through outline for the non-neck solids
const BONE = '#1f4fd8';     // skeleton bones
const JOINT = '#e03b3b';    // skeleton joints
const NECK_FILL = '#ff5fa6';
const NECK_EDGE = '#d23f80';

// A beast in its SEGMENT's frame, like a Critter, but it CROSSES the road: it waits at startAcross
// (beside the road, on the right) and ends at endAcross (fully clear of the road, on the left). The
// current offset is a pure function of how near the rider is — see beastAcross.
export interface Beast {
  along: number;
  startAcross: number;   // waits here, beside the road (+ = right of centre)
  midAcross: number;     // freezes here, head centre over the lane centreline
  endAcross: number;     // ends here, fully clear of the road (- = left of centre)
  height: number;        // standing height, metres
  faceRight: boolean;
  form: BeastForm;
}

// The crossing is clocked in RIDER FRAMES, not metres: the beast starts to move when the rider is
// BEAST_CROSS_FRAMES presses from reaching it (at his current speed) and is completely across by the
// frame he arrives. So a faster rider gives the beast a shorter real distance to cover — same frames.
//
// It runs in THREE phases, each a configurable number of those frames (steps):
//   1. ENTERS  — walk in from the roadside until the centre of the head sphere is over the lane centre.
//   2. FROZEN  — deer-in-the-headlights: stop dead, the head swivels 90° to face us, nothing moves.
//   3. ESCAPES — bolt the rest of the way, clearing the road (tail tip and all) by the final frame.
const CAT_ENTERS_ROAD_STEPS = 20;
const CAT_FROZEN_STEPS = 10;
const CAT_ESCAPES_STEPS = 10;
export const BEAST_CROSS_FRAMES = CAT_ENTERS_ROAD_STEPS + CAT_FROZEN_STEPS + CAT_ESCAPES_STEPS;

// Close the crossing — and release the rider's throttle hold — this far short of the beast, so it's
// never right up against the camera (which distorts things badly up close). The whole crossing clock
// counts down to a point BEAST_ROAD_BUFFER before the beast, not to the beast itself.
export const BEAST_ROAD_BUFFER = 8;   // metres

const clamp = (x: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, x));
const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;

// crossing progress 0..1 from the rider's along-gap to the beast (m) and his speed (m/press). The gap
// is measured to a point BEAST_ROAD_BUFFER short of the beast: 0 until he is BEAST_CROSS_FRAMES frames
// from THAT point, then linear to 1 as he reaches it — so the beast is clear with road still to spare.
function crossT(gap: number, v: number): number {
  const e = gap - BEAST_ROAD_BUFFER;
  if (e <= 0) return 1;                                    // within the buffer — fully across already
  if (v <= 1e-6) return 0;                                 // stopped: the frame-clock isn't ticking
  return clamp(1 - e / (BEAST_CROSS_FRAMES * v), 0, 1);
}

// the beast's whole pose this frame, a pure function of how near the rider is: lateral offset, gait
// phase, and whether the head is swivelled to face us.
export interface BeastPose { across: number; walk: number; headFront: boolean }

// gait phase from the number of steps SPENT WALKING — STRIDE_STEPS per cycle. The phase boundaries
// (ENTERS, FROZEN) are whole multiples of STRIDE_STEPS, so the legs land exactly at rest at the freeze
// and at the finish.
function gait(walkingSteps: number): number {
  return (walkingSteps / STRIDE_STEPS) * 2 * Math.PI;
}

// Map the single crossing clock (crossT) onto a step counter 0..BEAST_CROSS_FRAMES, then split it into
// the three phases: walk in to the centre, freeze and face us, then bolt clear. The head swivels to
// front ONLY in the freeze — two 90° swivels in all (profile -> front entering the freeze, front ->
// profile leaving it).
export function beastPose(b: Beast, riderAlong: number, v: number): BeastPose {
  const step = crossT(b.along - riderAlong, v) * BEAST_CROSS_FRAMES;
  const freezeAt = CAT_ENTERS_ROAD_STEPS;
  const escapeAt = CAT_ENTERS_ROAD_STEPS + CAT_FROZEN_STEPS;

  if (step <= freezeAt) {                                          // ENTERS: walk in to the lane centre
    const p = freezeAt > 0 ? step / freezeAt : 1;
    return { across: lerp(b.startAcross, b.midAcross, p), walk: gait(step), headFront: false };
  }
  if (step <= escapeAt) {                                          // FROZEN: stand dead still, facing us
    return { across: b.midAcross, walk: gait(freezeAt), headFront: true };
  }
  const p = clamp((step - escapeAt) / CAT_ESCAPES_STEPS, 0, 1);    // ESCAPES: bolt clear of the road
  return { across: lerp(b.midAcross, b.endAcross, p), walk: gait(freezeAt + (step - escapeAt)), headFront: false };
}

// Is the beast still ahead (beyond the buffer) AND inside the BEAST_CROSS_FRAMES window — i.e. crossing
// in front of us right now? While this holds the rider must not accelerate (he sees it and holds off).
function beastInDanger(b: Beast, riderAlong: number, v: number): boolean {
  const e = (b.along - riderAlong) - BEAST_ROAD_BUFFER;
  return e > 0 && e <= BEAST_CROSS_FRAMES * v;
}

// Any beast on this segment crossing in front of the rider right now? (The model's accel gate.)
export function segmentBeastDanger(beasts: Beast[], riderAlong: number, v: number): boolean {
  return beasts.some((b) => beastInDanger(b, riderAlong, v));
}

// A beast placed in the scene, measured FROM THE RIDER and ready to draw.
export interface BeastView {
  at: { right: number; forward: number };
  height: number;
  faceRight: boolean;
  form: BeastForm;
  walk: number;        // gait phase (radians); 0 at rest
  headFront: boolean;  // true while frozen — the head is swivelled to face us
}

const CAT_HEIGHT = 1.5;          // metres — ground to the top of the ears
const CAT_ALONG = 105;           // desired spot down the road; rounded up to just past a tree
const CAT_ROAD_GAP = 1.5;        // it sits this far beyond the roadside tree line, facing the road
const PROFILE_REACH = 1.14;      // tail tip — how far the drawing reaches from its anchor (unit-frame x)
const CAT_BEYOND_TREE = 2;       // sits this far PAST the rounding tree, so the tree reads in front of it

// Build a cat at a given SIZE. A beast's size (height in metres) is decoupled from its form (the
// unit-frame skeleton), so the same cat can be a kitten or full-grown — only the height changes.
function cat(along: number, startAcross: number, midAcross: number, endAcross: number, height: number, faceRight: boolean): Beast {
  return { along, startAcross, midAcross, endAcross, height, faceRight, form: CAT };
}

// the smallest right-side tree `along` at or after `desired` — the cat is tucked just past it. Trees
// are NOT evenly spaced (size/scheme nudges some off the line and the count-per-segment stretches the
// stride), so read the segment's actual trees instead of assuming a regular interval.
function nextTreeAlong(desired: number, trees: Tree[]): number {
  let best = Infinity;
  for (const t of trees) if (t.across > 0 && t.along >= desired && t.along < best) best = t.along;
  return Number.isFinite(best) ? best : desired;
}

// The beasts lining a segment: for now one cat that waits beside the road on the RIGHT, just past the
// herd, then crosses to the LEFT as the rider nears.
export function segmentBeasts(laneHalfWidth: number, treeLineOffset: number, trees: Tree[]): Beast[] {
  const treeX = laneHalfWidth + treeLineOffset;
  const start = treeX + CAT_ROAD_GAP;   // waiting spot, beside the road on the right
  // Freeze spot: the head sphere sits at local x HEAD.cx, which maps to an across offset of HEAD.cx *
  // height from the feet anchor — so to put the head CENTRE on the lane centreline, the anchor sits at
  // -HEAD.cx * height.
  const mid = -HEAD.cx * CAT_HEIGHT;
  // The far side: the cat's sprite reaches PROFILE_REACH * height from its anchor (the tail tip), so to
  // be COMPLETELY clear of the road — tail and all — the anchor must sit a full reach (plus the same
  // road gap) past the left edge.
  const end = -(laneHalfWidth + CAT_ROAD_GAP + PROFILE_REACH * CAT_HEIGHT);
  // round the along UP to a tree and sit just beyond it, so a tree stands between the rider and the cat.
  const along = nextTreeAlong(CAT_ALONG, trees) + CAT_BEYOND_TREE;
  return [cat(along, start, mid, end, CAT_HEIGHT, false)];
}

// Wrap a placed beast as Scenery. Like critters, it carries no extra up-close detail yet, so near
// and far are the same draw — a hook for per-distance detail later.
export function beastScenery(view: BeastView): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawBeast(ctx, view, project);
  return { forward: view.at.forward, height: view.height, drawAsNear: draw, drawAsFar: draw };
}

// Forward kinematics: starting at `root` with the first bone pointing at absolute `baseAngle`, each
// joint adds its relative angle and a rigid bone carries on to the next joint. Returns every joint
// position (root first).
function jointsOf(root: P, baseAngle: number, bones: Bone[]): P[] {
  const pts: P[] = [root];
  let angle = baseAngle, x = root[0], y = root[1];
  for (const b of bones) {
    angle += b.joint;
    x += b.length * Math.cos(angle);
    y += b.length * Math.sin(angle);
    pts.push([x, y]);
  }
  return pts;
}

function fillStroke(ctx: Ctx, fill: string, line: string): void {
  ctx.fillStyle = fill; ctx.fill();
  ctx.strokeStyle = line; ctx.stroke();
}

// Lay down (but don't paint) the path of a tapered capsule between joints A and B (half-widths rA,
// rB), with rounded ends.
function capsulePath(ctx: Ctx, A: P, B: P, rA: number, rB: number): void {
  const dx = B[0] - A[0], dy = B[1] - A[1];
  const len = Math.hypot(dx, dy) || 1e-6;
  const ux = dx / len, uy = dy / len;   // along the bone
  const nx = -uy, ny = ux;              // its left normal
  const CAP = 1.33;                     // how far the rounded end bulges past the joint
  ctx.beginPath();
  ctx.moveTo(A[0] + nx * rA, A[1] + ny * rA);
  ctx.lineTo(B[0] + nx * rB, B[1] + ny * rB);
  ctx.quadraticCurveTo(B[0] + ux * rB * CAP, B[1] + uy * rB * CAP, B[0] - nx * rB, B[1] - ny * rB);
  ctx.lineTo(A[0] - nx * rA, A[1] - ny * rA);
  ctx.quadraticCurveTo(A[0] - ux * rA * CAP, A[1] - uy * rA * CAP, A[0] + nx * rA, A[1] + ny * rA);
  ctx.closePath();
}

// a filled + outlined capsule (a rigid limb part; the rounding at a shared joint reads as the joint).
function capsule(ctx: Ctx, A: P, B: P, rA: number, rB: number, fill: string, line: string): void {
  capsulePath(ctx, A, B, rA, rB);
  fillStroke(ctx, fill, line);
}

// The body is just the internal solids drawn directly in the body colour: torso, neck, head and tail
// overlap, so the same fill unions them into one connected shape. We fill them ALL first (so no fill
// paints over another's outline), then stroke them ALL — the only seams that show are where two solids
// meet, which is fine for now. (A smoothed "skin" silhouette over these solids was tried and dropped;
// it flattened the face and rippled the back. Revisit once motion lands.)
function drawBody(ctx: Ctx, fill: string, line: string): void {
  ctx.fillStyle = fill;
  capsulePath(ctx, TORSO_A, TORSO_B, TORSO_R, TORSO_R); ctx.fill();
  capsulePath(ctx, NECK_A, NECK_B, NECK_R, NECK_R); ctx.fill();
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    capsulePath(ctx, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1]); ctx.fill();
  }
  ctx.beginPath(); ctx.arc(HEAD.cx, HEAD.cy, HEAD.r, 0, Math.PI * 2); ctx.fill();

  ctx.strokeStyle = line;
  capsulePath(ctx, TORSO_A, TORSO_B, TORSO_R, TORSO_R); ctx.stroke();
  capsulePath(ctx, NECK_A, NECK_B, NECK_R, NECK_R); ctx.stroke();
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    capsulePath(ctx, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1]); ctx.stroke();
  }
  ctx.beginPath(); ctx.arc(HEAD.cx, HEAD.cy, HEAD.r, 0, Math.PI * 2); ctx.stroke();
}

// Draw the beast in its unit frame (standing height 1, y up, feet at the origin), sized by distance.
function drawBeast(ctx: Ctx, b: BeastView, project: Project): void {
  const base = project(b.at.right, b.at.forward, 0);
  const top = project(b.at.right, b.at.forward, b.height);
  const h = base.y - top.y;
  if (h < 2) return;   // too small to detail; the renderer's size cull is the real cutoff

  ctx.save();
  ctx.translate(base.x, base.y);
  if (b.faceRight) ctx.scale(-1, 1);   // the form faces left; flip to face right
  ctx.scale(h, -h);                    // into the unit profile frame (y up, feet at the origin)
  ctx.lineWidth = LINE_WIDTH;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  if (DEBUG) drawDiagnostic(ctx);
  else drawCat(ctx, b.form.palette, b.walk, b.headFront);

  ctx.restore();
}

// the finished cat: the body is the internal solids drawn directly; legs, ears and face on top. The
// legs run on a DIAGONAL gait — near-front with far-hind (phase `walk`), near-hind with far-front
// (half a cycle on). `headFront` swivels the head to face us (the frozen, deer-in-the-headlights look):
// the sphere is the same from any angle, so only the ears and face features change.
function drawCat(ctx: Ctx, pal: BeastForm['palette'], walk: number, headFront: boolean): void {
  const opp = walk + Math.PI;
  drawLeg(ctx, far(FRONT_HIP), pal.shadow, pal.line, opp);    // far pair, behind the body, in shade
  drawLeg(ctx, far(HIND_HIP), pal.shadow, pal.line, walk);
  if (!headFront) drawEar(ctx, FAR_EAR, pal.shadow, pal.line);   // profile: far ear peeks behind the head
  drawBody(ctx, pal.body, pal.line);                         // head + neck + torso + tail as overlapping solids
  drawLeg(ctx, FRONT_HIP, pal.body, pal.line, walk);         // near pair, over the body
  drawLeg(ctx, HIND_HIP, pal.body, pal.line, opp);
  if (headFront) {                                           // FROZEN: two symmetric ears, a face-on muzzle
    drawEar(ctx, FRONT_EAR_L, pal.body, pal.line);
    drawEar(ctx, FRONT_EAR_R, pal.body, pal.line);
    drawFaceFront(ctx, pal);
  } else {                                                   // PROFILE: one ear on top, one-eye muzzle
    drawEar(ctx, NEAR_EAR, pal.body, pal.line);
    drawFace(ctx, pal.eye, pal.nose);
  }
}

// the diagnostic view: solids as see-through outlines, legs as raw skeleton, the NECK in solid pink.
function drawDiagnostic(ctx: Ctx): void {
  ctx.strokeStyle = GHOST;
  capsulePath(ctx, TORSO_A, TORSO_B, TORSO_R, TORSO_R); ctx.stroke();   // torso outline
  ctx.beginPath(); ctx.ellipse(HEAD.cx, HEAD.cy, HEAD.r, HEAD.r, 0, 0, Math.PI * 2); ctx.stroke();   // head
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    capsulePath(ctx, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1]); ctx.stroke();
  }
  for (const e of [NEAR_EAR, FAR_EAR]) {
    ctx.beginPath(); ctx.moveTo(e.a[0], e.a[1]); ctx.lineTo(e.tip[0], e.tip[1]); ctx.lineTo(e.b[0], e.b[1]); ctx.closePath(); ctx.stroke();
  }

  legSkeleton(ctx, far(FRONT_HIP));
  legSkeleton(ctx, far(HIND_HIP));
  legSkeleton(ctx, FRONT_HIP);
  legSkeleton(ctx, HIND_HIP);

  capsulePath(ctx, NECK_A, NECK_B, NECK_R, NECK_R);   // the NECK, solid pink — the thing to look at
  ctx.fillStyle = NECK_FILL; ctx.fill();
  ctx.strokeStyle = NECK_EDGE; ctx.stroke();
}

// the raw skeleton of one leg: bones as a polyline, joints as dots.
function legSkeleton(ctx: Ctx, hip: P): void {
  const j = jointsOf(hip, LEG_BASE_ANGLE, [UPPER_LEG, LOWER_LEG, PAW]);
  ctx.strokeStyle = BONE;
  ctx.beginPath();
  ctx.moveTo(j[0][0], j[0][1]);
  for (let i = 1; i < j.length; i++) ctx.lineTo(j[i][0], j[i][1]);
  ctx.stroke();
  ctx.fillStyle = JOINT;
  for (const p of j) { ctx.beginPath(); ctx.arc(p[0], p[1], 0.018, 0, Math.PI * 2); ctx.fill(); }
}

const far = (hip: P): P => [hip[0] + FAR_SETBACK, hip[1]];

// one leg: upper leg, lower leg, paw — three capsules along the FK chain from the hip. The gait
// `phase` swings the thigh fore-aft and bends the knee on the forward (lift) half, so the leg steps.
function drawLeg(ctx: Ctx, hip: P, fill: string, line: string, phase: number): void {
  const s = Math.sin(phase);
  const base = LEG_BASE_ANGLE + SWING_AMP * s;                       // thigh swings fore/aft
  const lower = { ...LOWER_LEG, joint: LOWER_LEG.joint + KNEE_AMP * Math.max(0, s) };   // bend the knee as it lifts
  const j = jointsOf(hip, base, [UPPER_LEG, lower, PAW]);
  capsule(ctx, j[0], j[1], UPPER_LEG.r0, UPPER_LEG.r1, fill, line);
  capsule(ctx, j[1], j[2], lower.r0, lower.r1, fill, line);
  capsule(ctx, j[2], j[3], PAW.r0, PAW.r1, fill, line);
}

function drawEar(ctx: Ctx, e: { a: P; tip: P; b: P }, fill: string, line: string): void {
  ctx.beginPath();
  ctx.moveTo(e.a[0], e.a[1]);
  ctx.lineTo(e.tip[0], e.tip[1]);
  ctx.lineTo(e.b[0], e.b[1]);
  ctx.closePath();
  fillStroke(ctx, fill, line);
}

function drawFace(ctx: Ctx, eye: string, nose: string): void {
  ctx.fillStyle = eye;
  ctx.beginPath();
  ctx.arc(HEAD.eye[0], HEAD.eye[1], 0.024, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = nose;
  ctx.beginPath();
  ctx.arc(HEAD.nose[0], HEAD.nose[1], 0.018, 0, Math.PI * 2);
  ctx.fill();
}

// the FRONT-ON muzzle, shown during the freeze: two eyes, a centred nose, a little mouth, and whiskers
// — all laid out symmetrically about the head centre (cx, cy).
function drawFaceFront(ctx: Ctx, pal: BeastForm['palette']): void {
  const cx = HEAD.cx, cy = HEAD.cy;

  ctx.fillStyle = pal.eye;                                   // two eyes, level, either side of centre
  for (const ex of [cx - 0.07, cx + 0.07]) {
    ctx.beginPath();
    ctx.arc(ex, cy + 0.03, 0.028, 0, Math.PI * 2);
    ctx.fill();
  }

  ctx.fillStyle = pal.nose;                                  // nose — a small inverted triangle, centred
  ctx.beginPath();
  ctx.moveTo(cx - 0.025, cy - 0.03);
  ctx.lineTo(cx + 0.025, cy - 0.03);
  ctx.lineTo(cx, cy - 0.065);
  ctx.closePath();
  ctx.fill();

  ctx.strokeStyle = pal.line;                                // mouth — down from the nose, then a curl each way
  ctx.beginPath();
  ctx.moveTo(cx, cy - 0.065);
  ctx.lineTo(cx, cy - 0.10);
  ctx.quadraticCurveTo(cx - 0.03, cy - 0.10, cx - 0.055, cy - 0.07);
  ctx.moveTo(cx, cy - 0.10);
  ctx.quadraticCurveTo(cx + 0.03, cy - 0.10, cx + 0.055, cy - 0.07);
  ctx.stroke();

  ctx.beginPath();                                           // whiskers — three a side, fanning from the muzzle
  for (let i = 0; i < 3; i++) {
    const dy = (i - 1) * 0.028;
    ctx.moveTo(cx - 0.03, cy - 0.05 + dy * 0.3);
    ctx.lineTo(cx - 0.24, cy - 0.05 + dy);
    ctx.moveTo(cx + 0.03, cy - 0.05 + dy * 0.3);
    ctx.lineTo(cx + 0.24, cy - 0.05 + dy);
  }
  ctx.stroke();
}
