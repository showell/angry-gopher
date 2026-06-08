// beast.ts — a hand-drawn cartoon BEAST in profile (no emoji), modelled as an ARTICULATED SKELETON.
//
// A beast is built from rigid PARTS, each with a permanent shape — for the leg: an upper leg, a lower
// leg, and a foot. The JOINTS between them (hip, knee, ankle) have no size of their own; they are
// just pivots, and a POSE is the set of joint ANGLES. Forward kinematics walks the chain — each joint
// adds its angle to the running direction, then a rigid bone of fixed length carries on to the next
// joint — so the limb bends at real joints, and a hop is just a change of angles, nothing redraws.
//
// Rigid limb parts are drawn as tapered capsules (a permanent length + end radii); the torso, head
// and ears keep their own permanent outlines; the neck and tail are curled chains. Everything lives
// in a frame where the beast stands 1 unit tall, feet on y = 0, facing LEFT, x running toward the
// tail. The kangaroo is the first study; future beasts reuse this anatomy with different numbers.

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

// ---- the kangaroo skeleton (rigid bones + rest-pose joint angles, radians) ----

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
const ARM_SHOULDER: P = [-0.05, 0.49];
const ARM_BASE_ANGLE = -2.035;
const UPPER_ARM: Bone = { length: 0.090, joint: 0,     r0: 0.035, r1: 0.027 };
const FORE_ARM:  Bone = { length: 0.165, joint: 0.219, r0: 0.027, r1: 0.016 };

// the heavy tail: thick as the haunch at the root, sweeping in one smooth curve down and back to a
// low point that rests near the ground (no up-hook). Tapering capsules between successive nodes.
const TAIL_NODES: P[] = [[0.44, 0.49], [0.64, 0.29], [0.81, 0.13], [0.94, 0.04]];
const TAIL_RADII = [0.130, 0.085, 0.045, 0.012];

// the neck, leaning forward from the withers to the head. Its back edge is the upper part of the
// dorsal curve, so its lower node sits back, over the start of the back, to flow into it smoothly.
const NECK_NODES: P[] = [[0.03, 0.55], [-0.02, 0.66], [-0.08, 0.76]];
const NECK_RADII = [0.090, 0.065, 0.050];

// the head's permanent outline (snout pointing left), with the eye and nostril. The occiput (back of
// the head) continues straight up out of the nape, so the dorsal line runs unbroken into the neck.
const HEAD = {
  throat: [-0.14, 0.70], occiput: [-0.04, 0.82], crown: [-0.11, 0.86],
  noseTop: [-0.32, 0.81], snout: [-0.37, 0.75], chin: [-0.26, 0.68],
  eye: [-0.21, 0.79], nostril: [-0.345, 0.76],
} as const;

// two upright ears rising from the crown, the front one a touch ahead of the back one.
const EAR_BACK = { base: [-0.05, 0.82], tip: [0.03, 1.00], r0: 0.034, r1: 0.010 } as const;
const EAR_FRONT = { base: [-0.12, 0.83], tip: [-0.18, 1.02], r0: 0.038, r1: 0.012 } as const;

