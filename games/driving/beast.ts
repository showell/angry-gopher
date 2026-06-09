// beast.ts — a hand-drawn cartoon BEAST in profile (no emoji), modelled from simple solids.
//
// A cat standing in profile, built from the parts you'd name pointing at it:
//   • TORSO — a long rounded cylinder (a horizontal capsule) parallel to the ground.
//   • NECK  — a shorter, thick cylinder (a capsule) that connects the head to the torso.
//   • HEAD  — a sphere (a circle), carried forward at the end of the neck.
//   • LEGS  — four articulated chains (upper leg, lower leg, paw) joined by knee/ankle JOINTS that
//             have no size; a POSE is the set of joint ANGLES, walked by forward kinematics.
//   • TAIL  — a tapering chain of capsules off the rump.
// Filled in one colour the capsules and sphere union into a single connected body. Everything lives
// in a frame where the beast stands 1 unit tall (feet on y = 0, ear tips at 1), facing LEFT, x toward
// the tail.
//
// DEBUG (below) swaps in a diagnostic view: the neck solid pink, the other solids as see-through
// outlines, the legs as their raw skeleton — so the underlying construction is visible. Turn it off
// for the finished cat.

import type { Project, Ctx, Scenery } from './scenery.ts';

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

// where the legs attach to the torso (near pair, in front; far pair set back a touch and drawn in
// shade behind the body, so all four legs read).
const FRONT_HIP: P = [-0.10, 0.46];
const HIND_HIP: P = [0.58, 0.46];
const FAR_SETBACK = 0.06;   // the far leg of each pair sits this much further toward the tail

// two triangular ears, seen in PROFILE: the near ear stands on top of the head; the far ear sits a
// little behind it and lower, so (drawn behind the head, in shade) only its tip peeks out.
const NEAR_EAR = { a: [-0.53, 0.84], tip: [-0.53, 1.04], b: [-0.43, 0.87] } as const;
const FAR_EAR = { a: [-0.45, 0.86], tip: [-0.43, 1.00], b: [-0.35, 0.85] } as const;

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
const SKIN = '#1faa4f';     // the stretched-skin envelope (diagnostic)

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
// unit-frame skeleton), so the same cat can be a kitten or full-grown — only the height changes.
function cat(along: number, across: number, height: number, faceRight: boolean): Beast {
  return { along, across, height, faceRight, form: CAT };
}

// The beasts lining a segment: for now one cat on the RIGHT, just past the herd, facing the road.
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

// Extend the current path with a smooth OPEN curve through pts (Catmull-Rom -> cubic Béziers).
function smoothOpen(ctx: Ctx, pts: P[]): void {
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[i + 2] ?? pts[i + 1];
    const c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
    const c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
    ctx.bezierCurveTo(c1x, c1y, c2x, c2y, p2[0], p2[1]);
  }
}

type Circle = { c: P; r: number };

// sample a capsule into overlapping circles along its length, so a chain of them fills the cylinder.
function sampleCapsule(out: Circle[], A: P, B: P, rA: number, rB: number, n: number): void {
  for (let k = 0; k <= n; k++) {
    const t = k / n;
    out.push({ c: [A[0] + (B[0] - A[0]) * t, A[1] + (B[1] - A[1]) * t], r: rA + (rB - rA) * t });
  }
}

// every internal solid as a cloud of circles (the capsules sampled along their length).
function bodyCircles(): Circle[] {
  const out: Circle[] = [{ c: [HEAD.cx, HEAD.cy], r: HEAD.r }];
  sampleCapsule(out, NECK_A, NECK_B, NECK_R, NECK_R, 4);
  sampleCapsule(out, TORSO_A, TORSO_B, TORSO_R, TORSO_R, 8);
  for (let i = 0; i < TAIL_NODES.length - 1; i++) {
    sampleCapsule(out, TAIL_NODES[i], TAIL_NODES[i + 1], TAIL_RADII[i], TAIL_RADII[i + 1], 4);
  }
  return out;
}

