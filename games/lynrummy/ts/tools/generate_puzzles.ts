// generate_puzzles.ts — emit games/lynrummy/puzzles/puzzles.json from
// agent self-play.
//
// The agent plays full games against the canonical Game 17 opening
// board (matching bench/end_of_deck_perf.ts + bench/gen_baseline_board.ts
// + python/dealer.py, all of which agree on the 6-helper / 23-card
// fixed deal). For each shuffle seed we run one game; we look for a
// turn-play where:
//
//   1. the engine_v2 A* solver returns a plan of EXACTLY 3 plan-lines
//      (recorded as PlayRecord.planDescs.length === 3), and
//   2. the augmented board (existing helpers + the play's placements)
//      contains AT LEAST 30 cards.
//
// At the first qualifying play we capture the augmented positioned
// board as the puzzle's `initial_state.board` (hands empty, deck empty
// — these puzzles are board-only). Then we move on to the next deck
// seed; one puzzle per deck, max. We stop at TARGET_PUZZLES = 5.
//
// The `discard` field that lived in the legacy Python-mined catalog
// is NOT emitted — Wire.initialStateDecoder doesn't read it, and the
// Phase-0 inventory confirmed Elm silently ignores it.
//
// Naming: `a3_NNN_seedSSS` (A* engine, 3-line plan, three-digit puzzle
// index, deck-shuffle seed). Title is `<name> (3-line)` to match the
// convention the legacy `mined_NNN_*` entries used.
//
// Usage:
//   node tools/generate_puzzles.ts
//
// No CLI args by design: TARGET_PUZZLES is a constant in the source
// (Steve dislikes CLI knobs that bitrot).

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel } from "../src/rules/card.ts";
import type { BoardStack, Loc } from "../src/geometry.ts";
import { findOpenLoc } from "../src/geometry.ts";
import { playFullGame, type PlayRecord } from "../src/agent_player.ts";
import { physicalPlan } from "../src/physical_plan.ts";
import { applyLocally } from "../src/primitives.ts";
import { encodeInitialState, type RemoteStateJson } from "../src/transcript.ts";

// --- Tunables (constants, NOT CLI args) -----------------------------

const TARGET_PUZZLES = 5;
const MIN_BOARD_CARDS = 30;
const TARGET_PLAN_LINES = 3;
const MAX_SEEDS_TRIED = 200;  // safety cap; we expect 5 puzzles well before this
const HAND_SIZE = 15;
const NUM_PLAYERS = 2;
const STOP_AT_DECK = 10;

// Game 17 opening board — same fixed deal as bench/end_of_deck_perf.ts
// and bench/gen_baseline_board.ts; the pattern dates back to the
// retired python/dealer.py. 6 helpers, 23 cards.
const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function boardLocFor(row: number): Loc {
  // Mirror of dealer.go's initial-board layout, kept in lockstep with
  // bench/end_of_deck_perf.ts so transcripts and puzzles render the
  // same on a fresh-replay bootstrap.
  const col = (row * 3 + 1) % 5;
  return { top: 20 + row * 60, left: 40 + col * 30 };
}

