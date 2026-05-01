// card.ts — Card primitives. Mirrors python/rules/card.py.
//
// A Card is a tuple of (value, suit, deck) ints:
//   value: 1..13 (1=A, 11=J, 12=Q, 13=K)
//   suit:  0..3  (0=C, 1=D, 2=S, 3=H)
//   deck:  0 or 1 (the game uses a double deck)
//
// Cards are encoded as readonly tuples to match the Python tuple shape
// and so they can serve as composite keys in maps via JSON-stringification
// when needed. Equality is by value semantics (deep compare).

export const RANKS = "A23456789TJQK";
export const SUITS = "CDSH";

// RED = {Diamonds, Hearts}.
export const RED: ReadonlySet<number> = new Set([1, 3]);

export type Card = readonly [number, number, number];

/**
 * Parse a card label like "5H" or "TC:1" into a Card tuple.
 * `:1` suffix selects deck 1; default is deck 0.
 */
export function parseCardLabel(label: string): Card {
  let deck = 0;
  if (label.includes(":")) {
    const parts = label.split(":");
    label = parts[0]!;
    deck = parseInt(parts[1]!, 10);
  }
  if (label.length !== 2) {
    throw new Error(`invalid card label: ${JSON.stringify(label)}`);
  }
  const rankIdx = RANKS.indexOf(label[0]!);
  const suitIdx = SUITS.indexOf(label[1]!);
  if (rankIdx < 0 || suitIdx < 0) {
    throw new Error(`invalid card label: ${JSON.stringify(label)}`);
  }
  return [rankIdx + 1, suitIdx, deck] as const;
}

/** Render a Card as a label string (deck-0 form, no suffix). */
export function cardLabel(c: Card): string {
  return RANKS[c[0] - 1]! + SUITS[c[1]]!;
}
