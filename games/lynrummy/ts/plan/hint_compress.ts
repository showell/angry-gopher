// hint_compress.ts — rewrite a raw engine hint into the sequence a human
// would actually perform.
//
// The engine emits a hint one line per BFS plan step, led by a
// "place [X] from hand" step (hand_play.ts:formatHint + bfs/move.ts:
// describe). Two things make that faithful-to-the-solver phrasing wrong
// for a player:
//
//   1. Gesture granularity. A hand card placed and then dropped onto a
//      board stack is ONE drag, but reads as two lines.
//   2. Ordering. The projection layer lists the hand placement FIRST and
//      doesn't care about order, but a player holds the card and drops it
//      only when the board is ready. So board manipulation comes FIRST and
//      the hand card lands LAST.
//
// This module reassembles the plan into: every board→board move (in the
// solver's order), then the single hand card landing on its target, fused
// into one line. It works entirely in DSL space — card lists round-trip
// through the shared dsl parser/emitter (`canon`), so output is canonical
// DSL and a malformed line just fails to match.
//
// Verb families:
//   - push / free_pull / splice: consume one loose card. From HAND they are
//     the landing step ("play|splice X from hand ..."); of a BOARD card they
//     are board cleanup ("push|pull|splice X ...").
//   - extract_absorb (peel/pluck/yank/steal/split_out/set_peel): always
//     board→board — relocate a card from a source helper to a target.
//   - shift / decompose: not yet handled; a plan containing one is left raw.
//
// Scope: a single hand card consumed by exactly one move. Pairs that split
// (decompose) and shift come later. Any plan we don't fully understand is
// returned UNCHANGED — never half-transformed.

import { parseCardList } from "../dsl/parse.ts";
import { formatCardList } from "../dsl/emit.ts";

const PLACE_RE = /^place \[(.+?)\] from hand$/;

// extract_absorb: "<verb> <card> from HELPER [source], absorb onto [target]
// → [result]" with optional " [→COMPLETE]" and "; spawn ..." tails. The verb
// encodes the source-remnant fate (the player just watches); the motion is
// always "move this card from source onto target".
const EXTRACT_ABSORB_RE =
  /^(peel|pluck|yank|steal|split_out|set_peel) (.+?) from HELPER \[(.+?)\], absorb onto \[(.+?)\] → \[.+?\](?: \[→COMPLETE\])?(?: ; spawn .+)?$/;

// Display verb per extract_absorb verb. peel/pluck/yank/steal are already
// recognizable English; the two internal names get natural substitutes
// (set_peel IS a peel from a set; split_out reads fine as two words).
const VERB_LABEL: Readonly<Record<string, string>> = {
  peel: "peel",
  pluck: "pluck",
  yank: "yank",
  steal: "steal",
  set_peel: "peel",
  split_out: "split out",
};

/** A push/free_pull/splice move: consumes one loose card onto/into a target.
 *  `looseGroup`/`targetGroup` are the capture indices; `handVerb` phrases it
 *  as a hand landing, `boardVerb` as a board cleanup; `prep` is shared. */
interface ConsumeRule {
  readonly re: RegExp;
  readonly looseGroup: number;
  readonly targetGroup: number;
  readonly handVerb: "play" | "splice";
  readonly boardVerb: "push" | "pull" | "splice";
  readonly prep: "onto" | "into";
}

const CONSUME_RULES: readonly ConsumeRule[] = [
  // push: trouble card onto a complete helper (extend a run/set).
  { re: /^push \[(.+?)\] onto HELPER \[(.+?)\] → \[.+?\]$/, looseGroup: 1, targetGroup: 2, handVerb: "play", boardVerb: "push", prep: "onto" },
  // free_pull: loose card onto a partial — same gesture as push; the
  // helper-vs-partial distinction is invisible to the player.
  { re: /^pull (.+?) onto \[(.+?)\] → \[.+?\](?: \[→COMPLETE\])?$/, looseGroup: 1, targetGroup: 2, handVerb: "play", boardVerb: "pull", prep: "onto" },
  // splice: loose card into a run, which splits around it (unspoken — the
  // player watches it happen). "splice" is a verb players recognize.
  { re: /^splice \[(.+?)\] into HELPER \[(.+?)\] → \[.+?\] \+ \[.+?\]$/, looseGroup: 1, targetGroup: 2, handVerb: "splice", boardVerb: "splice", prep: "into" },
];

