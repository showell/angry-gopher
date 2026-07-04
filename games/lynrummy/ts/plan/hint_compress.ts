// hint_compress.ts — collapse a naive multi-line hint into the tighter
// form that matches the player's actual gestures.
//
// The engine emits hints one line per BFS plan step, with a leading
// "place [X] from hand" for the cards lifted off the hand
// (hand_play.ts:formatHint + bfs/move.ts:describe). That phrasing is
// faithful to the SOLVER's steps but not to the player's MOTIONS: a
// hand card that is placed and then immediately dropped onto a board
// stack is ONE drag, yet it reads as two lines.
//
// The verbs that consume the just-placed card as a single hand→board
// drop are `push`, `free_pull`, and `splice` — the agent realizes each
// as one `merge_hand` primitive. `push`/`free_pull` land the card ONTO
// an existing group (extend); `splice` lands it INTO a run (which then
// splits around it). The other verbs (extract_absorb, shift, decompose)
// rearrange BOARD cards, so they never fuse with a hand placement.
//
// This rewrite works entirely in DSL space. It re-parses the card lists
// with the shared DSL parser and re-emits them with the shared emitter,
// so the output is canonical DSL — not string-spliced fragments — and a
// malformed line simply fails to match rather than producing garbage.
//
// Scope today: a pure single play (place [X] + one consuming move).
// Multi-step plans pass through unchanged — later sophistication work
// (see ts/in_progress/HINT_SOPHISTIFICATION.md).

import { parseCardList } from "../dsl/parse.ts";
import { formatCardList } from "../dsl/emit.ts";

const PLACE_RE = /^place \[(.+?)\] from hand$/;

/** One "the placed card drops directly onto/into a board stack" verb.
 *  `looseGroup` captures the card(s) the move consumes; `targetGroup`
 *  captures the destination stack; `verb`/`prep` are the human phrasing:
 *  "<verb> X from hand <prep> <target>". */
interface FuseRule {
  readonly re: RegExp;
  readonly looseGroup: number;
  readonly targetGroup: number;
  readonly verb: "play" | "splice";
  readonly prep: "onto" | "into";
}

const FUSE_RULES: readonly FuseRule[] = [
  // push: trouble card onto a complete helper (extend a run/set).
  { re: /^push \[(.+?)\] onto HELPER \[(.+?)\] → \[.+?\]$/, looseGroup: 1, targetGroup: 2, verb: "play", prep: "onto" },
  // free_pull: loose card onto a partial being assembled — same gesture
  // as push; the "helper vs partial" distinction is invisible to the player.
  { re: /^pull (.+?) onto \[(.+?)\] → \[.+?\](?: \[→COMPLETE\])?$/, looseGroup: 1, targetGroup: 2, verb: "play", prep: "onto" },
  // splice: loose card into a run. "splice" is a verb players recognize;
  // we don't spell out that the run divides into two — the player sees it.
  { re: /^splice \[(.+?)\] into HELPER \[(.+?)\] → \[.+?\] \+ \[.+?\]$/, looseGroup: 1, targetGroup: 2, verb: "splice", prep: "into" },
];

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
  return tryFuseSinglePlay(lines) ?? lines;
}

// place [X] from hand ; <push|pull|splice> [X] ... → play X from hand
// <onto|into> <target>. Only when those two lines are the WHOLE hint and
// the consumed cards are exactly the placed cards: the placement and the
// drop are then a single drag, and fusing tells the player the one thing
// they'd do.
function tryFuseSinglePlay(lines: readonly string[]): readonly string[] | null {
  if (lines.length !== 2) return null;
  const place = lines[0]!.match(PLACE_RE);
  if (place === null) return null;
  const placed = canon(place[1]!);
  if (placed === null) return null;

  for (const rule of FUSE_RULES) {
    const m = lines[1]!.match(rule.re);
    if (m === null) continue;
    const loose = canon(m[rule.looseGroup]!);
    const target = canon(m[rule.targetGroup]!);
    // The consumed cards must BE the placed cards (deck-aware identity —
    // canon keeps the deck-2 marker); otherwise the move is consuming
    // board trouble, not the placement, and it isn't one gesture.
    if (loose === null || target === null || loose !== placed) return null;
    // Human phrasing: no brackets, no "HELPER" (an algorithm-internal
    // name for the board stack), no "→ [result]" (the player watches it
    // land), and no deck-2 apostrophe (A♠' reads as A♠ — the two physical
    // decks are identical to the eye). Deck matters for identity, not display.
    return [`${rule.verb} ${deckBlind(placed)} from hand ${rule.prep} ${deckBlind(target)}`];
  }
  return null;
}
