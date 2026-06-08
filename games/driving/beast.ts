// beast.ts — a hand-drawn cartoon BEAST in profile (no emoji), modelled as an ARTICULATED SKELETON.
//
// The LIMBS are rigid PARTS with permanent shapes — for the leg: an upper leg, a lower leg, a foot —
// joined by JOINTS (hip, knee, ankle) that have no size of their own; they are just pivots, and a
// POSE is the set of joint ANGLES. Forward kinematics walks the chain, so the limb bends at real
// joints and a hop is just a change of angles, nothing redraws. The joints are the ONLY hard angles
// on the animal.
//
// The BODY (neck + back + tail) is the opposite: one continuous shape whose top edge is a single
// SMOOTH curve (a Catmull-Rom spline through the dorsal points), so the line from the back of the
// head, down the back, to the tip of the tail has no kinks — it tapers into the tail as part of the
// same shape. The head, ears and limbs are drawn over it.
//
// Everything lives in a frame where the beast stands 1 unit tall, feet on y = 0, facing LEFT, x
// running toward the tail. The kangaroo is the first study; future beasts reuse this with new numbers.

import type { Project, Ctx, Scenery } from './scenery.ts';

// a point in the beast's profile frame: x toward the tail (right), y up, feet at the origin.
type P = readonly [number, number];

// a rigid bone: its permanent length, the RELATIVE angle (radians) of the joint at its proximal end,
// and the taper of its flesh (radius at the proximal end r0, at the distal end r1).
interface Bone { length: number; joint: number; r0: number; r1: number }

// For now a species is just its palette; the skeleton below is the kangaroo's. A second beast will
// lift the skeleton numbers into this form (same anatomy, different proportions).
interface BeastForm {
  palette: { body: string; belly: string; limb: string; shadow: string; line: string; eye: string };
}

const KANGAROO: BeastForm = {
  // two-tone, like the emoji: brown on the back/outer, cream belly on the underside and inner limbs;
  // shadow is the darker tone for the far-side leg (in shade behind the body).
  palette: { body: '#b27a44', belly: '#e6cda6', limb: '#a06f3c', shadow: '#82592f', line: '#3b2a17', eye: '#15100a' },
};

// ---- the kangaroo skeleton ----

// hind leg: the Z. A big, long, thick THIGH (the haunch) points down-and-forward from the hip; a
// short, slender SHIN bends back down to the ankle; the ankle lays the long FOOT out flat. Lengths
// and thicknesses read from the emoji's shading (thigh > foot > shin). (joint angles are rest-pose.)
const HIP: P = [0.24, 0.48];                                  // set back, at the end of the long torso
const LEG_BASE_ANGLE = -2.467;                                // absolute direction of the thigh
const THIGH: Bone = { length: 0.384, joint: 0,      r0: 0.130, r1: 0.050 };
const SHIN:  Bone = { length: 0.194, joint: 1.499,  r0: 0.048, r1: 0.030 };
const FOOT:  Bone = { length: 0.316, joint: -1.981, r0: 0.032, r1: 0.013 };

// the fore-arm, bent at the elbow and hanging in front of the chest. Its lower segment (the fore-arm)
// is nearly as long as the hind leg's shin, as in the cartoon — the forelimb isn't tiny.
const ARM_SHOULDER: P = [-0.12, 0.56];                 // up at the base of the neck, near the head
const ARM_BASE_ANGLE = -1.990;
const UPPER_ARM: Bone = { length: 0.100, joint: 0,     r0: 0.035, r1: 0.027 };
const FORE_ARM:  Bone = { length: 0.165, joint: 0.174, r0: 0.027, r1: 0.016 };

