// cat_anatomy.ts — how to draw a cartoon cat in profile (no emoji). The body is a set of overlapping
// solids (torso/neck/tail capsules + a head sphere) filled in one colour; four articulated legs are
// posed by a gait phase; the head is drawn either in PROFILE (one eye) or HEAD-ON (two eyes, muzzle,
// whiskers). Everything lives in a unit frame: the cat stands 1 tall (feet on y = 0, ear tips at 1),
// faces LEFT, x toward the tail. Where the cat IS and how it crosses the road lives in cat_motion.ts;
// this module only knows shapes. DEBUG swaps in a diagnostic view (pink neck, ghost solids, skeletons).

import type { Project, Ctx, Scenery } from './scenery.ts';

// ---- types ----

// a point in the cat's profile frame: x toward the tail (right), y up, feet at the origin.
type P = readonly [number, number];

// a rigid bone: permanent length, the RELATIVE angle (radians) of the joint at its proximal end, and
// the taper of its flesh (radius r0 proximal, r1 distal).
interface Bone { length: number; joint: number; r0: number; r1: number }

// a cat's look — just a palette for now.
export interface CatForm {
  palette: { body: string; shadow: string; line: string; eye: string; nose: string };
}

// a placed cat measured FROM THE RIDER, ready to draw, with its current pose (gait + head facing).
export interface CatView {
  at: { right: number; forward: number };
  height: number;
  faceRight: boolean;
  form: CatForm;
  walk: number;        // gait phase (radians); 0 at rest
  headFront: boolean;  // true while frozen — head swivelled to face us
}

// ---- constants ----

const DEBUG = false;

export const CAT: CatForm = {
  palette: { body: '#c8823c', shadow: '#8a571f', line: '#3a2a17', eye: '#15100a', nose: '#b56b6b' },
};

// body solids (unit frame): torso and neck are capsules (two endpoints + a radius); the head is a sphere.
const TORSO_SHOULDER: P = [-0.14, 0.55];
const TORSO_RUMP: P = [0.66, 0.55];
const TORSO_RADIUS = 0.13;
const NECK_BASE: P = [-0.178, 0.608];
const NECK_TOP: P = [-0.382, 0.693];
const NECK_RADIUS = 0.102;
const HEAD = { cx: -0.48, cy: 0.76, r: 0.16, eye: [-0.53, 0.80], nose: [-0.63, 0.74] } as const;

// silhouette facts cat_motion uses to place the cat: head-centre x (to centre the head on the lane)
// and the tail-tip reach (to clear the road by a full tail length).
export const CAT_HEAD_X = HEAD.cx;
export const CAT_TAIL_REACH = 1.14;

// one leg, rest pose: thigh down-and-slightly-forward, then the knee bends the shank down-and-back so
// the foot sits behind the knee, then a small forward paw. All four share this shape.
const LEG_BASE_ANGLE = -1.745;
const UPPER_LEG: Bone = { length: 0.24, joint: 0,      r0: 0.050, r1: 0.040 };
const LOWER_LEG: Bone = { length: 0.21, joint: 0.620,  r0: 0.040, r1: 0.032 };
const PAW:       Bone = { length: 0.05, joint: -1.571, r0: 0.034, r1: 0.030 };

// where the legs attach; the far leg of each pair sits a touch toward the tail and is drawn in shade.
const FRONT_HIP: P = [-0.10, 0.46];
const HIND_HIP: P = [0.58, 0.46];
const FAR_LEG_SETBACK = 0.06;

// gait flex: the thigh swings fore-aft, the knee bends on the forward (lift) half of the swing.
const THIGH_SWING_AMP = 0.40;
const KNEE_LIFT_AMP = 0.55;

// ears — profile pair (near on top, far peeking behind) and the front-on pair (symmetric atop the head).
const NEAR_EAR = { a: [-0.53, 0.84], tip: [-0.53, 1.04], b: [-0.43, 0.87] } as const;
const FAR_EAR = { a: [-0.45, 0.86], tip: [-0.43, 1.00], b: [-0.35, 0.85] } as const;
const FRONT_EAR_L = { a: [HEAD.cx - 0.15, 0.86], tip: [HEAD.cx - 0.10, 1.03], b: [HEAD.cx - 0.02, 0.88] } as const;
const FRONT_EAR_R = { a: [HEAD.cx + 0.02, 0.88], tip: [HEAD.cx + 0.10, 1.03], b: [HEAD.cx + 0.15, 0.86] } as const;

// tail — capsules between these nodes, tapering by these radii.
const TAIL_NODES: P[] = [[0.72, 0.52], [0.94, 0.50], [1.08, 0.58], [1.14, 0.73]];
const TAIL_RADII = [0.060, 0.050, 0.038, 0.022];

const LINE_WIDTH = 0.012;   // outline weight, in standing-height units (scales with distance)

// diagnostic-view colours
const GHOST_OUTLINE = '#7fa8c9';
const SKELETON_BONE = '#1f4fd8';
const SKELETON_JOINT = '#e03b3b';
const NECK_FILL = '#ff5fa6';
const NECK_EDGE = '#d23f80';

// ---- functions ----

// Wrap a placed cat as Scenery. No up-close detail yet, so near and far are the same draw.
export function catScenery(view: CatView): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawCat(ctx, view, project);
  return { forward: view.at.forward, height: view.height, drawAsNear: draw, drawAsFar: draw };
}

// Forward kinematics: starting at `root` with the first bone pointing at absolute `baseAngle`, each
// joint adds its relative angle and a rigid bone carries on. Returns every joint position (root first).
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

// Lay down (but don't paint) the path of a tapered capsule between A and B (half-widths rA, rB), with
// rounded ends.
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

