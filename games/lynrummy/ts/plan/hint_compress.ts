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
//   2. Ordering. The projection layer lists the hand placement FIRST, but
//      the placement only happens as part of the move that consumes the
//      card — which the solver may sequence anywhere in the plan.
//
// This module fuses the place line into the consuming move IN PLACE: the
// moves keep the solver's order (executable by construction) and the
// landing move renders as the one "... from hand ..." line. In the common
// case the solver lands the hand card last, so the hint naturally reads
// board-prep-first; when a later board move consumes the landing's result,
// the landing correctly comes before it. It works entirely in DSL space —
// card lists round-trip
// through the shared dsl parser/emitter (`canon`), so output is canonical
// DSL and a malformed line just fails to match.
//
// A second shape: the hand card is a SEED, not a lander. It isn't consumed
// by any move — instead board cards land ONTO it to build a new group
// (e.g. drop 2♥, peel A♣ onto it, peel K♦ onto that → K♦ A♣ 2♥). A human
// just needs "place 2♥ on board to build K♦ A♣ 2♥", so the chain collapses
// to one line. The chain-follow is verb-blind: anything that lands a board
// card onto the chain's current group (absorb, shift, pull, push) advances
// it, and if the whole grown group is later consumed onto something else,
// the chain follows it there — the line names where the placed card
// EVENTUALLY lands. Side repairs interleaved with the chain (an absorb
// spawns a remnant, a later push re-homes it) don't block the collapse:
// placing the seed sets the loner flag, so the next Hint press walks the
// player through the board-only cleanup. If the chain ever DONATES (a
// card extracted from it, a splice into it) we can no longer name the
// placed card's home honestly, and the whole plan stays raw.
//
// Verb families:
//   - push / free_pull / splice: consume one loose card. From HAND they are
//     the landing step ("play|splice X from hand ..."); of a BOARD card they
//     are board cleanup ("push|pull|splice X ...").
//   - extract_absorb (peel/pluck/yank/steal/split_out/set_peel): always
//     board→board — relocate a card from a source helper to a target.
//   - shift: board→board — backfill one end of a run so the other end can
//     pop off and land on the target. Two drags, one thought; rendered as
//     one compound line.
//   - decompose: not yet handled; a plan containing one is left raw.
//
// Scope: a single hand card consumed by exactly one move. Pairs that split
// (decompose) come later. Any plan we don't fully understand is returned
// UNCHANGED — never half-transformed.

import { parseCardList } from "../dsl/parse.ts";
import { formatCardList } from "../dsl/emit.ts";

const PLACE_RE = /^place \[(.+?)\] from hand$/;

// extract_absorb: "<verb> <card> from HELPER [source], absorb onto [target]
// → [result]" with optional " [→COMPLETE]" and "; spawn ..." tails. The verb
// encodes the source-remnant fate (the player just watches); the motion is
// always "move this card from source onto target".
const EXTRACT_ABSORB_RE =
  /^(peel|pluck|yank|steal|split_out|set_peel) (.+?) from HELPER \[(.+?)\], absorb onto \[(.+?)\] → \[(.+?)\](?: \[→COMPLETE\])?(?: ; spawn .+)?$/;

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

// shift: "shift <p> to pop <stolen> [<newDonor> -> <shifted>]; absorb onto
// [target] → [merged]" — <p> backfills one end of a run so <stolen> can pop
// off the other end and land on <target>. <shifted> is "<p> + <rest>" or
// "<rest> + <p>", which side telling which end <p> entered (and so which
// end <stolen> left). The run as the player currently SEES it isn't in the
// line — it's rebuilt from <rest> plus <stolen> on the popped end.
const SHIFT_RE =
  /^shift (.+?) to pop (.+?) \[(.+?) -> (.+?)\]; absorb onto \[(.+?)\] → \[(.+?)\](?: \[→COMPLETE\])?$/;

/** A push/free_pull/splice move: consumes one loose card onto/into a target.
 *  `looseGroup`/`targetGroup`/`resultGroup` are the capture indices
 *  (resultGroup null when the result isn't a single group); `handVerb`
 *  phrases it as a hand landing, `boardVerb` as a board cleanup; `prep` is
 *  shared. */