function makeOpeningBoardPositioned(): BoardStack[] {
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

// mulberry32 — same PRNG as bench/end_of_deck_perf.ts so puzzle seeds
// reproduce with the standing perf harness.
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

// --- Cards-on-the-board metric --------------------------------------
//
// "Total cards visible across all stacks on the board" — sum of stack
// lengths. No helper exists in src/ specifically for this (the closest
// is `totalCardCount` private to agent_player.ts), so we redefine it
// here. Trivially correct.

function cardsOnBoard(board: readonly BoardStack[]): number {
  let n = 0;
  for (const s of board) n += s.cards.length;
  return n;
}

// --- Augmented board synthesis ---------------------------------------
//
// Given a positioned board sim and a play's placements, build the
// "augmented" board the solver actually operates on: existing stacks
// + a new stack carrying the placement cards at a freshly-found loc.
// For single-card placements the new stack is a 1-card singleton
// (which the solver classifies as `kind=singleton`, an absorber);
// for multi-card placements the cards form one fresh stack at a loc
// sized for the placement count.
//
// This mirrors the augmented-buckets shape `applyPlay` constructs
// in agent_player.ts (`partition([...board, [...play.placements]])`),
// just lifted to the positioned-stack representation so we can serialize
// it as `initial_state.board`.

function augmentedBoard(
  sim: readonly BoardStack[],
  placements: readonly Card[],
): BoardStack[] {
  const loc = findOpenLoc(sim, placements.length);
  return [...sim, { cards: [...placements], loc }];
}

// --- Sim advancement (matches transcript.ts's per-play sim threading)
//
// To advance the positioned sim across a play we need to walk the
// physical-plan primitive sequence. transcript.ts does the same thing
// to render its action log; we reuse `physicalPlan` + `applyLocally`
// here so positions stay in lockstep with what the Elm UI would render.

function advanceSim(sim: readonly BoardStack[], play: PlayRecord): readonly BoardStack[] {
  const prims = physicalPlan(sim, play.placements, play.planDescs);
  let cur = sim;
  for (const p of prims) cur = applyLocally(cur, p);
  return cur;
}

// --- Puzzle JSON shape (matches Wire.initialStateDecoder) -----------
//
// Delegates to `encodeInitialState` from src/transcript.ts (the
// canonical Wire.initialStateDecoder encoder used for live agent
// self-play sessions). Puzzles pass empty hands and an empty deck —
// the puzzle-specific contract (hands.length === 2, deck empty) lives
// here at the call site rather than in a sibling encoder, because the
// surface shape is identical and only the inputs differ. NO `discard`
// field — the Phase-0 inventory confirmed Elm's decoder doesn't ask
// for it and we're not perpetuating dead surface.

function encodePuzzleInitialState(board: readonly BoardStack[]): RemoteStateJson {
  // Two empty hands match the Lyn Rummy two-hand invariant the decoder
  // + Game logic expect; deck is empty because these are board-only
  // puzzles (no draws available, no further turns).
  return encodeInitialState(board, [[], []], []);
}

interface CapturedPuzzle {
  name: string;
  title: string;
  initial_state: RemoteStateJson;
}

// --- Capture loop ---------------------------------------------------

interface CaptureContext {
  readonly seed: number;
  readonly turnIndex: number;
  readonly playIndex: number;
  readonly boardCardCount: number;
}

function tryCaptureFromSeed(seed: number): { puzzle: CapturedPuzzle | null; ctx: CaptureContext | null } {
  const rand = mulberry32(seed);
  const remaining = shuffle(remainingCards(), rand);
  const hands: readonly (readonly Card[])[] = [
    remaining.slice(0, HAND_SIZE),
    remaining.slice(HAND_SIZE, NUM_PLAYERS * HAND_SIZE),
  ];
  const deck = remaining.slice(NUM_PLAYERS * HAND_SIZE);
  const initialBoard = makeOpeningBoardPositioned();

  // Run the full self-play game first; we then walk the recorded
  // turns/plays to find a qualifying capture point. We don't need to
  // rerun the engine — the planDescs on each PlayRecord is exactly
  // what solveStateWithDescs returned during play.
  const result = playFullGame(
    initialBoard.map(s => s.cards),  // bare-cards form for the engine
    hands,
    deck,
    { stopAtDeck: STOP_AT_DECK },
  );

  let sim: readonly BoardStack[] = initialBoard;
  for (let ti = 0; ti < result.turns.length; ti++) {
    const turn = result.turns[ti]!;
    for (let pi = 0; pi < turn.plays.length; pi++) {
      const play = turn.plays[pi]!;
      const aug = augmentedBoard(sim, play.placements);
      const cardCount = cardsOnBoard(aug);
      if (
        play.planDescs.length === TARGET_PLAN_LINES &&
        cardCount >= MIN_BOARD_CARDS
      ) {
        const idx = String(0).padStart(3, "0");  // overwritten by caller
        const name = `a3_${idx}_seed${seed}`;
        return {
          puzzle: {
            name,
            title: `${name} (${TARGET_PLAN_LINES}-line)`,
            initial_state: encodePuzzleInitialState(aug),
          },
          ctx: {
            seed,
            turnIndex: ti + 1,
            playIndex: pi + 1,
            boardCardCount: cardCount,
          },
        };
      }
      sim = advanceSim(sim, play);
    }
  }
  return { puzzle: null, ctx: null };
}

// --- Catalog emission ------------------------------------------------

function main(): void {
  const here = path.dirname(new URL(import.meta.url).pathname);
  const catalogPath = path.resolve(here, "../../puzzles/puzzles.json");

  const captured: CapturedPuzzle[] = [];
  const ctxs: CaptureContext[] = [];

  // Try seeds 1..MAX_SEEDS_TRIED until we have TARGET_PUZZLES.
  // One puzzle per seed maximum — once a deck yields, we move on.
  let seed = 1;
  while (captured.length < TARGET_PUZZLES && seed <= MAX_SEEDS_TRIED) {
    process.stdout.write(`[seed ${String(seed).padStart(3)}] running self-play... `);
    const { puzzle, ctx } = tryCaptureFromSeed(seed);
    if (puzzle !== null && ctx !== null) {
      const idx = String(captured.length + 1).padStart(3, "0");
      const renamed: CapturedPuzzle = {
        ...puzzle,
        name: `a3_${idx}_seed${seed}`,
        title: `a3_${idx}_seed${seed} (${TARGET_PLAN_LINES}-line)`,
      };
      captured.push(renamed);
      ctxs.push(ctx);
      console.log(
        `captured  (turn=${ctx.turnIndex}, play=${ctx.playIndex}, board=${ctx.boardCardCount} cards)  → ${renamed.name}`,
      );
    } else {
      console.log("no qualifying play; advancing");
    }
    seed++;
  }

  if (captured.length < TARGET_PUZZLES) {
    throw new Error(
      `Only captured ${captured.length}/${TARGET_PUZZLES} puzzles after ${seed - 1} seeds. ` +
      `Raise MAX_SEEDS_TRIED or relax constraints.`,
    );
  }

  const catalog = { puzzles: captured };
  fs.writeFileSync(catalogPath, JSON.stringify(catalog, null, 2) + "\n");
  console.log();
  console.log(`Wrote ${captured.length} puzzles to ${catalogPath}`);
  console.log("Summary:");
  for (let i = 0; i < captured.length; i++) {
    const ctx = ctxs[i]!;
    console.log(
      `  ${captured[i]!.name.padEnd(20)}  seed=${String(ctx.seed).padStart(3)}  ` +
      `turn=${String(ctx.turnIndex).padStart(2)}  play=${ctx.playIndex}  board=${ctx.boardCardCount} cards`,
    );
  }
}

main();
