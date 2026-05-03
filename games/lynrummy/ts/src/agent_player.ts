// agent_player.ts — agent self-play loop for Lyn Rummy.
//
// One turn:
//   while hand has cards:
//     play = findPlay(hand, board)
//     if play === null: break               (stuck)
//     apply play → new (board, hand)
//     if hand empty: break                  (cleared)
//
// Turn-end draw rule (per Steve, 2026-05-03):
//   stuck (couldn't make ANY further play):  draw 3
//   played whole hand:                       draw 5
//
// `playFullGame` loops turns until the deck reaches a low-water mark
// (default 10 — past that, gameplay is essentially over and self-play
// stops being informative).
//
// This module is the canonical agent driver in TS. The engine v2 A*
// solver is reached via `findPlay` (hand_play.ts) for hint generation
// and `solveStateWithDescs` (engine_v2.ts) for replaying a chosen play
// to derive the new clean board.

import type { Card } from "./rules/card.ts";
import type { Buckets, RawBuckets } from "./buckets.ts";
import { classifyBuckets } from "./buckets.ts";
import { classifyStack, type ClassifiedCardStack } from "./classified_card_stack.ts";
import { findPlay, type PlayResult } from "./hand_play.ts";
import { solveStateWithDescs } from "./engine_v2.ts";
import { describe, type Desc } from "./move.ts";
import { enumerateMoves } from "./enumerator.ts";

// --- Plan replay (apply a plan to derive the post-plan Buckets) -----

function applyPlan(initial: Buckets, plan: readonly { desc: Desc }[]): Buckets {
  let state: Buckets = initial;
  for (let step = 0; step < plan.length; step++) {
    const want = describe(plan[step]!.desc);
    let matched: Buckets | null = null;
    for (const [desc, next] of enumerateMoves(state)) {
      if (describe(desc) === want) { matched = next; break; }
    }
    if (matched === null) {
      throw new Error(`step ${step + 1}: enumerator did not yield matching move "${want}"`);
    }
    state = matched;
  }
  return state;
}

// --- One find_play → mutate (board, hand) ---------------------------

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

// --- Invariant assertions --------------------------------------------
//
// Per memory/feedback_dont_paper_over_problems.md: invariants are
// permanent (always-on, throw on violation). These run after every
// applyHandPlay + at the end of every turn. If any fire, the agent's
// internal state has diverged from what the rules guarantee — every
// downstream symptom (transcript drift, replay confusion, geometry
// chaos) cascades from here.

/** Every stack on the board must classify as a legal length-3+ kind
 *  (run / rb / set). The BFS guarantee is that every applyHandPlay
 *  produces a clean board; if this fires, either the BFS was wrong
 *  or applyPlan diverged from solveStateWithDescs. */