// The body is the internal solids drawn directly in the body colour: torso, neck, head and tail
// overlap, so the same fill unions them into one connected shape. Fill them ALL first (so no fill
// paints over another's outline), then stroke them ALL — the only seams that show are where two
// solids meet, which is fine.
function drawBody(ctx: Ctx, fill: string, line: string): void {
  ctx.fillStyle = fill;
  capsulePath(ctx, TORSO_SHOULDER, TORSO_RUMP, TORSO_RADIUS, TORSO_RADIUS); ctx.fill();
  capsulePath(ctx, NECK_BASE, NECK_TOP, NECK_RADIUS, NECK_RADIUS); ctx.fill();
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    capsulePath(ctx, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1]); ctx.fill();
  }
  ctx.beginPath(); ctx.arc(HEAD.cx, HEAD.cy, HEAD.r, 0, Math.PI * 2); ctx.fill();

  ctx.strokeStyle = line;
  capsulePath(ctx, TORSO_SHOULDER, TORSO_RUMP, TORSO_RADIUS, TORSO_RADIUS); ctx.stroke();
  capsulePath(ctx, NECK_BASE, NECK_TOP, NECK_RADIUS, NECK_RADIUS); ctx.stroke();
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    capsulePath(ctx, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1]); ctx.stroke();
  }
  ctx.beginPath(); ctx.arc(HEAD.cx, HEAD.cy, HEAD.r, 0, Math.PI * 2); ctx.stroke();
}

// Draw the cat in its unit frame (standing height 1, y up, feet at the origin), sized by distance.
function drawCat(ctx: Ctx, c: CatView, project: Project): void {
  const base = project(c.at.right, c.at.forward, 0);
  const top = project(c.at.right, c.at.forward, c.height);
  const h = base.y - top.y;
  if (h < 2) return;   // too small to detail; the renderer's size cull is the real cutoff

  ctx.save();
  ctx.translate(base.x, base.y);
  if (c.faceRight) ctx.scale(-1, 1);   // the form faces left; flip to face right
  ctx.scale(h, -h);                    // into the unit profile frame (y up, feet at the origin)
  ctx.lineWidth = LINE_WIDTH;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  if (DEBUG) drawDiagnostic(ctx);
  else paintCat(ctx, c.form.palette, c.walk, c.headFront);

  ctx.restore();
}

// paint the cat's parts: body solids, then legs/ears/face on top. The legs run a DIAGONAL gait —
// near-front with far-hind (phase `walk`), near-hind with far-front (half a cycle on). `headFront`
// swivels the head to face us (the frozen look): the sphere is the same from any angle, so only the
// ears and face change.
function paintCat(ctx: Ctx, pal: CatForm['palette'], walk: number, headFront: boolean): void {
  const opp = walk + Math.PI;
  drawLeg(ctx, far(FRONT_HIP), pal.shadow, pal.line, opp);    // far pair, behind the body, in shade
  drawLeg(ctx, far(HIND_HIP), pal.shadow, pal.line, walk);
  if (!headFront) drawEar(ctx, FAR_EAR, pal.shadow, pal.line);   // profile: far ear peeks behind the head
  drawBody(ctx, pal.body, pal.line);
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

// the diagnostic view: solids as see-through outlines, legs as raw skeletons, the NECK in solid pink.
function drawDiagnostic(ctx: Ctx): void {
  ctx.strokeStyle = GHOST_OUTLINE;
  capsulePath(ctx, TORSO_SHOULDER, TORSO_RUMP, TORSO_RADIUS, TORSO_RADIUS); ctx.stroke();
  ctx.beginPath(); ctx.ellipse(HEAD.cx, HEAD.cy, HEAD.r, HEAD.r, 0, 0, Math.PI * 2); ctx.stroke();
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

  capsulePath(ctx, NECK_BASE, NECK_TOP, NECK_RADIUS, NECK_RADIUS);   // the NECK, solid pink — the thing to look at
  ctx.fillStyle = NECK_FILL; ctx.fill();
  ctx.strokeStyle = NECK_EDGE; ctx.stroke();
}

// the raw skeleton of one leg: bones as a polyline, joints as dots.
function legSkeleton(ctx: Ctx, hip: P): void {
  const j = jointsOf(hip, LEG_BASE_ANGLE, [UPPER_LEG, LOWER_LEG, PAW]);
  ctx.strokeStyle = SKELETON_BONE;
  ctx.beginPath();
  ctx.moveTo(j[0][0], j[0][1]);
  for (let i = 1; i < j.length; i++) ctx.lineTo(j[i][0], j[i][1]);
  ctx.stroke();
  ctx.fillStyle = SKELETON_JOINT;
  for (const p of j) { ctx.beginPath(); ctx.arc(p[0], p[1], 0.018, 0, Math.PI * 2); ctx.fill(); }
}

const far = (hip: P): P => [hip[0] + FAR_LEG_SETBACK, hip[1]];

// one leg: upper leg, lower leg, paw — three capsules along the FK chain from the hip. The gait `phase`
// swings the thigh fore-aft and bends the knee on the forward (lift) half, so the leg steps.
function drawLeg(ctx: Ctx, hip: P, fill: string, line: string, phase: number): void {
  const s = Math.sin(phase);
  const base = LEG_BASE_ANGLE + THIGH_SWING_AMP * s;
  const lower = { ...LOWER_LEG, joint: LOWER_LEG.joint + KNEE_LIFT_AMP * Math.max(0, s) };
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

// the PROFILE muzzle: one eye and the nose, seen side-on.
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

// the HEAD-ON muzzle (shown frozen): two eyes, a centred nose, a little mouth, and whiskers — all laid
// out symmetrically about the head centre (cx, cy).
function drawFaceFront(ctx: Ctx, pal: CatForm['palette']): void {
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
