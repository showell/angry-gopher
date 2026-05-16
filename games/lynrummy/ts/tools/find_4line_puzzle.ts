// find_4line_puzzle.ts — one-off discovery script. Throwaway.
//
// Scans agent self-play across a sweep of seeds, collects EVERY play
// whose BFS plan has TARGET_PLAN_LENGTH moves. Streams a summary
// (verb-multiset per hit) plus optional full DSL for the diverse
// subset. Writes nothing; exits 0 on completion.
//
// Per Steve's puzzle-curation guidance (2026-05-16): curation
// programs bit-rot as BFS evolves; throw them away after the
// curation pass. The output (the puzzle DSL) is what's durable.

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
const TARGET_PLAN_LENGTH = 4;

// Configurable sweep. Start small to gauge variety; scale up
// (move to a background process) once we know the variety/seed
// ratio.
const SEEDS = Array.from({ length: 10 }, (_, i) => i + 1);

interface Hit {
  readonly seed: number;
  readonly turn: number;
  readonly player: number;
  readonly augmented: readonly BoardStack[];
  readonly hand: readonly Card[];
  readonly cardsToPlay: readonly Card[];
  readonly verbs: readonly string[]; // user-facing first-word verbs from moveLines
  readonly moveLines: readonly string[];
}

function firstWord(s: string): string {
  const m = s.match(/^\s*(\S+)/);
  return m ? m[1]! : "";
}

function findInSeed(seed: number): Hit[] {
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

  const hits: Hit[] = [];

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

      if (logical.moves.length === TARGET_PLAN_LENGTH) {
        // The puzzle = the augmented board BFS solves. Conceptually:
        // [...board, cardsToPlay]. We append cardsToPlay as a fresh
        // BoardStack at a non-overlapping loc so the UI can render
        // the puzzle exactly as BFS sees it.
        //
        // (Don't try to use getPrimitivesForLogicalPlay's prims[]
        // for this — for singleton placements there's no separate
        // place_hand primitive; the placement is woven into the
        // first move's primitives via expandVerb.)
        const placedLoc = findOpenLoc(board, logical.cardsToPlay.length);
        const augmented: readonly BoardStack[] = [
          ...board,
          { cards: [...logical.cardsToPlay], loc: placedLoc },
        ];
        hits.push({
          seed,
          turn,
          player: active,
          augmented,
          hand: [...hands[active]!],
          cardsToPlay: logical.cardsToPlay,
          verbs: logical.moveLines.map(firstWord),
          moveLines: logical.moveLines,
        });
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
  return hits;
}

function verbKey(verbs: readonly string[]): string {
  // Sorted multiset string — same key for same verb-multiset.
  return [...verbs].sort().join("+");
}

function puzzleName(hit: Hit): string {
  const sortedVerbs = [...hit.verbs].sort().join("_");
  return `4line_${sortedVerbs}_s${hit.seed}t${hit.turn}p${hit.player}`;
}

function dumpPuzzleDsl(hit: Hit): void {
  console.log(`puzzle ${puzzleName(hit)}`);
  for (const s of hit.augmented) {
    console.log(`  ${formatBoardStackLine(s)}`);
  }
  console.log();
}

function main(): void {
  const emitDsl = process.argv.includes("--emit-dsl");
  const tStart = Date.now();
  const allHits: Hit[] = [];

  if (!emitDsl) {
    console.log(`=== sweep: seeds ${SEEDS[0]}..${SEEDS[SEEDS.length - 1]} (${SEEDS.length} seeds) ===`);
    console.log();
  }

  for (const seed of SEEDS) {
    const t0 = Date.now();
    const hits = findInSeed(seed);
    const ms = Date.now() - t0;
    allHits.push(...hits);
    if (!emitDsl) console.log(`seed=${seed}: ${hits.length} hits in ${ms}ms`);
  }

  if (emitDsl) {
    // DSL-only output, suitable for piping to a .dsl file.
    console.log(`# Curated 4-line Lyn Rummy puzzles.`);
    console.log(`#`);
    console.log(`# Generated 2026-05-16 from agent self-play across seeds ${SEEDS[0]}–${SEEDS[SEEDS.length - 1]}.`);
    console.log(`# Each board is a dirty state that the BFS solver resolves in exactly 4`);
    console.log(`# verb-level moves. Names encode the sorted verb-multiset + provenance`);
    console.log(`# (s<seed>t<turn>p<player>) so duplicates within a verb-shape are distinguishable.`);
    console.log(`#`);
    console.log(`# Format matches mined_seeds.dsl — \`puzzle <name>\` header + indented`);
    console.log(`# \`at (left,top): cards\` body. UI: views/puzzle.go consumes directly.`);
    console.log(`# Conformance: test/test_curated_puzzles.ts asserts plan_length === 4.`);
    console.log();
    for (const hit of allHits) dumpPuzzleDsl(hit);
    return;
  }

  console.log();
  console.log(`=== ${allHits.length} total 4-line plays across ${SEEDS.length} seeds (${Date.now() - tStart}ms) ===`);
  console.log();

  const verbsCovered = new Set<string>();
  for (const h of allHits) for (const v of h.verbs) verbsCovered.add(v);
  console.log(`Verbs seen (any position): ${[...verbsCovered].sort().join(", ")}`);
  console.log();

  const byVerbKey = new Map<string, Hit[]>();
  for (const h of allHits) {
    const k = verbKey(h.verbs);
    if (!byVerbKey.has(k)) byVerbKey.set(k, []);
    byVerbKey.get(k)!.push(h);
  }
  console.log(`Distinct verb-multisets: ${byVerbKey.size}`);
  for (const [k, hs] of [...byVerbKey.entries()].sort((a, b) => b[1].length - a[1].length)) {
    console.log(`  [${k}] — ${hs.length} hit(s)`);
  }
  console.log();

  console.log(`=== first diverse subset (one per verb-multiset, max 10) ===`);
  console.log();
  let picked = 0;
  for (const [, hs] of byVerbKey) {
    if (picked >= 10) break;
    dumpPuzzleDsl(hs[0]!);
    picked++;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
