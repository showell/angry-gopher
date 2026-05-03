// end_of_deck_perf.ts — single-agent self-play to ≤10-card deck.
//
// Steve, 2026-05-03: "play a few full games to the end of the deck
// (10 cards left) to make sure [engine_v2] performs well with large
// boards." This driver runs the agent_player loop with a fixed
// opening board (Game 17) and a mulberry32-seeded shuffle of the
// remaining 81 cards; deals 15 to hand; loops turns until the deck
// reaches the low-water mark.
//
// Per-turn timing focuses on findPlay wall (the engine_v2 hot path),
// since that's what dominates as the board grows.
//
// Usage:
//   node bench/end_of_deck_perf.ts                # default: seeds 42,43,44
//   node bench/end_of_deck_perf.ts 100 101        # custom seed list
//   node bench/end_of_deck_perf.ts --trace 44     # markdown per-verb trace
//                                                  for one seed

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel, cardLabel } from "../src/rules/card.ts";
import { playFullGame, type GameResult } from "../src/agent_player.ts";
import { describe, type Desc } from "../src/move.ts";

const HAND_SIZE = 15;
const STOP_AT_DECK = 10;

// Game 17 opening board — same as bench_outer_shell + python/dealer.py.
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
  if (out.length !== 81) throw new Error(`expected 81 remaining; got ${out.length}`);
  return out;
}

// mulberry32 — deterministic, seedable, native to JS. Same PRNG used
// by bench_outer_shell.
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

function totalCardsOnBoard(board: readonly (readonly Card[])[]): number {
  let n = 0;
  for (const s of board) n += s.length;
  return n;
}

function reportGame(seed: number, result: GameResult): void {
  console.log();
  console.log(`=== seed ${seed} — ${result.turns.length} turns, stopped: ${result.stoppedReason} ===`);
  console.log(`final: hand=${result.finalHand.length}  board=${result.finalBoard.length} stacks (${totalCardsOnBoard(result.finalBoard)} cards)  deck=${result.finalDeckSize}  total_wall=${result.totalWallMs.toFixed(0)}ms`);
  console.log();
  console.log(
    "turn  hand start→played→drew→end   board→         plays  outcome      find_play_ms  turn_ms",
  );
  console.log("-".repeat(94));
  for (const t of result.turns) {
    const handMid = t.handBefore - t.cardsPlayedThisTurn;
    const stacksStr = `${t.boardBefore}→${t.boardAfter}`;
    const handStr = `${String(t.handBefore).padStart(2)}→${String(t.cardsPlayedThisTurn).padStart(2)}→${String(handMid).padStart(2)}+${String(t.cardsDrawn).padStart(1)}=${String(t.handAfter).padStart(2)}`;
    const outcomeStr = t.outcome.padEnd(11);
    console.log(
      `${String(t.turnNum).padStart(3)}   ${handStr}    ${stacksStr.padStart(5)}        ${
        String(t.playsMade).padStart(4)
      }   ${outcomeStr}    ${
        t.findPlayWallMsTotal.toFixed(0).padStart(8)
      }    ${
        t.turnWallMs.toFixed(0).padStart(5)
      }`,
    );
  }
  // Worst find_play turn
  let worst = result.turns[0]!;
  for (const t of result.turns) if (t.findPlayWallMsTotal > worst.findPlayWallMsTotal) worst = t;
  console.log();
  console.log(
    `worst find_play turn: #${worst.turnNum} — ${worst.findPlayWallMsTotal.toFixed(0)}ms ` +
    `(hand=${worst.handBefore}, board=${worst.boardBefore} stacks)`,
  );
}

function verbName(d: Desc): string {
  if (d.type === "extract_absorb") return d.verb;
  return d.type;
}

function describeShort(d: Desc, max = 78): string {
  const s = describe(d);
  return s.length > max ? s.slice(0, max - 3) + "..." : s;
}

/** Emit a markdown per-verb trace for one game. One row per place /
 *  plan-step verb; each play's findPlay wall is on the placement
 *  row, plan-step continuations show "—". */
function emitTrace(seed: number, result: GameResult): void {
  const out: string[] = [];
  out.push(`# Game trace — seed ${seed}, engine_v2 + liveness prune + maxPlanLength=4`);
  out.push("");
  out.push(`Total wall: ${result.totalWallMs.toFixed(0)} ms across ${result.turns.length} turns. Stopped: ${result.stoppedReason}.`);
  out.push("");
  out.push("## Per-turn summary");
  out.push("");
  out.push("| Turn | hand start | played | hand mid | drew | hand end | board→ | plays | outcome | find_play_ms | turn_ms |");
  out.push("|----:|----:|----:|----:|----:|----:|:----:|----:|:----|----:|----:|");
  for (const t of result.turns) {
    const handMid = t.handBefore - t.cardsPlayedThisTurn;
    const board = `${t.boardBefore}→${t.boardAfter}`;
    out.push(
      `| ${t.turnNum} | ${t.handBefore} | ${t.cardsPlayedThisTurn} | ${handMid} | ${t.cardsDrawn} | ${t.handAfter} | ${board} | ${t.playsMade} | ${t.outcome} | ${t.findPlayWallMsTotal.toFixed(0)} | ${t.turnWallMs.toFixed(0)} |`,
    );
  }
  out.push("");
  out.push("## Per-verb trace");
  out.push("");
  out.push("First row of each play shows the `find_play` wall; plan-step rows show `—`.");
  out.push("");
  out.push("| Turn | Play | find_ms | Verb | Description |");
  out.push("|----:|----:|----:|:----|:----|");
  for (const t of result.turns) {
    let p = 0;
    for (const play of t.plays) {
      p++;
      const placeLabel = play.placements.map(cardLabel).join(" ");
      out.push(`| ${t.turnNum} | ${p} | ${play.findPlayMs.toFixed(0)} | \`place\` | ${placeLabel} from hand |`);
      for (const d of play.planDescs) {
        const desc = describeShort(d).replace(/\|/g, "\\|");
        out.push(`| ${t.turnNum} | ${p} | — | \`${verbName(d)}\` | ${desc} |`);
      }
    }
  }
  process.stdout.write(out.join("\n") + "\n");
}

function main(): void {
  const args = process.argv.slice(2);
  const traceIdx = args.indexOf("--trace");
  const trace = traceIdx >= 0;
  if (trace) args.splice(traceIdx, 1);
  const seeds = args.length > 0
    ? args.map(s => parseInt(s, 10))
    : [42, 43, 44];

  for (const seed of seeds) {
    const rand = mulberry32(seed);
    const remaining = shuffle(remainingCards(), rand);
    const hand = remaining.slice(0, HAND_SIZE);
    const deck = remaining.slice(HAND_SIZE);
    const board = makeOpeningBoard();

    const result = playFullGame(board, hand, deck, { stopAtDeck: STOP_AT_DECK });
    if (trace) emitTrace(seed, result);
    else reportGame(seed, result);
  }
}

main();
