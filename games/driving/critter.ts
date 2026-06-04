// =============================================================================
// critter — the roadside animals (cows, pigs, elephants). This module owns
// EVERYTHING about them: where they stand on a segment, how big they are, and
// how they're drawn (emoji billboards, cached). The rest of the app stays
// generic: ask a segment for its critters, then throw the drawn billboards on
// the canvas — no need to know a cow from an elephant.
// =============================================================================

// A critter in its SEGMENT's frame: `along` the segment, `across` from the
// centreline (+ = right). A point billboard — height in metres, facing a way.
export interface Critter {
  along: number;
  across: number;
  emoji: string;
  height: number;
  faceRight: boolean;
}

// A critter placed in the scene, measured FROM THE RIDER and ready to draw.
// `at` is a ground-plane point { right, forward } in the Rider's frame.
export interface CritterView {
  at: { right: number; forward: number };
  emoji: string;
  height: number;
  faceRight: boolean;
}

// ---- dimensions (metres) ----
const COW_HEIGHT = 1.4;
const CALF_HEIGHT = COW_HEIGHT / 2;
const BULL_HEIGHT = COW_HEIGHT * 1.15;          // a touch bigger than a cow
const PIG_HEIGHT = 1.1;
const ELEPHANT_HEIGHT = 2.8;                    // adult; x GIANT_ELEPHANT_SCALE late in the route
const BABY_ELEPHANT_HEIGHT = ELEPHANT_HEIGHT / 2;

const HERD_ROAD_OFFSET = 10;             // cows graze this far beyond the lane edge
const BULL_DIST = 24;                    // the bull stands here (~the 4th tree); the herd is just behind
const BULL_TREE_GAP = 0.5;               // the bull's rear sits this far back from the tree line
const HERD_GAP_BEHIND_BULL = 6;          // the rest of the herd starts this far behind the bull
const HERD_COL_SPACING = 6;              // along-spacing of the herd scatter
const HERD_ROW_STAGGER = 2;              // along-stagger between herd rows
const HERD_ROW_DEPTH = 5;                // across-spacing (depth) of the herd scatter
const HERD_JITTER_ALONG = 1.5;           // deterministic wobble of the scatter, along
const HERD_JITTER_ACROSS = 1.2;          // deterministic wobble of the scatter, across
const PIG_DIST_BEFORE_END = 60;          // pigs gather this far before the next intersection
const ELEPHANT_PAST_INTERSECTION = 20;   // the elephants stand this far beyond the intersection
const BABY_ELEPHANT_AHEAD = 6;           // the baby elephant sits this far ahead of the adult
const BABY_ELEPHANT_SIDE_OFFSET = 14;    // ...and this far to the side (opposite the turn)

const GIANT_ELEPHANT_SCALE = 3;          // elephants this many times bigger...
const GIANT_ELEPHANT_FROM_SEG = 8;       // ...on segments numbered above this

// ---- where the critters are, per segment ----

// The critters ALONG a segment: a cow herd near the start (left) and pigs near
// the end (right). `treeLineOffset` is how far roadside trees sit beyond the lane
// edge — the bull lines its rear up with that tree line.
export function segmentCritters(length: number, laneHalfWidth: number, treeLineOffset: number): Critter[] {
  return [...cowHerd(laneHalfWidth, treeLineOffset), ...pigRow(length, laneHalfWidth + HERD_ROAD_OFFSET)];
}

// The critters AT a segment's exit intersection: the elephants, just past it, to
// the side OPPOSITE the turn. `intersectionAlong` is where the intersection is
// (the segment's far end); `turnSign` is +1 right / -1 left; elephants go giant
// late in the route (segNum). The adult faces "left" (rear on its right), so we
// put its REAR — not its middle — on the centreline by shifting it half its
// width, else the wide giant body straddles the road.
export function intersectionCritters(intersectionAlong: number, turnSign: number, segNum: number): Critter[] {
  const corner = intersectionAlong + ELEPHANT_PAST_INTERSECTION;
  const scale = segNum > GIANT_ELEPHANT_FROM_SEG ? GIANT_ELEPHANT_SCALE : 1;
  const adultH = ELEPHANT_HEIGHT * scale, babyH = BABY_ELEPHANT_HEIGHT * scale;
  return [
    { along: corner,                       across: -turnSign * adultH / 2,                emoji: '🐘', height: adultH, faceRight: false },
    { along: corner + BABY_ELEPHANT_AHEAD, across: -turnSign * BABY_ELEPHANT_SIDE_OFFSET, emoji: '🐘', height: babyH, faceRight: false },
  ];
}

