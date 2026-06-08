// beast.ts — a hand-drawn cartoon BEAST in profile (no emoji), modelled as an ARTICULATED SKELETON.
//
// The LIMBS are rigid PARTS with permanent shapes — for each leg: an upper leg, a lower leg, a paw —
// joined by JOINTS (the knee, the ankle) that have no size of their own; they are just pivots, and a
// POSE is the set of joint ANGLES. Forward kinematics walks the chain, so the leg bends at real
// joints and a gait would be just a change of angles, nothing redraws. The joints are the ONLY hard
// angles on the animal.
//
// The BODY (neck + back) is the opposite: one continuous shape whose outline is a single SMOOTH
// closed curve (a Catmull-Rom loop through the silhouette points), so there are no kinks anywhere.
// The head, ears, tail and legs are drawn over/under it.
//
// This beast is a CAT standing in profile: a torso roughly parallel to the ground, four near-vertical
// legs (a slight bend at the knee puts each foot just behind its knee), a head carried forward on a
// short neck, and a long tail off the rump. Everything lives in a frame where the beast stands 1 unit
// tall (feet on y = 0, top of the ears at 1), facing LEFT, x running toward the tail.

import type { Project, Ctx, Scenery } from './scenery.ts';

// a point in the beast's profile frame: x toward the tail (right), y up, feet at the origin.
type P = readonly [number, number];

// a rigid bone: its permanent length, the RELATIVE angle (radians) of the joint at its proximal end,
// and the taper of its flesh (radius at the proximal end r0, at the distal end r1).
interface Bone { length: number; joint: number; r0: number; r1: number }

// For now a species is just its palette; the skeleton below is the cat's. A second beast will lift
// the skeleton numbers into this form (same anatomy, different proportions).
interface BeastForm {
  palette: { body: string; belly: string; shadow: string; line: string; eye: string; nose: string };
}

const CAT: BeastForm = {
  // a ginger cat: warm body, cream belly; shadow is the darker tone for the FAR pair of legs.
  palette: { body: '#c8823c', belly: '#efe0c6', shadow: '#8a571f', line: '#3a2a17', eye: '#15100a', nose: '#b56b6b' },
};

// ---- the cat skeleton ----

// one leg: upper leg down (and slightly forward), then the knee bends the lower leg down-and-BACK so
// the foot sits behind the knee, then a small forward paw. All four legs share this shape; they
// differ only in where they attach. (joint angles are rest-pose, radians.)
const LEG_BASE_ANGLE = -1.745;                                // upper leg: down, a touch forward
const UPPER_LEG: Bone = { length: 0.24, joint: 0,      r0: 0.050, r1: 0.040 };
const LOWER_LEG: Bone = { length: 0.21, joint: 0.620,  r0: 0.040, r1: 0.032 };
const PAW:       Bone = { length: 0.05, joint: -1.571, r0: 0.034, r1: 0.030 };

// where the legs attach to the torso (near pair, in front; far pair set back a touch and drawn in
// shade behind the body, so all four legs read).
const FRONT_HIP: P = [-0.16, 0.46];
const HIND_HIP: P = [0.52, 0.46];
const FAR_SETBACK = 0.06;   // the far leg of each pair sits this much further toward the tail

// the body outline (neck + back + belly) as ONE closed smooth loop, clockwise from the top of the
// neck: over the back to the rump, around to under the belly, and up the chest and front of the neck.
const BODY: P[] = [
  [-0.28, 0.70],   // top of the neck (the head sits forward of and above here)
  [-0.10, 0.655],  // withers
  [0.18, 0.645],   // back
  [0.44, 0.645],   // back
  [0.64, 0.625],   // rump
  [0.74, 0.50],    // rump-back / tail base
  [0.67, 0.41],    // under the rump
  [0.40, 0.40],    // belly
  [0.10, 0.40],    // belly
  [-0.16, 0.42],   // brisket (lower chest)
  [-0.28, 0.57],   // throat (front of the neck)
];

// the head: a roundish ellipse carried forward of the neck, with the eye and the nose at the front.
const HEAD = {
  cx: -0.45, cy: 0.74, rx: 0.15, ry: 0.135,
  eye: [-0.50, 0.78], nose: [-0.59, 0.71],
} as const;

