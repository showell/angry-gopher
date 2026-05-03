// trace_game.ts — full self-play trace, one row per verb, with timings.
//
// Replays end_of_deck_perf for a single seed but instruments the per-
// turn loop directly: each find_play call's wall is recorded and
// attributed to the FIRST verb of the play it produced. Subsequent
// verbs in the same play row inherit the wall (— in the column).
//
// Output is markdown-formatted on stdout, ready to paste into an essay
// surface or pipe to a file.
//
// Usage:
//   node bench/trace_game.ts          # default seed 44
//   node bench/trace_game.ts 42       # custom

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel, cardLabel } from "../src/rules/card.ts";
import type { Buckets, RawBuckets } from "../src/buckets.ts";
import { classifyBuckets } from "../src/buckets.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { findPlay, type PlayResult } from "../src/hand_play.ts";
import { solveStateWithDescs, type PlanLine } from "../src/engine_v2.ts";
import { type Desc, describe } from "../src/move.ts";
import { enumerateMoves } from "../src/enumerator.ts";

const HAND_SIZE = 15;
const STOP_AT_DECK = 10;

const BOARD_LABELS: string[][] = [
  ["KS", "AS", "2S", "3S"],
  ["TD", "JD", "QD", "KD"],
  ["2H", "3H", "4H"],
  ["7S", "7D", "7C"],
  ["AC", "AD", "AH"],
  ["2C", "3D", "4C", "5H", "6S", "7H"],
];

function makeOpeningBoard(): readonly (readonly Card[])[] {
  return BOARD_LABELS.map(s => s.map(parseCardLabel));
}

