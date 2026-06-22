// find_2line_puzzle.ts — one-off discovery script. Throwaway.
//
// Scans agent self-play across a sweep of seeds, collects EVERY play
// whose BFS plan has TARGET_PLAN_LENGTH moves. Default run prints a
// variety report; `--emit-dsl` prints a diverse, curation-ready subset
// (one puzzle per verb-multiset, cleanest/smallest board first, filled
// up to WANT). 2-line plays are the easiest tier — a friendly board has
// few stacks, so we bias toward small boards.
//
// Per Steve's puzzle-curation guidance (2026-05-16): curation programs
// bit-rot as BFS evolves; throw them away after the curation pass. The
// output (the puzzle DSL) is what's durable.

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
const TARGET_PLAN_LENGTH = 2;
const WANT = 10;

const SEEDS = Array.from({ length: 30 }, (_, i) => i + 1);

interface Hit {
  readonly seed: number;
  readonly turn: number;
  readonly player: number;
  readonly augmented: readonly BoardStack[];
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
        // The puzzle = the augmented board BFS solves: [...board, cardsToPlay].
        // We append cardsToPlay as a fresh BoardStack at a non-overlapping loc
        // so the UI renders the puzzle exactly as BFS sees it.
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

    const drawCount = handEmptiedThisTurn ? 5 : playsThisTurn === 0 ? 3 : 0;
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
  return `${TARGET_PLAN_LENGTH}line_${sortedVerbs}_s${hit.seed}t${hit.turn}p${hit.player}`;
}

function boardSig(hit: Hit): string {
  return hit.augmented.map(formatBoardStackLine).join("|");
}

// Total cards on the board — the puzzle-ordering key (fewest first =
// cleanest first), and the tiebreak for "cleanest representative" of a
// verb-multiset.
function cardCount(hit: Hit): number {
  return hit.augmented.reduce((n, s) => n + s.cards.length, 0);
}

function dumpPuzzleDsl(hit: Hit): void {
  console.log(`puzzle ${puzzleName(hit)}`);
  for (const s of hit.augmented) console.log(`  ${formatBoardStackLine(s)}`);
  console.log();
}

// Diverse subset: one puzzle per verb-multiset first (max variety),
// each the cleanest (fewest-cards) board for that multiset. If distinct
// multisets < WANT, round-robin in the next-cleanest boards (distinct
// boards only) until WANT is reached.
function pickDiverse(hits: readonly Hit[]): Hit[] {
  const byKey = new Map<string, Hit[]>();
  for (const h of hits) {
    const k = verbKey(h.verbs);
    if (!byKey.has(k)) byKey.set(k, []);
    byKey.get(k)!.push(h);
  }
  for (const g of byKey.values()) {
    g.sort((a, b) => cardCount(a) - cardCount(b));
  }
  const keys = [...byKey.keys()].sort();
  const picked: Hit[] = [];
  const seen = new Set<string>();
  let round = 0;
  while (picked.length < WANT) {
    let progressed = false;
    for (const k of keys) {
      if (picked.length >= WANT) break;
      const g = byKey.get(k)!;
      if (round < g.length) {
        progressed = true;
        const h = g[round]!;
        const sig = boardSig(h);
        if (!seen.has(sig)) {
          seen.add(sig);
          picked.push(h);
        }
      }
    }
    if (!progressed) break;
    round++;
  }
  return picked;
}

function main(): void {
  const emitDsl = process.argv.includes("--emit-dsl");
  const allHits: Hit[] = [];
  for (const seed of SEEDS) allHits.push(...findInSeed(seed));
  // Diverse picks, then ordered by total cards on the board (fewest
  // first) — the gallery presents each tier cleanest-board-first.
  const subset = pickDiverse(allHits).sort((a, b) => cardCount(a) - cardCount(b));

  if (emitDsl) {
    const today = new Date().toISOString().slice(0, 10);
    console.log(`# Curated ${TARGET_PLAN_LENGTH}-line Lyn Rummy puzzles.`);
    console.log(`#`);
    console.log(`# Generated ${today} from agent self-play across seeds ${SEEDS[0]}–${SEEDS[SEEDS.length - 1]}.`);
    console.log(`# Each board is a dirty state that the BFS solver resolves in exactly`);
    console.log(`# ${TARGET_PLAN_LENGTH} verb-level moves — the easiest tier. Curated for variety`);
    console.log(`# (one puzzle per verb-multiset), then ordered by total cards on the`);
    console.log(`# board (fewest first). Names encode the sorted verb-multiset +`);
    console.log(`# provenance (s<seed>t<turn>p<player>).`);
    console.log(`#`);
    console.log(`# Format matches curated_4line_puzzles.dsl. UI: the server (puzzles.zig) consumes`);
    console.log(`# directly. No conformance — these are surfacing-only puzzles.`);
    console.log();
    for (const hit of subset) dumpPuzzleDsl(hit);
    return;
  }

  console.log(`=== sweep: seeds ${SEEDS[0]}..${SEEDS[SEEDS.length - 1]} — ${allHits.length} total ${TARGET_PLAN_LENGTH}-line plays ===`);
  console.log();

  const verbsCovered = new Set<string>();
  for (const h of allHits) for (const v of h.verbs) verbsCovered.add(v);
  console.log(`Verbs seen (any position): ${[...verbsCovered].sort().join(", ")}`);
  console.log();

  const byVerbKey = new Map<string, number>();
  for (const h of allHits) byVerbKey.set(verbKey(h.verbs), (byVerbKey.get(verbKey(h.verbs)) ?? 0) + 1);
  console.log(`Distinct verb-multisets: ${byVerbKey.size}`);
  for (const [k, n] of [...byVerbKey.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  [${k}] — ${n} hit(s)`);
  }
  console.log();

  console.log(`=== diverse subset (${subset.length}) ===`);
  console.log();
  for (const hit of subset) dumpPuzzleDsl(hit);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