// two triangular ears on top of the head (front one forward of the back one).
const EAR_FRONT = { a: [-0.55, 0.83], tip: [-0.57, 1.00], b: [-0.45, 0.85] } as const;
const EAR_BACK = { a: [-0.43, 0.85], tip: [-0.37, 1.00], b: [-0.31, 0.82] } as const;

// the long tail off the rump, sweeping back and curling up at the tip — capsules between the nodes.
const TAIL_NODES: P[] = [[0.72, 0.52], [0.94, 0.50], [1.08, 0.58], [1.14, 0.73]];
const TAIL_RADII = [0.060, 0.050, 0.038, 0.022];

const LINE_WIDTH = 0.012;   // outline weight, in standing-height units (scales with distance)

// A beast in its SEGMENT's frame, like a Critter: along/across placement, world height, facing.
export interface Beast {
  along: number;
  across: number;
  height: number;      // standing height, metres
  faceRight: boolean;
  form: BeastForm;
}

// A beast placed in the scene, measured FROM THE RIDER and ready to draw.
export interface BeastView {
  at: { right: number; forward: number };
  height: number;
  faceRight: boolean;
  form: BeastForm;
}

const CAT_HEIGHT = 2.8;          // metres — a big SAFARI-sized cat, ground to the top of the ears
const CAT_ALONG = 65;            // just past the cow herd (which ends ~55)
const CAT_ROAD_GAP = 1.5;        // it sits this far beyond the roadside tree line, facing the road

// Build a cat at a given SIZE. A beast's size (height in metres) is decoupled from its form (the
// unit-frame skeleton), so the same cat can be a kitten or full-grown — only the height changes, and
// drawBeast scales the whole profile to it.
function cat(along: number, across: number, height: number, faceRight: boolean): Beast {
  return { along, across, height, faceRight, form: CAT };
}

// The beasts lining a segment: for now one cat on the RIGHT, just past the herd, facing the road.
// `treeLineOffset` is how far the roadside trees sit beyond the lane edge; the cat sits just past them.
export function segmentBeasts(laneHalfWidth: number, treeLineOffset: number): Beast[] {
  const treeX = laneHalfWidth + treeLineOffset;
  return [cat(CAT_ALONG, treeX + CAT_ROAD_GAP, CAT_HEIGHT, false)];
}

// Wrap a placed beast as Scenery. Like critters, it carries no extra up-close detail yet, so near
// and far are the same draw — a hook for per-distance detail later.
export function beastScenery(view: BeastView): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawBeast(ctx, view, project);
  return { forward: view.at.forward, height: view.height, drawAsNear: draw, drawAsFar: draw };
}

// Forward kinematics: starting at `root` with the first bone pointing at absolute `baseAngle`, each
// joint adds its relative angle and a rigid bone carries on to the next joint. Returns every joint
// position (root first), so a limb's outline can be drawn between them.
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

// Trace a CLOSED smooth curve through pts (a Catmull-Rom spline rendered as cubic Béziers, wrapping
// around). EVERY point is interior — its tangent comes from its neighbours on both sides — so the
// whole loop is smooth, with no kink anywhere, including where the last point rejoins the first.
function smoothLoop(ctx: Ctx, pts: P[]): void {
  const n = pts.length;
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n];
    const p1 = pts[i];
    const p2 = pts[(i + 1) % n];
    const p3 = pts[(i + 2) % n];
    const c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
    const c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
    ctx.bezierCurveTo(c1x, c1y, c2x, c2y, p2[0], p2[1]);
  }
  ctx.closePath();
}

// Draw one rigid bone as a tapered capsule between joints A and B (half-widths rA, rB), with rounded
// ends — the rounding at a shared joint is what reads as the joint (a knee, an ankle).
function capsule(ctx: Ctx, A: P, B: P, rA: number, rB: number, fill: string, line: string): void {
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
  fillStroke(ctx, fill, line);
}