/** One parsed move line. `boardLine` is always the board→board rendering.
 *  For a consuming verb, `consumesCard` is the loose card (deck-aware) and
 *  `handLine` is the "... from hand ..." rendering; extract_absorb leaves
 *  both null (it never lands a hand card). */
interface ParsedMove {
  readonly consumesCard: string | null;
  readonly handLine: string | null;
  readonly boardLine: string;
}

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

/** Parse one move line into board + (optional) hand renderings, or null if
 *  it's a verb we don't handle (shift / decompose / anything unknown). */
function parseMove(line: string): ParsedMove | null {
  for (const r of CONSUME_RULES) {
    const m = line.match(r.re);
    if (m === null) continue;
    const card = canon(m[r.looseGroup]!);
    const target = canon(m[r.targetGroup]!);
    if (card === null || target === null) return null;
    const c = deckBlind(card);
    const t = deckBlind(target);
    return {
      consumesCard: card,
      handLine: `${r.handVerb} ${c} from hand ${r.prep} ${t}`,
      boardLine: `${r.boardVerb} ${c} ${r.prep} ${t}`,
    };
  }
  const ea = line.match(EXTRACT_ABSORB_RE);
  if (ea !== null) {
    const verb = VERB_LABEL[ea[1]!];
    const card = canon(ea[2]!);
    const source = canon(ea[3]!);
    const target = canon(ea[4]!);
    if (verb === undefined || card === null || source === null || target === null) {
      return null;
    }
    return {
      consumesCard: null,
      handLine: null,
      boardLine: `${verb} ${deckBlind(card)} from ${deckBlind(source)} onto ${deckBlind(target)}`,
    };
  }
  return null;
}

/** Rewrite a raw engine hint into board-first, gesture-faithful form.
 *  Returns the input unchanged when the plan doesn't fit the shape we
 *  fully understand (never a half-transformed plan). */
export function compressHint(lines: readonly string[]): readonly string[] {
  if (lines.length === 0) return lines;

  const place = lines[0]!.match(PLACE_RE);
  if (place === null) {
    // No hand placement: a pure board plan (or a lone board move). Humanize
    // every line, or bail if any line is a verb we don't handle.
    return humanizeAllBoard(lines) ?? lines;
  }
  const placed = canon(place[1]!);
  if (placed === null) return lines;

  const moveLines = lines.slice(1);
  if (moveLines.length === 0) {
    // Triple-in-hand on a clean board: the placed cards ARE the play.
    return [`play ${deckBlind(placed)} from hand`];
  }

  const moves: ParsedMove[] = [];
  for (const ml of moveLines) {
    const pm = parseMove(ml);
    if (pm === null) return lines; // unknown verb → leave the whole plan raw
    moves.push(pm);
  }

  // Exactly one move must land the placed card; that's the hand step.
  const landing = moves.filter(m => m.consumesCard === placed);
  if (landing.length !== 1) return lines; // can't cleanly place X → bail

  // Board manipulation first (solver's order), the hand card last.
  const board = moves.filter(m => m.consumesCard !== placed);
  return [...board.map(m => m.boardLine), landing[0]!.handLine!];
}

/** Humanize a plan with no hand placement — each line as a board move —
 *  or null if any line is a verb we don't handle. */
function humanizeAllBoard(lines: readonly string[]): readonly string[] | null {
  const out: string[] = [];
  for (const line of lines) {
    const pm = parseMove(line);
    if (pm === null) return null;
    out.push(pm.boardLine);
  }
  return out;
}
