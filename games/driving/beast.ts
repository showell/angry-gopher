// beast.ts — a hand-drawn cartoon BEAST in profile (no emoji). Every beast shares one anatomy: a
// torso with an arched back, a long heavy tail, a big hind leg on a flat foot, a small arm, an
// upright neck, and a head with a snout, two ears and an eye. A species is just a BeastForm — the
// palette plus the profile ANCHOR POINTS, given in a frame where the beast stands 1 unit tall with
// its feet on y = 0, facing LEFT, x running toward the tail. The kangaroo is the first study; future
// beasts (same anatomy, different proportions) are new BeastForms drawn by the very same code.

import type { Project, Ctx, Scenery } from './scenery.ts';

// a point in the beast's profile frame: x toward the tail (right), y up, feet at the origin.
type P = readonly [number, number];

interface BeastForm {
  palette: { body: string; belly: string; limb: string; line: string; eye: string };
  // hind leg + flat foot — the kangaroo's ground support
  heel: P; toe: P; footTop: P; ankle: P; knee: P; hip: P; thighBack: P;
  // torso — the arched back and the belly
  rump: P; backPeak: P; shoulder: P; chestFront: P; bellyBottom: P;
  // the long tail
  tailTop: P; tailBottom: P; tailTip: P;
  // neck + head
  neckFront: P; throat: P; chin: P; snout: P; noseTop: P; headTop: P; crown: P;
  // ears, eye, nostril, and the small fore-arm
  earFrontTip: P; earBackTip: P; eye: P; nostril: P;
  armTop: P; armElbow: P; armPaw: P;
}

const KANGAROO: BeastForm = {
  palette: { body: '#b27a44', belly: '#e3c9a3', limb: '#9c6736', line: '#3b2a17', eye: '#15100a' },
  heel: [0.15, 0.02], toe: [-0.17, 0.00], footTop: [-0.08, 0.06], ankle: [0.15, 0.08], knee: [0.25, 0.33], hip: [0.08, 0.50], thighBack: [0.31, 0.40],
  rump: [0.33, 0.50], backPeak: [0.20, 0.64], shoulder: [-0.02, 0.58], chestFront: [-0.12, 0.44], bellyBottom: [0.05, 0.33],
  tailTop: [0.27, 0.47], tailBottom: [0.17, 0.38], tailTip: [0.62, 0.05],
  neckFront: [-0.08, 0.52], throat: [-0.14, 0.62], chin: [-0.19, 0.66], snout: [-0.31, 0.72], noseTop: [-0.27, 0.77], headTop: [-0.05, 0.81], crown: [-0.04, 0.82],
  earFrontTip: [-0.12, 1.00], earBackTip: [0.06, 0.97], eye: [-0.15, 0.78], nostril: [-0.28, 0.73],
  armTop: [-0.05, 0.53], armElbow: [0.01, 0.45], armPaw: [-0.11, 0.40],
};

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

const KANGAROO_HEIGHT = 1.8;     // a big red kangaroo stands about this tall
const KANGAROO_ALONG = 24;       // matches the bull's BULL_DIST so the two stand opposite each other
const KANGAROO_ROAD_GAP = 1.5;   // it stands this far beyond the roadside tree line, facing the road

// The beasts lining a segment: for now one kangaroo on the RIGHT, opposite the bull that leads the
// herd on the left. `treeLineOffset` is how far the roadside trees sit beyond the lane edge — the
// kangaroo stands just past them and faces the road.
export function segmentBeasts(laneHalfWidth: number, treeLineOffset: number): Beast[] {
  const treeX = laneHalfWidth + treeLineOffset;
  return [{ along: KANGAROO_ALONG, across: treeX + KANGAROO_ROAD_GAP, height: KANGAROO_HEIGHT, faceRight: false, form: KANGAROO }];
}

// Wrap a placed beast as Scenery. Like critters, it carries no extra up-close detail yet, so near
// and far are the same draw — a hook for per-distance detail later.
export function beastScenery(view: BeastView): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawBeast(ctx, view, project);
  return { forward: view.at.forward, height: view.height, drawAsNear: draw, drawAsFar: draw };
}

// Fill the current path with `fill`, then trace its outline in the form's line colour.
function fillStroke(ctx: Ctx, F: BeastForm, fill: string): void {
  ctx.fillStyle = fill; ctx.fill();
  ctx.strokeStyle = F.palette.line; ctx.stroke();
}

// Draw the beast's profile, sized by distance. We map into a local frame where the standing height
// is 1, x runs right (toward the tail) and y runs UP, with the feet on the origin; every BeastForm
// anchor is read in that frame. Parts are drawn back-to-front so they overlap correctly.
function drawBeast(ctx: Ctx, b: BeastView, project: Project): void {
  const base = project(b.at.right, b.at.forward, 0);
  const top = project(b.at.right, b.at.forward, b.height);
  const h = base.y - top.y;
  if (h < 2) return;   // too small to detail; the renderer's size cull is the real cutoff

  const F = b.form;
  ctx.save();
  ctx.translate(base.x, base.y);
  if (b.faceRight) ctx.scale(-1, 1);   // the form faces left; flip to face right
  ctx.scale(h, -h);                    // into the unit profile frame (y up, feet at the origin)
  ctx.lineWidth = LINE_WIDTH;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  drawTail(ctx, F);
  drawHindLeg(ctx, F);
  drawTorso(ctx, F);
  drawEars(ctx, F);
  drawNeckHead(ctx, F);
  drawArm(ctx, F);
  drawFace(ctx, F);

  ctx.restore();
}