interface ConsumeRule {
  readonly re: RegExp;
  readonly looseGroup: number;
  readonly targetGroup: number;
  readonly resultGroup: number | null;
  readonly handVerb: "play" | "splice";
  readonly boardVerb: "push" | "pull" | "splice";
  readonly prep: "onto" | "into";
}

const CONSUME_RULES: readonly ConsumeRule[] = [
  // push: trouble card onto a complete helper (extend a run/set).
  { re: /^push \[(.+?)\] onto HELPER \[(.+?)\] → \[(.+?)\]$/, looseGroup: 1, targetGroup: 2, resultGroup: 3, handVerb: "play", boardVerb: "push", prep: "onto" },
  // free_pull: loose card onto a partial — same gesture as push; the
  // helper-vs-partial distinction is invisible to the player.
  { re: /^pull (.+?) onto \[(.+?)\] → \[(.+?)\](?: \[→COMPLETE\])?$/, looseGroup: 1, targetGroup: 2, resultGroup: 3, handVerb: "play", boardVerb: "pull", prep: "onto" },
  // splice: loose card into a run, which splits around it (unspoken — the
  // player watches it happen). "splice" is a verb players recognize. The
  // result is TWO groups, so a chain reaching a splice can't be followed
  // further: resultGroup is null and the chain-follow bails.
  { re: /^splice \[(.+?)\] into HELPER \[(.+?)\] → \[.+?\] \+ \[.+?\]$/, looseGroup: 1, targetGroup: 2, resultGroup: null, handVerb: "splice", boardVerb: "splice", prep: "into" },
];

/** One parsed move line. `boardLine` is always the board→board rendering.
 *  For a consuming verb, `consumesCard` is the loose group (deck-aware
 *  canon), `consumeTarget`/`consumeVerb` are the group it lands on and the
 *  board verb, `consumeResult` the group produced (null when it isn't a
 *  single group — splice), and `handLine` is the "... from hand ..."
 *  rendering; extract_absorb and shift leave those null (they never land a
 *  hand card). For the chain-follow: `chainTarget`/`chainResult` are the
 *  group this move lands a BOARD card onto and the group produced (null
 *  result = can't follow further); `touches` are the groups the move takes
 *  a card FROM — a chain reaching one of those can't be narrated. All
 *  card-list strings are deck-aware canon. */
