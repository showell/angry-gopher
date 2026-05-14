// generate_game.ts — play one full game and write a DSL transcript
// the Elm UI can replay. No flags; tunables are the constants below.

import type { Card } from "./core/card.ts";
import { playFullGame } from "./full_game/full_game.ts";
import { writeSession } from "./full_game/transcript.ts";
import { validateSession } from "./full_game/validate_session.ts";
import {
  openingBoardPositioned,
  remainingCards,
  mulberry32,
  shuffle,
} from "./baseline_deal.ts";

const HAND_SIZE = 15;
const NUM_PLAYERS = 2;
const SEED = 50;

function main(): void {
  const rand = mulberry32(SEED);
  const remaining = shuffle(remainingCards(), rand);
  // Deal BOTH hands BEFORE play starts (Lyn Rummy rule).
  const hands: readonly (readonly Card[])[] = [
    remaining.slice(0, HAND_SIZE),
    remaining.slice(HAND_SIZE, 2 * HAND_SIZE),
  ];
  const deck = remaining.slice(NUM_PLAYERS * HAND_SIZE);
  const positioned = openingBoardPositioned();

  const result = playFullGame(positioned, hands, deck);

  const t = writeSession({
    initialBoard: positioned,
    initialHands: hands,
    initialDeck: deck,
    result,
    label: `agent self-play (seed=${SEED})`,
  });
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