// Draw the beast in its unit frame (standing height 1, y up, feet at the origin), sized by distance.
// Back-to-front: the far pair of legs, the tail, the body, the near pair of legs, then the head.
function drawBeast(ctx: Ctx, b: BeastView, project: Project): void {
  const base = project(b.at.right, b.at.forward, 0);
  const top = project(b.at.right, b.at.forward, b.height);
  const h = base.y - top.y;
  if (h < 2) return;   // too small to detail; the renderer's size cull is the real cutoff

  const pal = b.form.palette;
  ctx.save();
  ctx.translate(base.x, base.y);
  if (b.faceRight) ctx.scale(-1, 1);   // the form faces left; flip to face right
  ctx.scale(h, -h);                    // into the unit profile frame (y up, feet at the origin)
  ctx.lineWidth = LINE_WIDTH;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  const farFront: P = [FRONT_HIP[0] + FAR_SETBACK, FRONT_HIP[1]];
  const farHind: P = [HIND_HIP[0] + FAR_SETBACK, HIND_HIP[1]];

  drawLeg(ctx, farFront, pal.shadow, pal.line);   // far pair, behind the body, in shade
  drawLeg(ctx, farHind, pal.shadow, pal.line);
  drawTail(ctx, pal.body, pal.line);              // tail, off the rump
  drawBody(ctx, pal.body, pal.line);              // neck + back, one smooth shape
  drawBelly(ctx, pal.belly);                      // lighter underside, over the body
  drawLeg(ctx, FRONT_HIP, pal.body, pal.line);    // near pair, over the body
  drawLeg(ctx, HIND_HIP, pal.body, pal.line);
  drawHead(ctx, pal.body, pal.line);              // over the front of the neck
  drawEars(ctx, pal.body, pal.line);
  drawFace(ctx, pal.eye, pal.nose);

  ctx.restore();
}

// one leg: upper leg, lower leg, paw — three capsules along the FK chain from the hip.
function drawLeg(ctx: Ctx, hip: P, fill: string, line: string): void {
  const j = jointsOf(hip, LEG_BASE_ANGLE, [UPPER_LEG, LOWER_LEG, PAW]);
  capsule(ctx, j[0], j[1], UPPER_LEG.r0, UPPER_LEG.r1, fill, line);
  capsule(ctx, j[1], j[2], LOWER_LEG.r0, LOWER_LEG.r1, fill, line);
  capsule(ctx, j[2], j[3], PAW.r0, PAW.r1, fill, line);
}

function drawTail(ctx: Ctx, fill: string, line: string): void {
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    capsule(ctx, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1], fill, line);
  }
}

function drawBody(ctx: Ctx, fill: string, line: string): void {
  ctx.beginPath();
  smoothLoop(ctx, BODY);
  fillStroke(ctx, fill, line);
}

// the lighter underside, drawn over the brown body (no outline, soft boundary) — the two-tone that
// makes the form read as volume rather than a flat silhouette.
function drawBelly(ctx: Ctx, fill: string): void {
  ctx.beginPath();
  ctx.moveTo(-0.15, 0.43);
  ctx.quadraticCurveTo(0.10, 0.39, 0.40, 0.40);    // along the belly bottom
  ctx.quadraticCurveTo(0.55, 0.42, 0.67, 0.43);    // to under the rump
  ctx.quadraticCurveTo(0.40, 0.47, 0.05, 0.47);    // back, rising a touch into the body
  ctx.quadraticCurveTo(-0.12, 0.47, -0.15, 0.43);  // up the chest
  ctx.closePath();
  ctx.fillStyle = fill; ctx.fill();
}

function drawHead(ctx: Ctx, fill: string, line: string): void {
  ctx.beginPath();
  ctx.ellipse(HEAD.cx, HEAD.cy, HEAD.rx, HEAD.ry, 0, 0, Math.PI * 2);
  fillStroke(ctx, fill, line);
}

function drawEars(ctx: Ctx, fill: string, line: string): void {
  for (const e of [EAR_FRONT, EAR_BACK]) {
    ctx.beginPath();
    ctx.moveTo(e.a[0], e.a[1]);
    ctx.lineTo(e.tip[0], e.tip[1]);
    ctx.lineTo(e.b[0], e.b[1]);
    ctx.closePath();
    fillStroke(ctx, fill, line);
  }
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