// ---- the body as one smooth shape ----
// The DORSAL line (top), from the top of the neck down the back to the tail tip: back-of-top-neck,
// back-of-lower-neck, withers, back, rump, then the three tail sections. The dorsal and ventral
// lists are joined into ONE closed Catmull-Rom loop (drawBody), so the whole silhouette is smooth —
// no kink down the neck, across the back, or where the neck-top closes.
const DORSAL: P[] = [
  [-0.11, 0.78],   // top of the neck, back (the head sits forward of and above here)
  [-0.02, 0.66],   // nape — the back of the neck, leaning forward
  [0.13, 0.575],   // withers — base of the neck, where it widens into the shoulders
  [0.30, 0.58],    // top of the back
  [0.48, 0.50],    // rump
  [0.66, 0.31],    // top of the upper tail
  [0.84, 0.13],    // top of the middle tail
  [1.01, 0.01],    // tail tip (tail ~10% longer)
];
// The VENTRAL line (bottom), from the tail tip back up to the top of the neck: tail underside, under
// the rump, belly, chest, throat, and on up the FRONT of the neck. Shares the tip with the dorsal
// line; the loop closes smoothly across the top of the neck, and the head ellipse sits on the front
// of it. Carrying the neck-front through the same smooth loop is what gives a real, kink-free neck.
const VENTRAL: P[] = [
  [1.01, 0.01],    // tail tip (shared)
  [0.87, 0.06],    // middle tail underside
  [0.68, 0.21],    // upper tail underside (dropped a touch — thicker through the middle)
  [0.46, 0.37],    // under the rump
  [0.18, 0.31],    // belly
  [-0.04, 0.40],   // lower chest
  [-0.14, 0.57],   // throat — base of the neck, front
  [-0.19, 0.74],   // up the front of the neck to its top (it narrows toward the head)
];

// the head: a long ellipse lying parallel to the ground (snout to the left), thinner than the neck it
// sits on. cx/cy centre it; rx is the long (horizontal) radius, ry the short (vertical) one.
const HEAD = {
  cx: -0.30, cy: 0.80, rx: 0.16, ry: 0.075,
  eye: [-0.33, 0.83], nostril: [-0.45, 0.805],
} as const;

// two upright ears rising from the top-back of the head, the front one a touch ahead of the back one.
const EAR_BACK = { base: [-0.18, 0.85], tip: [-0.11, 1.01], r0: 0.033, r1: 0.010 } as const;
const EAR_FRONT = { base: [-0.26, 0.86], tip: [-0.29, 1.03], r0: 0.036, r1: 0.012 } as const;

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

const KANGAROO_ADULT_HEIGHT = 2.7;   // metres — a big cartoon kangaroo (adult size)
const KANGAROO_ALONG = 65;           // just past the cow herd (which ends ~55), leaving road to hop across later
const KANGAROO_ROAD_GAP = 1.5;       // it stands this far beyond the roadside tree line, facing the road

// Build a kangaroo at a given SIZE. A beast's size (height in metres) is decoupled from its form (the
// unit-frame skeleton), so the same kangaroo can stand as a baby, an adult, or a giant — only the
// height changes, and drawBeast scales the whole profile to it.
function kangaroo(along: number, across: number, height: number, faceRight: boolean): Beast {
  return { along, across, height, faceRight, form: KANGAROO };
}

// The beasts lining a segment: for now one adult kangaroo on the RIGHT (opposite the herd, which
// leads on the left), parked just past the herd and facing the road. `treeLineOffset` is how far the
// roadside trees sit beyond the lane edge; the kangaroo stands just past them.
export function segmentBeasts(laneHalfWidth: number, treeLineOffset: number): Beast[] {
  const treeX = laneHalfWidth + treeLineOffset;
  return [kangaroo(KANGAROO_ALONG, treeX + KANGAROO_ROAD_GAP, KANGAROO_ADULT_HEIGHT, false)];
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
// Parts are drawn back-to-front: the far leg, then the body (neck + back + tail as one smooth shape),
// the near limbs over it, and finally the head.
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

  const leg = jointsOf(HIP, LEG_BASE_ANGLE, [THIGH, SHIN, FOOT]);          // [hip, knee, ankle, toe]
  const arm = jointsOf(ARM_SHOULDER, ARM_BASE_ANGLE, [UPPER_ARM, FORE_ARM]); // [shoulder, elbow, paw]

  drawFarLeg(ctx, pal.shadow, pal.line);     // far hind leg, behind everything, set back
  drawBody(ctx, pal.body, pal.line);         // neck + back + tail, one smooth shape
  capsule(ctx, leg[0], leg[1], THIGH.r0, THIGH.r1, pal.limb, pal.line);   // upper leg (the haunch)
  drawBelly(ctx, pal.belly);                                              // cream belly + thigh-front, over the body
  capsule(ctx, leg[1], leg[2], SHIN.r0, SHIN.r1, pal.belly, pal.line);    // lower leg (cream inner)
  capsule(ctx, leg[2], leg[3], FOOT.r0, FOOT.r1, pal.belly, pal.line);    // foot (cream)
  drawToes(ctx, pal.line);                                                // dark toe-claws at the foot tip
  capsule(ctx, arm[0], arm[1], UPPER_ARM.r0, UPPER_ARM.r1, pal.limb, pal.line);
  capsule(ctx, arm[1], arm[2], FORE_ARM.r0, FORE_ARM.r1, pal.limb, pal.line);
  drawPaw(ctx, pal.line);                                                 // dark paw at the arm's end
  drawHead(ctx, pal.body, pal.line);         // over the neck opening at the front
  drawEars(ctx, pal.body, pal.line);
  drawFace(ctx, pal.eye);

  ctx.restore();
}

