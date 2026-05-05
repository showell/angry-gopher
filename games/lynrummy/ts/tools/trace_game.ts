// trace_game.ts — human-readable transcript of one agent self-play
// game. Emits one DSL-style line per physical move, grouped under
// GROOM / PLAY / COMPLETE_TURN headers, so we can publish to the
// essay surface and debug a game by reading it.
//
// Usage:
//   node tools/trace_game.ts            # default: seed 42
//   node tools/trace_game.ts 100        # custom seed

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel, cardLabel } from "../src/rules/card.ts";
import { simulateFullTurn } from "../src/agent_player.ts";
import type { JoinEvent } from "../src/agent_player.ts";
import type { BoardStack, Loc } from "../src/geometry.ts";
import { applyLocally } from "../src/primitives.ts";
import { primToDslLine } from "../src/wire_json.ts";
import { physicalPlan } from "../src/physical_plan.ts";
import { planMergeStackOnBoard } from "../src/verbs.ts";

const HAND_SIZE = 15;
const NUM_PLAYERS = 2;
const STOP_AT_DECK = 10;

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function boardLocFor(row: number): Loc {
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

function emitGroom(
  sim: BoardStack[],
  joins: readonly JoinEvent[],
  out: string[],
): BoardStack[] {
  out.push("GROOM" + (joins.length === 0 ? "  (no-op)" : ""));
  let cur: readonly BoardStack[] = sim;
  for (const j of joins) {
    // Reuse the same planner the transcript uses, so the trace shows
    // any pre-flight move_stack the merge required.
    const planned = planMergeStackOnBoard(cur, j.src, j.tgt, "left");
    for (const p of planned.prims) {
      out.push("  " + primToDslLine(p, cur));
      cur = applyLocally(cur, p);
    }
  }
  return [...cur];
}

function emitPlay(
  sim: BoardStack[],
  placements: readonly Card[],
  planDescs: readonly any[],
  out: string[],
): BoardStack[] {
  const placeLabel = placements.map(cardLabel).join(" ");
  out.push(`PLAY  place ${placeLabel}`);
  const prims = physicalPlan(sim, placements, planDescs);
  let cur: readonly BoardStack[] = sim;
  for (const p of prims) {
    out.push("  " + primToDslLine(p, cur));
    cur = applyLocally(cur, p);
  }
  return [...cur];
}

function main(): void {
  const args = process.argv.slice(2);
  const seed = args.length > 0 ? parseInt(args[0]!, 10) : 42;

  const rand = mulberry32(seed);
  const remaining = shuffle(remainingCards(), rand);
  const initialHands: (readonly Card[])[] = [
    remaining.slice(0, HAND_SIZE),
    remaining.slice(HAND_SIZE, NUM_PLAYERS * HAND_SIZE),
  ];
  const initialDeck = remaining.slice(NUM_PLAYERS * HAND_SIZE);

  // Two parallel boards: `sim` (positioned, for primitive rendering)
  // and `board` (cards-only, what simulateFullTurn consumes). They
  // stay in lockstep because we replay every primitive on `sim`.
  let sim: BoardStack[] = makeOpeningBoardPositioned();
  let board: readonly (readonly Card[])[] = sim.map(s => s.cards);
  let hands: readonly (readonly Card[])[] = initialHands.map(h => [...h]);
  let deck: readonly Card[] = [...initialDeck];
  let active = 0;

  const out: string[] = [];
  out.push(`# Agent self-play trace — seed ${seed}`);
  out.push("");

  let turnNum = 1;
  while (deck.length > STOP_AT_DECK && turnNum <= 200) {
    const handBefore = hands[active]!.length;
    out.push(`## Turn ${turnNum}  (Player ${active})`);
    out.push("");
    out.push("```");
    out.push(`hand_before: ${hands[active]!.map(cardLabel).join(" ") || "(empty)"}`);
    out.push("");

    const r = simulateFullTurn(board, hands[active]!, deck, turnNum, active);

    for (const step of r.record.steps) {
      if (step.kind === "groom") {
        sim = emitGroom(sim, step.joins, out);
      } else {
        sim = emitPlay(sim, step.placements, step.planDescs, out);
      }
    }

    const handLeft = handBefore - r.record.cardsPlayedThisTurn;
    const stuckSuffix = r.record.outcome === "stuck"
      ? `gave up with ${handLeft} card${handLeft === 1 ? "" : "s"} in hand: [${r.hand.slice(0, handLeft).map(cardLabel).join(" ")}]`
      : "hand emptied";
    out.push(`COMPLETE_TURN  ${r.record.outcome}; ${stuckSuffix}; drew ${r.record.cardsDrawn}`);
    out.push("```");
    out.push("");

    board = r.board;
    hands = hands.map((h, i) => i === active ? r.hand : h);
    deck = r.deck;
    active = (active + 1) % hands.length;
    turnNum++;
  }

  out.push("---");
  out.push("");
  out.push(`stopped: deck=${deck.length} (≤${STOP_AT_DECK}); ${turnNum - 1} turns played`);

  process.stdout.write(out.join("\n") + "\n");
}

main();
