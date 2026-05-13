// generate_game.ts — play one full game and write a DSL transcript
// the Elm UI can replay. No flags; tunables are the constants below.

import type { Card } from "./src/rules/card.ts";
import { parseCardLabel } from "./src/rules/card.ts";
import { playFullGame } from "./full_game/full_game.ts";
import { writeSession } from "./full_game/transcript.ts";
import { validateSession } from "./full_game/validate_session.ts";

const HAND_SIZE = 15;
const NUM_PLAYERS = 2;
const STOP_AT_DECK = 10;
const SEED = 50;

// Game 17 opening board. Locations match dealer.go's initial-board
// layout (`top = 20 + row*60; col = (row*3 + 1) % 5; left = 40 + col*30`)
// so the transcript writer's positioned output matches what Elm renders
// on a fresh-replay bootstrap.
const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function boardLocFor(row: number): { top: number; left: number } {
  const col = (row * 3 + 1) % 5;
  return { top: 20 + row * 60, left: 40 + col * 30 };
}

function makeOpeningBoardPositioned(): readonly { cards: readonly Card[]; loc: { top: number; left: number } }[] {
  return BOARD_LABELS.map((stack, row) => ({
    cards: stack.map(parseCardLabel),
    loc: boardLocFor(row),
  }));
}

function remainingCards(): Card[] {
  const onBoard = new Set<string>();
  for (const stack of BOARD_LABELS) {
    for (const lbl of stack) {
      const c = parseCardLabel(lbl);
      onBoard.add(`${c[0]},${c[1]},${c[2]}`);
    }
  }
  const out: Card[] = [];
  for (let suit = 0; suit < 4; suit++) {
    for (let v = 1; v <= 13; v++) {
      for (const deck of [0, 1] as const) {
        const c: Card = [v, suit, deck] as const;
        if (!onBoard.has(`${c[0]},${c[1]},${c[2]}`)) out.push(c);
      }
    }
  }
  if (out.length !== 81) throw new Error(`expected 81 remaining; got ${out.length}`);
  return out;
}

// mulberry32 — deterministic, seedable, native to JS.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle<T>(arr: readonly T[], rand: () => number): T[] {
  const out = [...arr];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j]!, out[i]!];
  }
  return out;
}

function main(): void {
  const rand = mulberry32(SEED);
  const remaining = shuffle(remainingCards(), rand);
  // Deal BOTH hands BEFORE play starts (Lyn Rummy rule).
  const hands: readonly (readonly Card[])[] = [
    remaining.slice(0, HAND_SIZE),
    remaining.slice(HAND_SIZE, 2 * HAND_SIZE),
  ];
  const deck = remaining.slice(NUM_PLAYERS * HAND_SIZE);
  const positioned = makeOpeningBoardPositioned();

  const result = playFullGame(positioned, hands, deck, { stopAtDeck: STOP_AT_DECK });

  const t = writeSession(
    { initialBoard: positioned, initialHands: hands, initialDeck: deck, result },
    { label: `agent self-play (seed=${SEED})` },
  );
  console.log(`wrote session #${t.sessionId} (${t.actionsWritten} actions) to ${t.sessionDir}`);

  // Round-trip validation: re-read the emitted files, parse via the
  // production wire parsers, replay through applyLocally +
  // findViolation. If this passes, the transcript is both properly
  // formatted AND rule-abiding.
  const v = validateSession(t.sessionDir);
  if (!v.ok) {
    throw new Error(`session #${t.sessionId} validation failed: ${v.msg}`);
  }
  console.log(`validated session #${t.sessionId} (${v.actionsApplied} actions replayed clean)`);
  console.log(`review at http://localhost:9000/gopher/lynrummy-elm/play/${t.sessionId}`);
}

main();
