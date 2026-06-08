// critter — the SHARED critter substrate: the in-segment Critter and the placed-in-the-Rider's-
// frame CritterView, plus the drawing layer (cached emoji billboards). The animals themselves live
// in farm_critter.ts (cows/bull/pigs) and safari_critter.ts (elephant/giraffe/zebra); this module
// knows only how to put a billboard on the canvas, not a cow from an elephant.

import type { Project, Ctx, Scenery } from './scenery.ts';

// A critter in its SEGMENT's frame: `along` the segment, `across` from the centreline (+ = right).
// A point billboard — height in metres, facing a way.
export interface Critter {
  along: number;
  across: number;
  emoji: string;
  height: number;
  faceRight: boolean;
}

// A critter placed in the scene, measured FROM THE RIDER and ready to draw. `at` is a ground-plane
// point { right, forward } in the Rider's frame.
export interface CritterView {
  at: { right: number; forward: number };
  emoji: string;
  height: number;
  faceRight: boolean;
}

const SPRITE_PX = 96;   // offscreen resolution each emoji is rasterised at, once

// Wrap a placed critter as Scenery. Critters have no up-close detail yet, so drawAsNear and
// drawAsFar are the same billboard draw — a hook for per-distance detail later.
export function critterScenery(view: CritterView): Scenery {
  const draw = (ctx: Ctx, project: Project): void => drawCritter(ctx, view, project);
  return { forward: view.at.forward, height: view.height, drawAsNear: draw, drawAsFar: draw };
}

// Emoji are expensive to rasterise every frame, so render each ONCE to an offscreen sprite and
// reuse it (drawImage is far cheaper than fillText).
const spriteCache = new Map<string, HTMLCanvasElement>();
function emojiSprite(emoji: string): HTMLCanvasElement {
  const cached = spriteCache.get(emoji);
  if (cached) return cached;
  const c = document.createElement('canvas');
  c.width = SPRITE_PX; c.height = SPRITE_PX;
  const g = c.getContext('2d') as CanvasRenderingContext2D;
  g.font = `${Math.round(SPRITE_PX * 0.8)}px serif`;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText(emoji, SPRITE_PX / 2, SPRITE_PX / 2 + SPRITE_PX * 0.06);
  spriteCache.set(emoji, c);
  return c;
}

// Draw one critter as a full-body emoji billboard, sized by distance and flipped to face the road.
// The caller pre-filters by depth; we just skip sub-pixel ones.
function drawCritter(ctx: CanvasRenderingContext2D, cr: CritterView, project: Project): void {
  const base = project(cr.at.right, cr.at.forward, 0);
  const top = project(cr.at.right, cr.at.forward, cr.height);
  const h = base.y - top.y;
  if (h < 1) return;   // sub-pixel guard; the renderer's MIN_SCENERY_PX cull is the real cutoff
  ctx.save();
  ctx.translate(base.x, base.y);
  if (cr.faceRight) ctx.scale(-1, 1);   // most animal emoji face left by default
  ctx.drawImage(emojiSprite(cr.emoji), -h / 2, -h, h, h);   // square, bottom on the ground
  ctx.restore();
}