// the heavy tail, thick at the rump and tapering back-and-down to the ground behind.
function drawTail(ctx: Ctx, F: BeastForm): void {
  ctx.beginPath();
  ctx.moveTo(...F.tailTop);
  ctx.quadraticCurveTo(0.50, 0.36, ...F.tailTip);      // top edge sweeping down to the tip
  ctx.quadraticCurveTo(0.40, 0.16, ...F.tailBottom);   // back along the underside
  ctx.closePath();
  fillStroke(ctx, F, F.palette.body);
}

// the big hind leg: a bulging thigh to the knee, a shank to the ankle, and a long flat foot.
function drawHindLeg(ctx: Ctx, F: BeastForm): void {
  ctx.beginPath();
  ctx.moveTo(...F.hip);
  ctx.quadraticCurveTo(...F.thighBack, ...F.knee);   // thigh bulging back to the knee
  ctx.lineTo(...F.ankle);                            // shank down to the ankle
  ctx.quadraticCurveTo(...F.heel, ...F.toe);         // heel around to the foot's toe
  ctx.lineTo(...F.footTop);                          // top of the foot near the toes
  ctx.quadraticCurveTo(0.06, 0.20, ...F.hip);        // up the front of the shin back to the hip
  ctx.closePath();
  fillStroke(ctx, F, F.palette.limb);
}

// the torso: up the chest, over the arched back to the rump, then under the belly.
function drawTorso(ctx: Ctx, F: BeastForm): void {
  ctx.beginPath();
  ctx.moveTo(...F.chestFront);
  ctx.quadraticCurveTo(-0.07, 0.60, ...F.shoulder);    // up the chest to the shoulder
  ctx.quadraticCurveTo(...F.backPeak, ...F.rump);      // over the arched back to the rump
  ctx.quadraticCurveTo(0.28, 0.38, ...F.bellyBottom);  // down the rump and under the belly
  ctx.quadraticCurveTo(-0.05, 0.34, ...F.chestFront);  // belly forward to the chest
  ctx.closePath();
  fillStroke(ctx, F, F.palette.body);
}

// two upright ears rising from the crown; the back ear sits a touch behind the front one.
function drawEars(ctx: Ctx, F: BeastForm): void {
  ctx.beginPath();
  ctx.moveTo(-0.02, 0.80);
  ctx.quadraticCurveTo(0.10, 0.92, ...F.earBackTip);
  ctx.quadraticCurveTo(0.02, 0.86, 0.03, 0.80);
  ctx.closePath();
  fillStroke(ctx, F, F.palette.body);

  ctx.beginPath();
  ctx.moveTo(-0.09, 0.80);
  ctx.quadraticCurveTo(-0.16, 0.92, ...F.earFrontTip);
  ctx.quadraticCurveTo(-0.06, 0.88, -0.03, 0.80);
  ctx.closePath();
  fillStroke(ctx, F, F.palette.body);
}

// the upright neck and the head: up the back of the neck, over the skull, out to the snout, and
// back under the muzzle and throat to the chest.
function drawNeckHead(ctx: Ctx, F: BeastForm): void {
  ctx.beginPath();
  ctx.moveTo(...F.shoulder);                          // back-of-neck base, at the shoulder
  ctx.quadraticCurveTo(0.05, 0.70, ...F.crown);       // up the back of the neck to the crown
  ctx.quadraticCurveTo(...F.headTop, ...F.noseTop);   // over the skull to the top of the snout
  ctx.lineTo(...F.snout);                             // out to the nose tip
  ctx.lineTo(...F.chin);                              // under the muzzle to the chin
  ctx.quadraticCurveTo(...F.throat, ...F.neckFront);  // down the throat
  ctx.lineTo(...F.shoulder);                          // close along the chest
  ctx.closePath();
  fillStroke(ctx, F, F.palette.body);
}

// the small fore-arm, bent and held up against the chest.
function drawArm(ctx: Ctx, F: BeastForm): void {
  ctx.beginPath();
  ctx.moveTo(...F.armTop);
  ctx.quadraticCurveTo(0.04, 0.47, ...F.armElbow);
  ctx.lineTo(...F.armPaw);
  ctx.quadraticCurveTo(-0.05, 0.43, -0.02, 0.50);
  ctx.closePath();
  fillStroke(ctx, F, F.palette.limb);
}

// the eye and the nostril — two filled dots in the line colour.
function drawFace(ctx: Ctx, F: BeastForm): void {
  ctx.fillStyle = F.palette.eye;
  ctx.beginPath();
  ctx.arc(F.eye[0], F.eye[1], 0.022, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(F.nostril[0], F.nostril[1], 0.009, 0, Math.PI * 2);
  ctx.fill();
}
