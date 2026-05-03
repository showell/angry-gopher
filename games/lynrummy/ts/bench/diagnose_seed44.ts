// diagnose_seed44.ts — drill into the 6.2s findPlay outlier from
// end_of_deck_perf seed 44 turn 6.
//
// Replays the seed-44 game turn-by-turn through agent_player, captures
// the (hand, board) state going INTO the slow turn, then runs findPlay
// once with stats so we can see per-projection wall time + which
// (kind, cards) projection ate the budget.

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel, cardLabel } from "../src/rules/card.ts";
import { playTurn, type TurnResult } from "../src/agent_player.ts";
import { findPlay, type PlayStats } from "../src/hand_play.ts";
import { setSingletonDoomMode, type SingletonDoomMode } from "../src/enumerator.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { classifyBuckets, type RawBuckets } from "../src/buckets.ts";
import { solveStateWithDescs, lastVisits } from "../src/engine_v2.ts";

const HAND_SIZE = 15;
const STOP_AT_DECK = 10;
const SEED = 44;
const SLOW_TURN = 6;

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function makeOpeningBoard(): readonly (readonly Card[])[] {
  return BOARD_LABELS.map(stack => stack.map(parseCardLabel));
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
  return out;
}

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

function fmtCards(cards: readonly Card[]): string {
  return cards.map(cardLabel).join(" ");
}

function fmtBoard(board: readonly (readonly Card[])[]): string {
  return board.map(s => `[${fmtCards(s)}]`).join("\n  ");
}

// Replay seed-44 game; capture state going into turn `targetTurn`.
function captureStateAtTurn(targetTurn: number): {
  board: readonly (readonly Card[])[];
  hand: readonly Card[];
  deck: readonly Card[];
} {
  const rand = mulberry32(SEED);
  const remaining = shuffle(remainingCards(), rand);
  let hand: readonly Card[] = remaining.slice(0, HAND_SIZE);
  let deck: Card[] = remaining.slice(HAND_SIZE);
  let board: readonly (readonly Card[])[] = makeOpeningBoard();

  for (let turnNum = 1; turnNum < targetTurn; turnNum++) {
    const turn: TurnResult = playTurn(board, hand);
    board = turn.board;
    hand = turn.hand;
    const drawAmount = turn.outcome === "hand_empty" ? 5 : 3;
    const cardsDrawn = Math.min(drawAmount, deck.length);
    if (cardsDrawn > 0) {
      hand = [...hand, ...deck.slice(0, cardsDrawn)];
      deck = deck.slice(cardsDrawn);
    }
    if (deck.length <= STOP_AT_DECK) {
      throw new Error(`game ended at turn ${turnNum} before reaching turn ${targetTurn}`);
    }
  }
  return { board, hand, deck };
}

function runOne(state: ReturnType<typeof captureStateAtTurn>, mode: SingletonDoomMode): {
  wall: number; stats: PlayStats; result: ReturnType<typeof findPlay>;
} {
  setSingletonDoomMode(mode);
  const stats: PlayStats = { totalWallMs: 0, projections: [] };
  const t0 = performance.now();
  const result = findPlay(state.hand, state.board, { stats });
  const wall = performance.now() - t0;
  return { wall, stats, result };
}

function main(): void {
  console.log(`Replaying seed ${SEED} to turn ${SLOW_TURN}...`);
  const state = captureStateAtTurn(SLOW_TURN);

  console.log();
  console.log(`State going INTO turn ${SLOW_TURN}:`);
  console.log(`  hand (${state.hand.length}): ${fmtCards(state.hand)}`);
  console.log(`  board (${state.board.length} stacks):`);
  console.log(`    ${fmtBoard(state.board)}`);
  console.log(`  deck remaining: ${state.deck.length}`);
  console.log();

  // First findPlay of the turn under three doom-mode settings.
  for (const mode of ["off", "low", "high"] as const) {
    const { wall, stats, result } = runOne(state, mode);
    console.log(`SINGLETON_DOOM_MODE=${mode}:`);
    console.log(`  total: ${wall.toFixed(0)}ms — ${result === null ? "STUCK" : `play ${result.placements.length} card(s) + ${result.plan.length} step(s)`}`);
    const sorted = [...stats.projections].sort((a, b) => b.wallMs - a.wallMs);
    const top = sorted[0]!;
    console.log(`  worst projection: ${top.wallMs.toFixed(0)}ms — ${top.kind} ${fmtCards(top.cards)} ${top.foundPlan ? "yes" : "stuck"}`);
    console.log();
  }

  // Direct probe of the 8D singleton projection at multiple budgets to
  // see the visits-vs-wall curve.
  console.log();
  console.log("--- Direct probe: 8D singleton projection at varying budgets ---");
  setSingletonDoomMode("off");
  const eightD: Card = state.hand.find(c => c[0] === 8 && c[1] === 1)!;
  // Hand-rolled tryProjection (mirrors hand_play.ts internals).
  const augmented = [...state.board, [eightD]];
  const helper: (readonly Card[])[] = [];
  const trouble: (readonly Card[])[] = [];
  for (const s of augmented) {
    const ccs = classifyStack(s);
    if (ccs === null || ccs.n < 3) trouble.push(s);
    else helper.push(s);
  }
  const initial: RawBuckets = { helper, trouble, growing: [], complete: [] };
  const classified = classifyBuckets(initial);

  console.log("  budget    visits   wall_ms   plan");
  for (const budget of [500, 1000, 2000, 5000, 10000, 20000]) {
    const t0 = performance.now();
    const plan = solveStateWithDescs(classified, { maxStates: budget });
    const wall = performance.now() - t0;
    console.log(`  ${String(budget).padStart(6)}    ${String(lastVisits).padStart(6)}    ${wall.toFixed(0).padStart(6)}   ${plan === null ? "null" : `${plan.length} step(s)`}`);
  }

}

main();