// The SKIN is the outer silhouette of the UNION of those circles: scanning across x, the TOP line is
// the highest circle-top covering that x and the BOTTOM line is the lowest circle-bottom. So the skin
// lies exactly on whichever solid is outermost there — hugging each one — and the only place it leaves
// a circle is the local hand-off where the next solid becomes the outer one (which the smooth curve
// then rounds). No chords across circles, no spanning the gaps.
function buildSkin(): { top: P[]; bottom: P[] } {
  const circles = bodyCircles();
  let minX = Infinity, maxX = -Infinity;
  for (const c of circles) { minX = Math.min(minX, c.c[0] - c.r); maxX = Math.max(maxX, c.c[0] + c.r); }
  // The skin is sampled as scan-lines in x, so near-vertical stretches of the outline (the front of
  // the face, the tip of the tail) need a fine step or they flatten — sample densely.
  const step = (maxX - minX) / 240;
  const top: P[] = [], bottom: P[] = [];
  for (let x = minX; x <= maxX + 1e-9; x += step) {
    let yt = -Infinity, yb = Infinity;
    for (const c of circles) {
      const dx = x - c.c[0];
      if (Math.abs(dx) <= c.r) {
        const dy = Math.sqrt(c.r * c.r - dx * dx);
        if (c.c[1] + dy > yt) yt = c.c[1] + dy;
        if (c.c[1] - dy < yb) yb = c.c[1] - dy;
      }
    }
    if (yt > -Infinity) { top.push([x, yt]); bottom.push([x, yb]); }
  }
  return { top, bottom };
}

// Trace a CLOSED smooth curve through pts (Catmull-Rom -> cubic Béziers, wrapping around).
function smoothClosed(ctx: Ctx, pts: P[]): void {
  const n = pts.length;
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
    const c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
    const c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
    ctx.bezierCurveTo(c1x, c1y, c2x, c2y, p2[0], p2[1]);
  }
  ctx.closePath();
}

// Fill the cat's body as the SKIN silhouette: the top envelope, then the bottom envelope reversed,
// closed into one smooth shape. Head, neck, torso and tail are all inside this single outline.
function fillSkin(ctx: Ctx, fill: string, line: string): void {
  const { top, bottom } = buildSkin();
  const loop = [...top, ...bottom.slice(1, -1).reverse()];
  ctx.beginPath();
  smoothClosed(ctx, loop);
  fillStroke(ctx, fill, line);
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
  else drawCat(ctx, b.form.palette);

  ctx.restore();
}

// the finished cat: the body is the SKIN silhouette over the internal solids; legs, ears and face on top.
function drawCat(ctx: Ctx, pal: BeastForm['palette']): void {
  drawLeg(ctx, far(FRONT_HIP), pal.shadow, pal.line);   // far pair, behind the body, in shade
  drawLeg(ctx, far(HIND_HIP), pal.shadow, pal.line);
  drawEar(ctx, FAR_EAR, pal.shadow, pal.line);          // far ear, behind the head (its base is hidden)
  fillSkin(ctx, pal.body, pal.line);                    // head + neck + torso + tail as one sleek skin
  drawLeg(ctx, FRONT_HIP, pal.body, pal.line);          // near pair, over the body
  drawLeg(ctx, HIND_HIP, pal.body, pal.line);
  drawEar(ctx, NEAR_EAR, pal.body, pal.line);           // near ear, on top of the head
  drawFace(ctx, pal.eye, pal.nose);
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

  const skin = buildSkin();   // the stretched-skin envelope: head -> body top -> tail, and the belly
  ctx.strokeStyle = SKIN;
  ctx.beginPath(); smoothOpen(ctx, skin.top); ctx.stroke();
  ctx.beginPath(); smoothOpen(ctx, skin.bottom); ctx.stroke();

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

// one leg: upper leg, lower leg, paw — three capsules along the FK chain from the hip.
function drawLeg(ctx: Ctx, hip: P, fill: string, line: string): void {
  const j = jointsOf(hip, LEG_BASE_ANGLE, [UPPER_LEG, LOWER_LEG, PAW]);
  capsule(ctx, j[0], j[1], UPPER_LEG.r0, UPPER_LEG.r1, fill, line);
  capsule(ctx, j[1], j[2], LOWER_LEG.r0, LOWER_LEG.r1, fill, line);
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