function assertBoardClean(
  board: readonly (readonly Card[])[],
  ctx: string,
): void {
  for (let i = 0; i < board.length; i++) {
    const stack = board[i]!;
    const ccs: ClassifiedCardStack | null = classifyStack(stack);
    if (ccs === null) {
      throw new Error(
        `[agent_player ${ctx}] stack ${i} failed to classify: [${stack.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.n < 3) {
      throw new Error(
        `[agent_player ${ctx}] stack ${i} length ${ccs.n} (${ccs.kind}) — not graduated: [${stack.map(cardKey).join(" ")}]`,
      );
    }
    if (ccs.kind !== "run" && ccs.kind !== "rb" && ccs.kind !== "set") {
      throw new Error(
        `[agent_player ${ctx}] stack ${i} kind ${ccs.kind} not a length-3+ legal kind: [${stack.map(cardKey).join(" ")}]`,
      );
    }
  }
}

function totalCardCount(board: readonly (readonly Card[])[]): number {
  let n = 0;
  for (const s of board) n += s.length;
  return n;
}

function collectCardKeys(
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  deck: readonly Card[],
): string[] {
  const keys: string[] = [];
  for (const s of board) for (const c of s) keys.push(cardKey(c));
  for (const c of hand) keys.push(cardKey(c));
  for (const c of deck) keys.push(cardKey(c));
  return keys.sort();
}

/** Card conservation: nothing appears twice, nothing disappears. */
function assertCardsConserved(
  expected: readonly string[],
  board: readonly (readonly Card[])[],
  hand: readonly Card[],
  deck: readonly Card[],
  ctx: string,
): void {
  const got = collectCardKeys(board, hand, deck);
  if (got.length !== expected.length) {
    throw new Error(
      `[agent_player ${ctx}] card-count drift: expected ${expected.length}, got ${got.length} (board=${totalCardCount(board)} hand=${hand.length} deck=${deck.length})`,
    );
  }
  for (let i = 0; i < got.length; i++) {
    if (got[i] !== expected[i]) {
      throw new Error(
        `[agent_player ${ctx}] card-set drift at sorted index ${i}: expected ${expected[i]}, got ${got[i]}`,
      );
    }
  }
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

/** Apply a found play to (board, hand). Returns the post-turn state, or
 *  null if the engine can't replay (which shouldn't happen — findPlay
 *  already proved a clean-board plan exists). */
function applyHandPlay(
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
  const placedSet = new Set(play.placements.map(cardKey));
  const newHand = hand.filter(c => !placedSet.has(cardKey(c)));
  return { board: newBoard, hand: newHand, planDescs: plan.map(p => p.desc) };
}

// --- One turn ----------------------------------------------------------

/** Per-play record exposed for tracing harnesses. One PlayRecord per
 *  successful findPlay → applyHandPlay round-trip. */
export interface PlayRecord {
  readonly placements: readonly Card[];
  readonly planDescs: readonly Desc[];
  readonly findPlayMs: number;
  readonly applyMs: number;
}

export interface TurnResult {
  readonly playsMade: number;
  readonly cardsPlayed: readonly Card[];
  readonly outcome: "hand_empty" | "stuck";
  readonly board: readonly (readonly Card[])[];
  readonly hand: readonly Card[];
  readonly findPlayWallMsTotal: number;
  readonly applyWallMsTotal: number;
  readonly plays: readonly PlayRecord[];
}

export function playTurn(
  startBoard: readonly (readonly Card[])[],
  startHand: readonly Card[],
): TurnResult {
  let board = startBoard;
  let hand = startHand;
  const cardsPlayed: Card[] = [];
  const plays: PlayRecord[] = [];
  let playsMade = 0;
  let findPlayWallMsTotal = 0;
  let applyWallMsTotal = 0;

  while (hand.length > 0) {
    const t0 = performance.now();
    const play = findPlay(hand, board);
    const findPlayMs = performance.now() - t0;
    findPlayWallMsTotal += findPlayMs;
    if (play === null) {
      return {
        playsMade, cardsPlayed, outcome: "stuck",
        board, hand, findPlayWallMsTotal, applyWallMsTotal, plays,
      };
    }

    const t1 = performance.now();
    const next = applyHandPlay(board, hand, play);
    const applyMs = performance.now() - t1;
    applyWallMsTotal += applyMs;
    if (next === null) {
      // findPlay produced this play (proving a clean-board plan
      // exists), but applyHandPlay's engine call returned null.
      // That's a contradiction — two engine invocations on the same
      // augmented state disagreed on solvability. Don't paper over;
      // surface the bug.
      throw new Error(
        `[agent_player playTurn] applyHandPlay returned null for a play findPlay just produced. `
        + `This indicates a divergence between findPlay's engine call and applyHandPlay's `
        + `(both go through solveStateWithDescs). Placements: [${play.placements.map(cardKey).join(" ")}]. `
        + `Plan length: ${play.plan.length}.`,
      );
    }
    board = next.board;
    hand = next.hand;
    // INVARIANT: every applyHandPlay produces a clean board. The BFS
    // pipeline only returns plans that drive the augmented state to
    // victory; any failure here means the agent saw a "winning" plan
    // that didn't actually win.
    assertBoardClean(board, "playTurn after-play");
    plays.push({
      placements: [...play.placements],
      planDescs: next.planDescs,
      findPlayMs,
      applyMs,
    });
    for (const c of play.placements) cardsPlayed.push(c);
    playsMade++;
  }

  return {
    playsMade, cardsPlayed, outcome: "hand_empty",
    board, hand, findPlayWallMsTotal, applyWallMsTotal, plays,
  };
}

// --- Full game loop ----------------------------------------------------
//
// Lyn Rummy is a TWO-HAND game. "Solo" means one *user* (a human
// playing both sides, or an agent simulating both) — never one hand.
// The dealer rules (per python/dealer.py:142 + Elm Game.applyValidTurn):
//
//   1. Lay 23-card opening board.
//   2. Deal 15 to Player 1, 15 to Player 2 (51 left in deck).
//   3. Player 0 begins; alternate via active_player_index.
//   4. CompleteTurn → outgoing player draws 0/3/5 based on outcome:
//        - SuccessButNeedsCards (played 0)         → 3
//        - SuccessWithHandEmptied / SuccessAsVictor → 5
//        - Success (played some, hand non-empty)    → 0
//   5. nextActive = (outgoingIdx + 1) % nHands.
//
// playFullGame mirrors this exactly. Both hands are driven by the
// same agent brain (engine_v2 + findPlay); from a gameplay
// perspective it's solitaire-style self-play, but the wire-format
// shape matches what Elm + Python encode for "real" 2-player games.

export interface GameTurnRecord {
  readonly turnNum: number;
  readonly activePlayerIndex: number;
  readonly handBefore: number;
  readonly boardBefore: number;
  readonly playsMade: number;
  readonly cardsPlayedThisTurn: number;
  readonly outcome: "hand_empty" | "stuck";
  readonly drawCount: number;
  readonly cardsDrawn: number;
  readonly handAfter: number;
  readonly boardAfter: number;
  readonly deckRemaining: number;
  readonly turnWallMs: number;
  readonly findPlayWallMsTotal: number;
  readonly plays: readonly PlayRecord[];
}

export interface GameResult {
  readonly turns: readonly GameTurnRecord[];
  readonly finalBoard: readonly (readonly Card[])[];
  readonly finalHands: readonly (readonly Card[])[];
  readonly finalDeckSize: number;
  readonly stoppedReason: "deck_low" | "max_turns" | "hand_and_deck_empty";
  readonly totalWallMs: number;
}

export interface PlayGameOptions {
  readonly stopAtDeck?: number;
  readonly maxTurns?: number;
}

/** Compute draw count per the canonical Lyn Rummy rule (matches
 *  Elm `Game.applyValidTurn` drawCount + Python `_apply_complete_turn`).
 *  - hand emptied → 5
 *  - played zero → 3
 *  - played some, hand non-empty → 0 */
function drawCountFor(outcome: "hand_empty" | "stuck", cardsPlayedThisTurn: number): number {
  if (outcome === "hand_empty") return 5;
  if (cardsPlayedThisTurn === 0) return 3;
  return 0;
}

export function playFullGame(
  initialBoard: readonly (readonly Card[])[],
  initialHands: readonly (readonly Card[])[],
  initialDeck: readonly Card[],
  opts: PlayGameOptions = {},
): GameResult {
  const stopAtDeck = opts.stopAtDeck ?? 10;
  const maxTurns = opts.maxTurns ?? 200;

  let board = initialBoard;
  const hands: Card[][] = initialHands.map(h => [...h]);
  let deck = [...initialDeck];
  let activePlayerIndex = 0;
  const turns: GameTurnRecord[] = [];
  const tStart = performance.now();
  let stoppedReason: GameResult["stoppedReason"] = "max_turns";

  // Card-conservation baseline includes BOTH hands.
  const collectAllKeys = (): string[] => {
    const allHandsFlat: Card[] = [];
    for (const h of hands) for (const c of h) allHandsFlat.push(c);
    return collectCardKeys(board, allHandsFlat, deck);
  };
  const initialCardKeys = (() => {
    const flat: Card[] = [];
    for (const h of initialHands) for (const c of h) flat.push(c);
    return collectCardKeys(initialBoard, flat, initialDeck);
  })();

  for (let turnNum = 1; turnNum <= maxTurns; turnNum++) {
    const handBefore = hands[activePlayerIndex]!.length;
    const boardBefore = board.length;
    const tTurn0 = performance.now();
    const turn = playTurn(board, hands[activePlayerIndex]!);
    const turnWallMs = performance.now() - tTurn0;

    board = turn.board;
    hands[activePlayerIndex] = [...turn.hand];

    // INVARIANTS (apply per turn).
    const handMid = turn.hand.length;
    if (turn.outcome === "hand_empty" && handMid !== 0) {
      throw new Error(
        `[agent_player playFullGame] turn ${turnNum} player ${activePlayerIndex} `
        + `outcome=hand_empty but ${handMid} cards still in hand`,
      );
    }
    if (turn.outcome === "stuck" && handMid === 0) {
      throw new Error(
        `[agent_player playFullGame] turn ${turnNum} player ${activePlayerIndex} `
        + `outcome=stuck but hand is empty (should be hand_empty)`,
      );
    }
    if (handBefore - turn.cardsPlayed.length !== handMid) {
      throw new Error(
        `[agent_player playFullGame] turn ${turnNum} player ${activePlayerIndex} `
        + `hand arithmetic: handBefore (${handBefore}) - cardsPlayed (${turn.cardsPlayed.length}) `
        + `= ${handBefore - turn.cardsPlayed.length}, expected handMid ${handMid}`,
      );
    }

    // Draw for the outgoing (active) player.
    const drawCount = drawCountFor(turn.outcome, turn.cardsPlayed.length);
    const cardsDrawn = Math.min(drawCount, deck.length);
    if (cardsDrawn > 0) {
      hands[activePlayerIndex] = [...hands[activePlayerIndex]!, ...deck.slice(0, cardsDrawn)];
      deck = deck.slice(cardsDrawn);
    }

    // INVARIANT: card conservation across the entire game.
    void collectAllKeys;
    assertCardsConserved(
      initialCardKeys,
      board,
      // Flatten all hands for the conservation check.
      ([] as Card[]).concat(...hands),
      deck,
      `playFullGame turn ${turnNum}`,
    );

    turns.push({
      turnNum,
      activePlayerIndex,
      handBefore,
      boardBefore,
      playsMade: turn.playsMade,
      cardsPlayedThisTurn: turn.cardsPlayed.length,
      outcome: turn.outcome,
      drawCount,
      cardsDrawn,
      handAfter: hands[activePlayerIndex]!.length,
      boardAfter: board.length,
      deckRemaining: deck.length,
      turnWallMs,
      findPlayWallMsTotal: turn.findPlayWallMsTotal,
      plays: turn.plays,
    });

    if (deck.length <= stopAtDeck) {
      stoppedReason = "deck_low";
      break;
    }
    if (hands[activePlayerIndex]!.length === 0 && deck.length === 0) {
      stoppedReason = "hand_and_deck_empty";
      break;
    }

    // Switch active player. Mirrors Elm's
    // `nextActive = modBy nHands (outgoingIdx + 1)`.
    activePlayerIndex = (activePlayerIndex + 1) % hands.length;
  }

  return {
    turns,
    finalBoard: board,
    finalHands: hands.map(h => [...h]),
    finalDeckSize: deck.length,
    stoppedReason,
    totalWallMs: performance.now() - tStart,
  };
}
