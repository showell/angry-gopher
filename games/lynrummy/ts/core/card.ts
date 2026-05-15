// core/card.ts — the canonical Card type, shared across every TS
// layer (bfs, step, full_game, src/wire helpers) and structurally
// pinned to Elm's CardValue / Suit / OriginDeck unions.
//
// Code reads `Rank.Ace`, `Suit.Diamond`, `Deck.Two`; the runtime
// values are plain numbers (1..13 for ranks; 0..3 for suits in
// CDSH order; 0/1 for the decks). Numeric ordering is load-bearing
// — downstream code does arithmetic on rank (e.g. modulo wrap so
// 2 succeeds King in Lyn Rummy's run rules).
//
// Implemented as `const` objects rather than TS `enum` blocks
// because Node's strip-only TS mode (the runtime that executes
// these files) does not accept `enum`. The shape and ergonomics
// are identical: `Rank.Ace`, `type Rank = typeof Rank[keyof typeof
// Rank]`, etc.

export const Rank = {
  Ace: 1,
  Two: 2,
  Three: 3,
  Four: 4,
  Five: 5,
  Six: 6,
  Seven: 7,
  Eight: 8,
  Nine: 9,
  Ten: 10,
  Jack: 11,
  Queen: 12,
  King: 13,
} as const;
export type Rank = typeof Rank[keyof typeof Rank];

export const Suit = {
  Club: 0,
  Diamond: 1,
  Spade: 2,
  Heart: 3,
} as const;
export type Suit = typeof Suit[keyof typeof Suit];

export const Deck = {
  One: 0,
  Two: 1,
} as const;
export type Deck = typeof Deck[keyof typeof Deck];

export interface Card {
  readonly rank: Rank;
  readonly suit: Suit;
  readonly deck: Deck;
}

export const RANKS = "A23456789TJQK";
export const SUITS = "CDSH";
const SUITS_UNICODE = "♣♦♠♥";

/** Predicate on a suit value. Accepts `number` because callers
 *  frequently iterate `for (let s = 0; s < 4; s++)` and pass the raw
 *  loop index. The body works for any 0..3 and returns false
 *  otherwise — the brand is more useful at construction sites
 *  (`parseCardLabel`) than as a predicate input. */
export function isRedSuit(s: number): boolean {
  return s === Suit.Diamond || s === Suit.Heart;
}

/** Parse a card label like "5H" or "TC'" into a Card. A trailing
 *  apostrophe selects deck Two; default is deck One. Legacy `:1`
 *  suffix form also accepted. Unicode suit glyphs are accepted
 *  alongside ASCII for parser tolerance. */
export function parseCardLabel(label: string): Card {
  let deck: Deck = Deck.One;
  if (label.endsWith("'")) {
    deck = Deck.Two;
    label = label.slice(0, -1);
  } else if (label.includes(":")) {
    const parts = label.split(":");
    label = parts[0]!;
    deck = parseInt(parts[1]!, 10) === 1 ? Deck.Two : Deck.One;
  }
  if (label.length !== 2) {
    throw new Error(`invalid card label: ${JSON.stringify(label)}`);
  }
  const rankIdx = RANKS.indexOf(label[0]!);
  let suitIdx = SUITS.indexOf(label[1]!);
  if (suitIdx < 0) suitIdx = SUITS_UNICODE.indexOf(label[1]!);
  if (rankIdx < 0 || suitIdx < 0) {
    throw new Error(`invalid card label: ${JSON.stringify(label)}`);
  }
  return { rank: (rankIdx + 1) as Rank, suit: suitIdx as Suit, deck };
}

/** Render a Card as an ASCII label like "5H" or "TC'". Deck Two
 *  cards get a trailing apostrophe. */
export function cardLabel(c: Card): string {
  const base = RANKS[c.rank - 1]! + SUITS[c.suit]!;
  return c.deck === Deck.One ? base : `${base}'`;
}

/** Card token with unicode suit glyph; deck-2 cards get a trailing
 *  `'`. Used by the wire-DSL emitters. */
export function cardToken(c: Card): string {
  const base = RANKS[c.rank - 1]! + SUITS_UNICODE[c.suit]!;
  return c.deck === Deck.One ? base : `${base}'`;
}

/** Parse a whitespace-separated list of card labels like
 *  "5H 6H 7H'". Empty / whitespace-only input returns []. */
export function parseCardList(s: string): Card[] {
  if (s.trim() === "") return [];
  return s.trim().split(/\s+/).filter(Boolean).map(parseCardLabel);
}