function remainingCards(): Card[] {
  const onBoard = new Set<string>();
  for (const stack of BOARD_LABELS)
    for (const lbl of stack) {
      const c = parseCardLabel(lbl);
      onBoard.add(`${c[0]},${c[1]},${c[2]}`);
    }
  const out: Card[] = [];
  for (let s = 0; s < 4; s++)
    for (let v = 1; v <= 13; v++)
      for (const d of [0, 1] as const) {
        const c: Card = [v, s, d] as const;
        if (!onBoard.has(`${c[0]},${c[1]},${c[2]}`)) out.push(c);
      }
  return out;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
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

// --- Plan replay (mirror agent_player.ts logic; uses classifyBuckets +
// enumerateMoves; takes the engine_v2 plan and walks it). ----------------

function applyPlan(initial: Buckets, plan: readonly { desc: Desc }[]): Buckets {
  let state: Buckets = initial;
  for (let step = 0; step < plan.length; step++) {
    const want = describe(plan[step]!.desc);
    let matched: Buckets | null = null;
    for (const [desc, next] of enumerateMoves(state)) {
      if (describe(desc) === want) { matched = next; break; }
    }
    if (matched === null) {
      throw new Error(`step ${step + 1}: no matching move for "${want}"`);
    }
    state = matched;
  }
  return state;
}

function partition(
  augmented: readonly (readonly Card[])[],
): { helper: (readonly Card[])[]; trouble: (readonly Card[])[] } {
  const helper: (readonly Card[])[] = [];
  const trouble: (readonly Card[])[] = [];
  for (const stack of augmented) {
    const ccs = classifyStack(stack);
    if (ccs === null || ccs.n < 3) trouble.push(stack);
    else helper.push(stack);
  }
  return { helper, trouble };
}

function applyPlay(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  play: PlayResult,
): { board: readonly (readonly Card[])[]; hand: readonly Card[]; planDescs: readonly Desc[] } | null {
  const { helper, trouble } = partition([...board, [...play.placements]]);
  const initial: RawBuckets = { helper, trouble, growing: [], complete: [] };
  const classified = classifyBuckets(initial);
  const plan = solveStateWithDescs(classified, { maxStates: 50000, maxTroubleOuter: 12 });
  if (plan === null) return null;
  const final = applyPlan(classified, plan);
  const newBoard: (readonly Card[])[] = [
    ...final.helper.map(s => [...s.cards] as readonly Card[]),
    ...final.complete.map(s => [...s.cards] as readonly Card[]),
  ];
  const placedSet = new Set(play.placements.map(c => `${c[0]},${c[1]},${c[2]}`));
  const newHand = hand.filter(c => !placedSet.has(`${c[0]},${c[1]},${c[2]}`));
  return { board: newBoard, hand: newHand, planDescs: plan.map(p => p.desc) };
}

// --- Verb classification ---------------------------------------------

function verbName(d: Desc): string {
  if (d.type === "extract_absorb") return d.verb;
  return d.type;
}

function describeShort(d: Desc): string {
  // Use the canonical describe() but trim noise for table density.
  const s = describe(d);
  return s.length > 78 ? s.slice(0, 75) + "..." : s;
}

// --- Trace structure --------------------------------------------------

interface TraceRow {
  turn: number;
  play: number;
  verb: string;
  desc: string;
  findPlayMs: number | null;  // null if continuation of same play
  handAfter: number;
  boardAfter: number;
}

interface TurnSummary {
  turn: number;
  handBefore: number;
  boardBefore: number;
  playsMade: number;
  outcome: "stuck" | "hand_empty";
  cardsDrawn: number;
  handAfter: number;
  boardAfter: number;
  deckAfter: number;
  turnWallMs: number;
  findPlayWallMsTotal: number;
}

// --- Game loop with full instrumentation -----------------------------

function traceGame(seed: number): { rows: TraceRow[]; turns: TurnSummary[] } {
  const rand = mulberry32(seed);
  const remaining = shuffle(remainingCards(), rand);
  let hand: readonly Card[] = remaining.slice(0, HAND_SIZE);
  let deck: Card[] = remaining.slice(HAND_SIZE);
  let board: readonly (readonly Card[])[] = makeOpeningBoard();
  const rows: TraceRow[] = [];
  const turns: TurnSummary[] = [];

  for (let turn = 1; turn <= 100; turn++) {
    const handBefore = hand.length;
    const boardBefore = board.length;
    const tTurn0 = performance.now();
    let playsMade = 0;
    let findPlayWallMsTotal = 0;
    let outcome: "stuck" | "hand_empty" = "stuck";

    while (hand.length > 0) {
      const t0 = performance.now();
      const play = findPlay(hand, board);
      const findPlayMs = performance.now() - t0;
      findPlayWallMsTotal += findPlayMs;
      if (play === null) { outcome = "stuck"; break; }
      const next = applyPlay(board, hand, play);
      if (next === null) { outcome = "stuck"; break; }

      playsMade++;
      // Row 1 of this play: place hand card(s).
      const placeLabel = play.placements.map(cardLabel).join(" ");
      board = next.board;
      hand = next.hand;
      rows.push({
        turn, play: playsMade,
        verb: "place",
        desc: `${placeLabel} from hand`,
        findPlayMs,
        handAfter: hand.length,
        boardAfter: board.length,
      });
      // Subsequent rows: each plan step (a BFS verb).
      for (const d of next.planDescs) {
        rows.push({
          turn, play: playsMade,
          verb: verbName(d),
          desc: describeShort(d),
          findPlayMs: null,
          handAfter: hand.length,
          boardAfter: board.length,
        });
      }
      if (hand.length === 0) { outcome = "hand_empty"; break; }
    }

    const turnWallMs = performance.now() - tTurn0;
    const drawAmount = outcome === "hand_empty" ? 5 : 3;
    const cardsDrawn = Math.min(drawAmount, deck.length);
    if (cardsDrawn > 0) {
      hand = [...hand, ...deck.slice(0, cardsDrawn)];
      deck = deck.slice(cardsDrawn);
    }
    turns.push({
      turn, handBefore, boardBefore,
      playsMade, outcome, cardsDrawn,
      handAfter: hand.length, boardAfter: board.length,
      deckAfter: deck.length, turnWallMs, findPlayWallMsTotal,
    });
    if (deck.length <= STOP_AT_DECK) break;
  }
  return { rows, turns };
}

// --- Markdown rendering -----------------------------------------------

function pad(s: string | number, n: number): string {
  return String(s).padEnd(n);
}

function render(seed: number, rows: TraceRow[], turns: TurnSummary[]): string {
  const lines: string[] = [];
  lines.push(`# Game trace — seed ${seed}, engine_v2 + liveness prune + maxPlanLength=4`);
  lines.push("");
  lines.push("## Per-turn summary");
  lines.push("");
  lines.push("| Turn | hand→ | board→ | plays | played | outcome | drew | find_play_ms | turn_ms |");
  lines.push("|----:|:----:|:----:|----:|----:|:----|----:|----:|----:|");
  for (const t of turns) {
    const hand = `${t.handBefore}→${t.handAfter}`;
    const board = `${t.boardBefore}→${t.boardAfter}`;
    const cardsPlayed = t.playsMade;  // approximate; placements counted in rows
    void cardsPlayed;
    lines.push(
      `| ${t.turn} | ${hand} | ${board} | ${t.playsMade} | — | ${t.outcome} | ${t.cardsDrawn} | ${t.findPlayWallMsTotal.toFixed(0)} | ${t.turnWallMs.toFixed(0)} |`,
    );
  }
  lines.push("");
  lines.push("## Per-verb trace");
  lines.push("");
  lines.push("Each play's `find_play` wall (ms) is on the first row (the placement); plan-step rows continuing the same play show `—`.");
  lines.push("");
  lines.push("| Turn | Play | find_ms | Verb | Description | hand | board |");
  lines.push("|----:|----:|----:|:----|:----|----:|----:|");
  for (const r of rows) {
    const ms = r.findPlayMs === null ? "—" : r.findPlayMs.toFixed(0);
    // Markdown-escape pipes in description.
    const desc = r.desc.replace(/\|/g, "\\|");
    lines.push(`| ${r.turn} | ${r.play} | ${ms} | \`${r.verb}\` | ${desc} | ${r.handAfter} | ${r.boardAfter} |`);
  }
  return lines.join("\n");
}

// --- Main -------------------------------------------------------------

function main(): void {
  const seedArg = process.argv[2];
  const seed = seedArg ? parseInt(seedArg, 10) : 44;
  const { rows, turns } = traceGame(seed);
  process.stdout.write(render(seed, rows, turns) + "\n");
}

main();
