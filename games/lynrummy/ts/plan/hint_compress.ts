// hint_compress.ts — collapse a naive multi-line hint into the tighter
// form that matches the player's actual gestures.
//
// The engine's hint is emitted one line per BFS plan step, with a
// leading "place [X] from hand" for the cards lifted off the hand
// (hand_play.ts:formatHint + bfs/move.ts:describe). That phrasing is
// faithful to the SOLVER's steps but not to the player's MOTIONS: a
// hand card that is placed and then immediately pushed onto a helper
// is ONE drag, yet it reads as two lines.
//
// This rewrite works entirely in DSL space. It re-parses the card
// lists with the shared DSL parser and re-emits them with the shared
// emitter, so the output is canonical DSL — not string-spliced
// fragments — and a malformed line simply fails to match rather than
// producing garbage.
//
// Scope today: the pure single-push play. Anything else passes through
// unchanged — multi-step plans and non-push verbs are left for later
// sophistication passes (see ts/in_progress/HINT_SOPHISTIFICATION.md).

import { parseCardList } from "../dsl/parse.ts";
import { formatCardList } from "../dsl/emit.ts";

const PLACE_RE = /^place \[(.+?)\] from hand$/;
const PUSH_RE = /^push \[(.+?)\] onto HELPER \[(.+?)\] → \[(.+?)\]$/;

/** Drop deck-2 markers from a canonical card-list string. The only
 *  apostrophes in a `formatCardList` result are deck-2 suffixes, so
 *  stripping them renders cards deck-blind — how the player sees them. */
function deckBlind(cardList: string): string {
  return cardList.replace(/'/g, "");
}

/** Canonicalize a bracketed card-list substring by round-tripping it
 *  through the shared parser + emitter. Returns null when it isn't a
 *  valid card list, so a malformed line just doesn't match. */
function canon(cardsDsl: string): string | null {
  try {
    return formatCardList(parseCardList(cardsDsl));
  } catch {
    return null;
  }
}

/** Rewrite a hint (one line per plan step) into the gesture-faithful
 *  form. Returns the input untouched when no rule applies. */
export function compressHint(lines: readonly string[]): readonly string[] {
  return tryFuseSinglePush(lines) ?? lines;
}

// place [X] from hand ; push [X] onto HELPER [T] → [R]
//   → play [X] from hand onto HELPER [T] → [R]
//
// Only when those two lines are the WHOLE hint and the pushed cards are
// exactly the placed cards: the placement and the push are then a single
// drag, and fusing them tells the player to do the one thing they'd do.
function tryFuseSinglePush(lines: readonly string[]): readonly string[] | null {
  if (lines.length !== 2) return null;
  const place = lines[0]!.match(PLACE_RE);
  const push = lines[1]!.match(PUSH_RE);
  if (place === null || push === null) return null;

  const placed = canon(place[1]!);
  const pushed = canon(push[1]!);
  const target = canon(push[2]!);
  if (placed === null || pushed === null || target === null) {
    return null;
  }
  // The pushed cards must BE the hand cards — otherwise the push is
  // consuming board trouble, not the placement, and it isn't one gesture.
  // This identity check is deck-aware (canon keeps the deck-2 marker).
  if (placed !== pushed) return null;

  // Human phrasing: no brackets, no "HELPER" (an algorithm-internal name
  // for the board stack), no "→ [result]" (redundant once it's one
  // gesture — the player sees the result on the board), and no deck-2
  // apostrophe (the two physical decks are identical to the player, so
  // A♠' reads as A♠). Deck matters for identity above, never for display.
  return [`play ${deckBlind(placed)} from hand onto ${deckBlind(target)}`];
}
