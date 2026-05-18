// find_5line_puzzle.ts — one-off discovery script. Throwaway.
//
// Plays one agent-vs-agent game from a fixed SEED and stops at
// the first play whose BFS plan has TARGET_PLAN_LENGTH moves.
// Prints the puzzle as DSL on stdout.
//
// If the seed doesn't yield a 5-line hit, bump SEED manually
// and try again — per Steve's "scale up slowly" guidance, we
// don't sweep en masse. Once we have a handful, the output
// gets pasted into games/lynrummy/conformance/curated_5line_puzzles.dsl.

import { fileURLToPath } from "node:url";

import type { Card } from "../core/card.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { findOpenLoc } from "../geometry/geometry.ts";
import { findLogicalMovesForPlay } from "../plan/hand_play.ts";
import { findGroomPrimitives } from "../plan/groom.ts";
import { getPrimitivesForLogicalPlay } from "../plan/physical_plan.ts";
import { applyLocally } from "../game_events/primitives.ts";
import { formatBoardStackLine } from "../dsl/emit.ts";
import {
  openingBoardPositioned,
  remainingCards,
  mulberry32,
  shuffle,
} from "../baseline_deal.ts";

const HAND_SIZE = 15;
const NUM_PLAYERS = 2;
const STOP_AT_DECK = 10;
const TARGET_PLAN_LENGTH = 5;

// Tunable. Bump and re-run if this seed doesn't yield a hit.
const SEED = 1;

interface Hit {
  readonly seed: number;
  readonly turn: number;
  readonly player: number;
  readonly augmented: readonly BoardStack[];
  readonly cardsToPlay: readonly Card[];
  readonly verbs: readonly string[];
  readonly moveLines: readonly string[];
}

function firstWord(s: string): string {
  const m = s.match(/^\s*(\S+)/);
  return m ? m[1]! : "";
}

function puzzleName(hit: Hit): string {
  const sortedVerbs = [...hit.verbs].sort().join("_");
  return `5line_${sortedVerbs}_s${hit.seed}t${hit.turn}p${hit.player}`;
}

function emitPuzzleDsl(hit: Hit): void {
  console.log(`puzzle ${puzzleName(hit)}`);
  for (const s of hit.augmented) {
    console.log(`  ${formatBoardStackLine(s)}`);
  }
  console.log();
}

function findFirstHit(seed: number): Hit | null {
  const rand = mulberry32(seed);
  const remaining = shuffle(remainingCards(), rand);
  const hands: Card[][] = [
    [...remaining.slice(0, HAND_SIZE)],
    [...remaining.slice(HAND_SIZE, 2 * HAND_SIZE)],
  ];
  let deck = remaining.slice(NUM_PLAYERS * HAND_SIZE);
  let board: readonly BoardStack[] = openingBoardPositioned();
  let active = 0;
  let turn = 1;

  while (deck.length > STOP_AT_DECK && turn < 200) {
    let playsThisTurn = 0;
    let handEmptiedThisTurn = false;

    while (true) {
      const groomed = findGroomPrimitives(board);
      if (groomed !== null) {
        board = groomed.board;
        continue;
      }

      const cardLists = board.map(s => s.cards);
      const logical = findLogicalMovesForPlay(hands[active]!, cardLists);
      if (logical === null) break;

      if (logical.moveLines.length === TARGET_PLAN_LENGTH) {
        const placedLoc = findOpenLoc(board, logical.cardsToPlay.length);
        const augmented: readonly BoardStack[] = [
          ...board,
          { cards: [...logical.cardsToPlay], loc: placedLoc },
        ];
        return {
          seed,
          turn,
          player: active,
          augmented,
          cardsToPlay: logical.cardsToPlay,
          verbs: logical.moveLines.map(firstWord),
          moveLines: logical.moveLines,
        };
      }

      const prims = getPrimitivesForLogicalPlay(board, logical);
      for (const p of prims) board = applyLocally(board, p);
      const playedSet = new Set(logical.cardsToPlay);
      hands[active] = hands[active]!.filter(c => !playedSet.has(c));
      playsThisTurn++;
      if (hands[active]!.length === 0) {
        handEmptiedThisTurn = true;
        break;
      }
    }

    const drawCount = handEmptiedThisTurn
      ? 5
      : playsThisTurn === 0
        ? 3
        : 0;
    const drawn = deck.slice(0, drawCount);
    hands[active] = [...hands[active]!, ...drawn];
    deck = deck.slice(drawCount);
    active = (active + 1) % NUM_PLAYERS;
    turn++;
  }
  return null;
}

function main(): void {
  const hit = findFirstHit(SEED);
  if (hit === null) {
    console.error(`seed=${SEED}: no 5-line hit found before deck exhausted.`);
    process.exit(1);
  }
  console.error(`# hit: seed=${hit.seed} turn=${hit.turn} player=${hit.player}`);
  console.error(`# verbs: ${hit.verbs.join(" / ")}`);
  console.error(`# moveLines:`);
  for (const line of hit.moveLines) console.error(`#   ${line}`);
  console.error();
  emitPuzzleDsl(hit);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