// the torso's permanent outline: the long, gently arched back (the middle of the dorsal curve) over
// the belly. The withers meet the neck's base, and the rump meets the tail's base.
const TORSO = {
  chestFront: [-0.15, 0.42], shoulderTop: [0.03, 0.55], rump: [0.44, 0.50], rumpLow: [0.36, 0.36], belly: [0.02, 0.33],
} as const;

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
// Parts are drawn back-to-front: tail behind the body, then the torso, the near limbs over it, and
// finally the neck and head.
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

  drawFarLeg(ctx, pal.shadow, pal.line);                       // far hind leg, behind everything, set back
  drawChain(ctx, TAIL_NODES, TAIL_RADII, pal.body, pal.line);   // tail, behind the body
  drawTorso(ctx, pal.body, pal.line);
  capsule(ctx, leg[0], leg[1], THIGH.r0, THIGH.r1, pal.limb, pal.line);   // upper leg (the haunch)
  drawBelly(ctx, pal.belly);                                              // cream belly + thigh-front, over the body
  capsule(ctx, leg[1], leg[2], SHIN.r0, SHIN.r1, pal.belly, pal.line);    // lower leg (cream inner)
  capsule(ctx, leg[2], leg[3], FOOT.r0, FOOT.r1, pal.belly, pal.line);    // foot (cream)
  drawToes(ctx, pal.line);                                                // dark toe-claws at the foot tip
  capsule(ctx, arm[0], arm[1], UPPER_ARM.r0, UPPER_ARM.r1, pal.limb, pal.line);
  capsule(ctx, arm[1], arm[2], FORE_ARM.r0, FORE_ARM.r1, pal.limb, pal.line);
  drawPaw(ctx, pal.line);                                                 // dark paw at the arm's end
  drawChain(ctx, NECK_NODES, NECK_RADII, pal.body, pal.line);   // curled neck
  drawEars(ctx, pal.body, pal.line);
  drawHead(ctx, pal.body, pal.line);
  drawFace(ctx, pal.eye);

  ctx.restore();
}

// a curled chain (neck, tail): tapering capsules between successive nodes.
function drawChain(ctx: Ctx, nodes: P[], radii: number[], fill: string, line: string): void {
  for (let i = 0; i < nodes.length - 1; i++) {
    capsule(ctx, nodes[i], nodes[i + 1], radii[i], radii[i + 1], fill, line);
  }
}

function drawTorso(ctx: Ctx, fill: string, line: string): void {
  ctx.beginPath();
  ctx.moveTo(...TORSO.chestFront);
  ctx.quadraticCurveTo(-0.10, 0.50, ...TORSO.shoulderTop);   // up the chest to the withers
  ctx.quadraticCurveTo(0.24, 0.585, ...TORSO.rump);          // over the long, gently arched back
  ctx.quadraticCurveTo(0.48, 0.42, ...TORSO.rumpLow);        // down the rump
  ctx.quadraticCurveTo(0.14, 0.30, ...TORSO.belly);          // under the belly
  ctx.quadraticCurveTo(-0.15, 0.34, ...TORSO.chestFront);    // up to the chest front
  ctx.closePath();
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
  ctx.moveTo(-0.13, 0.40);
  ctx.quadraticCurveTo(-0.02, 0.30, 0.16, 0.31);   // under the long belly to the groin
  ctx.quadraticCurveTo(0.08, 0.24, -0.05, 0.24);   // down the front of the thigh to the knee
  ctx.quadraticCurveTo(-0.13, 0.32, -0.13, 0.40);  // up the chest front
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
  ctx.arc(-0.13, 0.25, 0.024, 0, Math.PI * 2);
  ctx.fill();
}

function drawEars(ctx: Ctx, fill: string, line: string): void {
  capsule(ctx, EAR_BACK.base, EAR_BACK.tip, EAR_BACK.r0, EAR_BACK.r1, fill, line);
  capsule(ctx, EAR_FRONT.base, EAR_FRONT.tip, EAR_FRONT.r0, EAR_FRONT.r1, fill, line);
}

function drawHead(ctx: Ctx, fill: string, line: string): void {
  ctx.beginPath();
  ctx.moveTo(...HEAD.throat);
  ctx.quadraticCurveTo(-0.03, 0.75, ...HEAD.occiput);     // up the back of the head, continuing the nape
  ctx.quadraticCurveTo(...HEAD.crown, ...HEAD.noseTop);   // over the crown to the top of the snout
  ctx.lineTo(...HEAD.snout);                              // out to the nose tip
  ctx.lineTo(...HEAD.chin);                               // under the muzzle to the chin
  ctx.quadraticCurveTo(-0.18, 0.67, ...HEAD.throat);      // back to the throat
  ctx.closePath();
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