interface ParsedMove {
  readonly consumesCard: string | null;
  readonly consumeTarget: string | null;
  readonly consumeVerb: "push" | "pull" | "splice" | null;
  readonly consumeResult: string | null;
  readonly handLine: string | null;
  readonly boardLine: string;
  readonly chainTarget: string | null;
  readonly chainResult: string | null;
  readonly touches: readonly string[];
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
    const result = r.resultGroup === null ? null : canon(m[r.resultGroup]!);
    if (card === null || target === null) return null;
    if (r.resultGroup !== null && result === null) return null;
    const c = deckBlind(card);
    const t = deckBlind(target);
    return {
      consumesCard: card,
      consumeTarget: target,
      consumeVerb: r.boardVerb,
      consumeResult: result,
      handLine: `${r.handVerb} ${c} from hand ${r.prep} ${t}`,
      boardLine: `${r.boardVerb} ${c} ${r.prep} ${t}`,
      chainTarget: target,
      chainResult: result,
      touches: [],
    };
  }
  const ea = line.match(EXTRACT_ABSORB_RE);
  if (ea !== null) {
    const verb = VERB_LABEL[ea[1]!];
    const card = canon(ea[2]!);
    const source = canon(ea[3]!);
    const target = canon(ea[4]!);
    const result = canon(ea[5]!);
    if (verb === undefined || card === null || source === null || target === null || result === null) {
      return null;
    }
    return {
      consumesCard: null,
      consumeTarget: null,
      consumeVerb: null,
      consumeResult: null,
      handLine: null,
      boardLine: `${verb} ${deckBlind(card)} from ${deckBlind(source)} onto ${deckBlind(target)}`,
      chainTarget: target,
      chainResult: result,
      touches: [source],
    };
  }
  const sh = line.match(SHIFT_RE);
  if (sh !== null) {
    const p = canon(sh[1]!);
    const stolen = canon(sh[2]!);
    const newDonor = canon(sh[3]!);
    const target = canon(sh[5]!);
    const merged = canon(sh[6]!);
    const halves = sh[4]!.split(" + ");
    if (p === null || stolen === null || newDonor === null || target === null
      || merged === null || halves.length !== 2) return null;
    // Rebuild the source run: <p>'s side of <shifted> says which end the
    // stolen card popped from — the opposite end from where <p> entered.
    const source =
      canon(halves[0]!) === p ? canon(`${halves[1]!} ${sh[2]!}`)
      : canon(halves[1]!) === p ? canon(`${sh[2]!} ${halves[0]!}`)
      : null;
    if (source === null) return null;
    // Which end of the donor run <p> came from isn't in the line; a chain
    // matching either reconstruction counts as touched.
    const donorPre = [canon(`${sh[1]!} ${sh[3]!}`), canon(`${sh[3]!} ${sh[1]!}`)]
      .filter((s): s is string => s !== null);
    return {
      consumesCard: null,
      consumeTarget: null,
      consumeVerb: null,
      consumeResult: null,
      handLine: null,
      // A compound gesture (backfill drag + the freed card's drag) — it
      // never lands a HAND card, but the freed card landing on the chain
      // advances it like any other landing.
      boardLine: `shift ${deckBlind(p)} into ${deckBlind(source)}, freeing the ${deckBlind(stolen)} onto ${deckBlind(target)}`,
      chainTarget: target,
      chainResult: merged,
      touches: [source, ...donorPre],
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

  const landing = moves.filter(m => m.consumesCard === placed);
  if (landing.length === 1) {
    // The placed card LANDS onto board structure: fuse the place line into
    // the landing move IN PLACE, keeping the solver's move order — which is
    // executable by construction. (Floating board moves ahead of the landing
    // broke when a later move consumed the landing's RESULT: it told the
    // player to pull onto a group that didn't exist yet. When the solver's
    // order has the landing last — every plan seen before that one — in-place
    // fusion renders the same hand-lands-last lines as the old reorder.)
    return moves.map(m => m.consumesCard === placed ? m.handLine! : m.boardLine);
  }
  if (landing.length === 0) {
    // The placed PAIR is a LANDING PAD — the plan's one move pulls a board
    // loner ONTO it. Three cards, one human thought: "put these two hand
    // cards with that board card". Deliberately narrow (two-card place, a
    // single pull targeting exactly the placed pair) — don't over-generalize.
    if (moves.length === 1 && placed.split(" ").length === 2) {
      const m = moves[0]!;
      if (m.consumeVerb === "pull" && m.consumeTarget === placed) {
        const [a, b] = deckBlind(placed).split(" ");
        return [`place ${a} and ${b} with the ${deckBlind(m.consumesCard!)} on the board`];
      }
    }
    // The placed card is a SEED — not consumed by anything, it's the anchor a
    // chain of board cards gets landed onto. Collapse the whole chain to one
    // line: "place X on board to build <final group>". ("place", not "play":
    // you play a card ONTO existing structure, you place one to START structure.)
    const built = followPlacedCard(placed, moves);
    if (built !== null) {
      return [`place ${deckBlind(placed)} on board to build ${deckBlind(built)}`];
    }
  }
  return lines; // more than one landing, or a shape we don't fully model → raw
}

/** Follow the placed card's group through the plan and return the group it
 *  eventually ends up in, or null if we can't say. Verb-blind: any move
 *  that lands a board card onto the chain's current group advances it, and
 *  if the grown group is itself consumed onto something else the chain
 *  follows it there. Moves that never touch the chain are side repairs and
 *  are simply skipped: the player only needs "place X to build G", and
 *  placing the seed sets the loner flag, so the NEXT hint walks them
 *  through the board-only cleanup. Bails (→ whole plan raw) when the chain
 *  DONATES a card (extract source / shift run or donor), reaches a splice
 *  (two result groups — no single home to name), or is never touched. */
function followPlacedCard(placed: string, moves: readonly ParsedMove[]): string | null {
  let current = placed;
  for (const m of moves) {
    if (m.touches.includes(current)) return null;
    if (m.chainTarget === current) {
      if (m.chainResult === null) return null;
      current = m.chainResult;
    } else if (m.consumesCard === current) {
      if (m.consumeResult === null) return null;
      current = m.consumeResult;
    }
  }
  return current === placed ? null : current;
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