// 15 cows early in the segment: a BULL at the front (lowest along — seen first as
// you leave the corner), bigger than the rest and facing the opposite way, then
// 10 full-size cows + 4 half-size calves just behind it in a loose cluster (a
// staggered grid with deterministic jitter — no randomness).
function cowHerd(hw: number, treeLineOffset: number): Critter[] {
  const out: Critter[] = [];
  const edge = hw + HERD_ROAD_OFFSET;     // the cows graze well off the road
  const treeX = hw + treeLineOffset;      // the roadside tree line (left side = -treeX)
  out.push({ along: BULL_DIST, across: -(treeX + BULL_HEIGHT / 2 + BULL_TREE_GAP), emoji: '🐂', height: BULL_HEIGHT, faceRight: false });
  for (let i = 0; i < 14; i++) {
    const col = Math.floor(i / 3), row = i % 3;
    const along = BULL_DIST + HERD_GAP_BEHIND_BULL + col * HERD_COL_SPACING + (row - 1) * HERD_ROW_STAGGER + HERD_JITTER_ALONG * Math.sin(i * 2.7);
    const across = -(edge + row * HERD_ROW_DEPTH + HERD_JITTER_ACROSS * Math.cos(i * 1.9));
    const calf = i % 4 === 1;   // i = 1,5,9,13 -> 4 calves at half size
    out.push({ along, across, emoji: '🐄', height: calf ? CALF_HEIGHT : COW_HEIGHT, faceRight: true });
  }
  return out;
}

function pigRow(length: number, edge: number): Critter[] {
  const out: Critter[] = [];
  for (const d of [-6, -2, 2, 6]) {
    out.push({ along: length - PIG_DIST_BEFORE_END + d, across: edge, emoji: '🐖', height: PIG_HEIGHT, faceRight: false });
  }
  return out;
}

// ---- drawing: emoji billboards, with cached sprites ----

// project a ground-plane point (right, forward) at a height to the screen
export type Project = (right: number, forward: number, height: number) => { x: number; y: number };

// Emoji are expensive to rasterize every frame, so render each one ONCE to an
// offscreen sprite and reuse it. drawImage is far cheaper than fillText.
const spriteCache = new Map<string, HTMLCanvasElement>();
function emojiSprite(emoji: string): HTMLCanvasElement {
  const cached = spriteCache.get(emoji);
  if (cached) return cached;
  const S = 96;
  const c = document.createElement('canvas');
  c.width = S; c.height = S;
  const g = c.getContext('2d') as CanvasRenderingContext2D;
  g.font = `${Math.round(S * 0.8)}px serif`;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText(emoji, S / 2, S / 2 + S * 0.06);
  spriteCache.set(emoji, c);
  return c;
}

// Draw one critter as a full-body emoji billboard, sized by distance and flipped
// to face the road. The caller pre-filters by depth; we just skip tiny ones.
export function drawCritter(ctx: CanvasRenderingContext2D, cr: CritterView, project: Project): void {
  const base = project(cr.at.right, cr.at.forward, 0);
  const top = project(cr.at.right, cr.at.forward, cr.height);
  const h = base.y - top.y;
  if (h < 5) return;
  ctx.save();
  ctx.translate(base.x, base.y);
  if (cr.faceRight) ctx.scale(-1, 1);   // most animal emoji face left by default
  ctx.drawImage(emojiSprite(cr.emoji), -h / 2, -h, h, h);   // square, bottom on the ground
  ctx.restore();
}