// the body: neck + back + tail as one shape — a smooth dorsal curve out to the tail tip, then a
// smooth ventral curve back to the throat, closed across the neck (the head hides that edge).
function drawBody(ctx: Ctx, fill: string, line: string): void {
  const loop = [...DORSAL, ...VENTRAL.slice(1)];   // one silhouette, sharing the tail tip
  ctx.beginPath();
  smoothLoop(ctx, loop);
  fillStroke(ctx, fill, line);
}

// the FAR hind leg, set back a touch from the near one and drawn in shade behind the body, so the
// kangaroo reads as standing on two legs. Same bones, hip shifted toward the tail.
const FAR_LEG_SETBACK = 0.05;
function drawFarLeg(ctx: Ctx, shade: string, line: string): void {
  const farHip: P = [HIP[0] + FAR_LEG_SETBACK, HIP[1]];
  const leg = jointsOf(farHip, LEG_BASE_ANGLE, [THIGH, SHIN, FOOT]);
  capsule(ctx, leg[0], leg[1], THIGH.r0, THIGH.r1, shade, line);
  capsule(ctx, leg[1], leg[2], SHIN.r0, SHIN.r1, shade, line);
  capsule(ctx, leg[2], leg[3], FOOT.r0, FOOT.r1, shade, line);
}

// the cream underside: belly + the front of the haunch, drawn over the brown body (no outline, soft
// boundary) — the two-tone that makes the form read as volume rather than a flat silhouette.
function drawBelly(ctx: Ctx, fill: string): void {
  ctx.beginPath();
  ctx.moveTo(-0.03, 0.41);
  ctx.quadraticCurveTo(0.05, 0.31, 0.18, 0.33);    // along the belly underside to the groin
  ctx.quadraticCurveTo(0.08, 0.25, -0.05, 0.25);   // down the front of the thigh to the knee
  ctx.quadraticCurveTo(-0.06, 0.33, -0.03, 0.41);  // up the chest front
  ctx.closePath();
  ctx.fillStyle = fill; ctx.fill();
}

// the dark toe-claws at the front of the foot.
function drawToes(ctx: Ctx, color: string): void {
  capsule(ctx, [-0.23, 0.04], [-0.30, 0.015], 0.020, 0.008, color, color);
  capsule(ctx, [-0.20, 0.03], [-0.27, 0.008], 0.018, 0.007, color, color);
}

// the dark paw at the end of the fore-arm.
function drawPaw(ctx: Ctx, color: string): void {
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(-0.20, 0.31, 0.024, 0, Math.PI * 2);
  ctx.fill();
}

function drawEars(ctx: Ctx, fill: string, line: string): void {
  capsule(ctx, EAR_BACK.base, EAR_BACK.tip, EAR_BACK.r0, EAR_BACK.r1, fill, line);
  capsule(ctx, EAR_FRONT.base, EAR_FRONT.tip, EAR_FRONT.r0, EAR_FRONT.r1, fill, line);
}

// the head: a long horizontal ellipse, sitting on the front of the neck and reaching forward to the
// snout. Drawn over the neck so it reads as a distinct, smaller head on a thicker neck.
function drawHead(ctx: Ctx, fill: string, line: string): void {
  ctx.beginPath();
  ctx.ellipse(HEAD.cx, HEAD.cy, HEAD.rx, HEAD.ry, 0, 0, Math.PI * 2);
  fillStroke(ctx, fill, line);
}

function drawFace(ctx: Ctx, eye: string): void {
  ctx.fillStyle = eye;
  ctx.beginPath();
  ctx.arc(HEAD.eye[0], HEAD.eye[1], 0.022, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(HEAD.nostril[0], HEAD.nostril[1], 0.009, 0, Math.PI * 2);
  ctx.fill();
}
