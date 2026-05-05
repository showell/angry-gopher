// agent_player.ts — agent self-play loop for Lyn Rummy.
//
// Two layers, smaller to larger:
//
//   1. simulateFullTurn(board, hand,  — one individual player's turn:
//      deck, turnNum)                   the play-from-hand loop
//      (findPlay → applyPlay until stuck or hand empty), per-turn
//      invariants, and the outcome-appropriate draw. Returns the
//      post-turn (board, hand, deck) plus a structured record. This
//      is the first-class boundary; when the human plays Player One
//      in the Elm UI and watches the agent play Player Two, the
//      agent's turn will be exactly one call to this function.
//   2. playFullGame(...)              — multi-hand orchestrator.
//      Tracks hands[] and the active-player index, picks the active
//      hand for each turn, calls simulateFullTurn on it, advances the
//      active player, loops until the deck runs low.
//
// Turn-end draw rule (canonical Lyn Rummy):
//   stuck (couldn't make ANY further play):  draw 3
//   played some, hand non-empty:             draw 0
//   played whole hand:                       draw 5
//
// Vocabulary (load-bearing across the codebase):
//   move  — one primitive UI action (place_hand, merge_stack, …).
//   play  — a sequence of moves that places ≥1 hand card and leaves
//           the board clean. What findPlay returns. What the hint
//           surface displays as one logical "do this."
//   turn  — a sequence of plays followed by the complete-turn event
//           (the draw). One individual player's turn.
//   game  — a sequence of turns alternating between players, until
//           the deck runs low.
//
// The engine_v2 A* solver is reached via `findPlay` (hand_play.ts)
// inside simulateFullTurn and via `solveStateWithDescs` (engine_v2.ts)
// inside applyPlay for replaying a chosen play to derive the new
// clean board.

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

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

// --- Invariant assertions --------------------------------------------
//
// Per memory/feedback_dont_paper_over_problems.md: invariants are
// permanent (always-on, throw on violation). These run after every
// applyPlay + at the end of every turn. If any fire, the agent's
// internal state has diverged from what the rules guarantee — every
// downstream symptom (transcript drift, replay confusion, geometry
// chaos) cascades from here.

/** Every stack on the board must classify as a legal length-3+ kind
 *  (run / rb / set). The BFS guarantee is that every applyPlay
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

/** Apply one play (the move-sequence findPlay returned) to (board, hand).
 *  Returns the post-play state, or null if the engine can't replay
 *  (which shouldn't happen — findPlay already proved a clean-board
 *  plan exists). */
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
  const placedSet = new Set(play.placements.map(cardKey));
  const newHand = hand.filter(c => !placedSet.has(cardKey(c)));
  return { board: newBoard, hand: newHand, planDescs: plan.map(p => p.desc) };
}

// --- Records ----------------------------------------------------------

/** Per-play record exposed for tracing harnesses. One PlayRecord per
 *  successful findPlay → applyPlay round-trip. */
export interface PlayRecord {
  readonly placements: readonly Card[];
  readonly planDescs: readonly Desc[];
  readonly findPlayMs: number;
  readonly applyMs: number;
}

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
 *  Elm `Game.applyValidTurn` drawCount).
 *  - hand emptied → 5
 *  - played zero → 3
 *  - played some, hand non-empty → 0 */
function drawCountFor(outcome: "hand_empty" | "stuck", cardsPlayedThisTurn: number): number {
  if (outcome === "hand_empty") return 5;
  if (cardsPlayedThisTurn === 0) return 3;
  return 0;
}

// --- One full turn ----------------------------------------------------

/** Run one individual player's full turn. Loops findPlay → applyPlay
 *  until the player runs out of plays or empties their hand, then
 *  applies the outcome-appropriate draw. Returns the post-turn
 *  (board, hand, deck) plus a structured record.
 *
 *  This is the first-class "one turn" boundary — the eventual
 *  human-watches-agent-as-Player-Two flow will dispatch one of these
 *  per opponent turn. The full-game loop (playFullGame) is a tiny
 *  while around it. */
export function simulateFullTurn(
  startBoard: readonly (readonly Card[])[],
  startHand: readonly Card[],
  startDeck: readonly Card[],
  turnNum: number,
  activePlayerIndex: number,
): {
  board: readonly (readonly Card[])[];
  hand: readonly Card[];
  deck: readonly Card[];
  record: GameTurnRecord;
} {
  const handBefore = startHand.length;
  const boardBefore = startBoard.length;
  const tTurn0 = performance.now();

  let board = startBoard;
  let hand = startHand;
  const cardsPlayed: Card[] = [];
  const plays: PlayRecord[] = [];
  let playsMade = 0;
  let findPlayWallMsTotal = 0;
  let applyWallMsTotal = 0;
  let outcome: "hand_empty" | "stuck";

  // The play loop: while the active player can still place hand
  // cards on a board that ends clean, do so.
  while (true) {
    if (hand.length === 0) { outcome = "hand_empty"; break; }

    const t0 = performance.now();
    const play = findPlay(hand, board);
    const findPlayMs = performance.now() - t0;
    findPlayWallMsTotal += findPlayMs;
    if (play === null) { outcome = "stuck"; break; }

    const t1 = performance.now();
    const next = applyPlay(board, hand, play);
    const applyMs = performance.now() - t1;
    applyWallMsTotal += applyMs;
    if (next === null) {
      // findPlay produced this play (proving a clean-board plan
      // exists), but applyPlay's engine call returned null. That's
      // a contradiction — two engine invocations on the same
      // augmented state disagreed on solvability. Don't paper over;
      // surface the bug.
      throw new Error(
        `[agent_player simulateFullTurn] applyPlay returned null for a play findPlay just produced. `
        + `This indicates a divergence between findPlay's engine call and applyPlay's `
        + `(both go through solveStateWithDescs). Placements: [${play.placements.map(cardKey).join(" ")}]. `
        + `Plan length: ${play.plan.length}.`,
      );
    }
    board = next.board;
    hand = next.hand;
    // INVARIANT: every applyPlay produces a clean board. The BFS
    // pipeline only returns plans that drive the augmented state to
    // victory; any failure here means the agent saw a "winning" plan
    // that didn't actually win.
    assertBoardClean(board, "simulateFullTurn after-play");
    plays.push({
      placements: [...play.placements],
      planDescs: next.planDescs,
      findPlayMs,
      applyMs,
    });
    for (const c of play.placements) cardsPlayed.push(c);
    playsMade++;
  }

  const turnWallMs = performance.now() - tTurn0;

  // Per-turn invariants.
  if (handBefore - cardsPlayed.length !== hand.length) {
    throw new Error(
      `[agent_player simulateFullTurn] turn ${turnNum} player ${activePlayerIndex} `
      + `hand arithmetic: handBefore (${handBefore}) - cardsPlayed (${cardsPlayed.length}) `
      + `= ${handBefore - cardsPlayed.length}, expected handAfterPlays ${hand.length}`,
    );
  }

  // Draw for the outgoing (active) player.
  const drawCount = drawCountFor(outcome, cardsPlayed.length);
  const cardsDrawn = Math.min(drawCount, startDeck.length);
  const handAfterDraw = cardsDrawn > 0
    ? [...hand, ...startDeck.slice(0, cardsDrawn)]
    : hand;
  const newDeck = cardsDrawn > 0 ? startDeck.slice(cardsDrawn) : startDeck;

  const record: GameTurnRecord = {
    turnNum,
    activePlayerIndex,
    handBefore,
    boardBefore,
    playsMade,
    cardsPlayedThisTurn: cardsPlayed.length,
    outcome,
    drawCount,
    cardsDrawn,
    handAfter: handAfterDraw.length,
    boardAfter: board.length,
    deckRemaining: newDeck.length,
    turnWallMs,
    findPlayWallMsTotal,
    plays,
  };

  // applyWallMsTotal is computed for symmetry with findPlayWallMsTotal
  // but isn't currently surfaced in the record; reference to silence
  // unused-var lints if any tighten later.
  void applyWallMsTotal;

  return { board, hand: handAfterDraw, deck: newDeck, record };
}

// --- Full game loop ----------------------------------------------------
//
// Lyn Rummy is a TWO-HAND game. "Solo" means one *user* (a human
// playing both sides, or an agent simulating both) — never one hand.
// The dealer rules (per Elm Game.applyValidTurn):
//
//   1. Lay 23-card opening board.
//   2. Deal 15 to Player 1, 15 to Player 2 (51 left in deck).
//   3. Player 0 begins; alternate via active_player_index.
//   4. CompleteTurn → outgoing player draws 0/3/5 based on outcome
//      (see drawCountFor).
//   5. nextActive = (outgoingIdx + 1) % nHands.
//
// playFullGame mirrors this exactly. Both hands are driven by the
// same agent brain (engine_v2 + findPlay); from a gameplay
// perspective it's solitaire-style self-play, but the wire-format
// shape matches what Elm encodes for "real" 2-player games.

export function playFullGame(
  initialBoard: readonly (readonly Card[])[],
  initialHands: readonly (readonly Card[])[],
  initialDeck: readonly Card[],
  opts: PlayGameOptions = {},
): GameResult {
  const stopAtDeck = opts.stopAtDeck ?? 10;
  const maxTurns = opts.maxTurns ?? 200;
  const tStart = performance.now();

  let board: readonly (readonly Card[])[] = initialBoard;
  let hands: readonly (readonly Card[])[] = initialHands.map(h => [...h]);
  let deck: readonly Card[] = [...initialDeck];
  let activePlayerIndex = 0;

  // Card-conservation baseline. Snapshot the initial card multiset
  // once; every per-turn check compares the live state against it.
  const initialCardKeys = collectCardKeys(
    board,
    ([] as Card[]).concat(...hands),
    deck,
  );

  const turns: GameTurnRecord[] = [];
  let stoppedReason: GameResult["stoppedReason"] = "max_turns";
  let turnNum = 1;

  while (deck.length > stopAtDeck) {
    if (turnNum > maxTurns) break;

    const result = simulateFullTurn(
      board,
      hands[activePlayerIndex]!,
      deck,
      turnNum,
      activePlayerIndex,
    );
    board = result.board;
    hands = hands.map((h, i) => i === activePlayerIndex ? result.hand : h);
    deck = result.deck;
    turns.push(result.record);

    // INVARIANT: card conservation across the entire game.
    assertCardsConserved(
      initialCardKeys,
      board,
      ([] as Card[]).concat(...hands),
      deck,
      `playFullGame turn ${turnNum}`,
    );

    // Advance active player. Mirrors Elm's
    // `nextActive = modBy nHands (outgoingIdx + 1)`.
    activePlayerIndex = (activePlayerIndex + 1) % hands.length;

    if (allHandsEmpty(hands) && deck.length === 0) {
      stoppedReason = "hand_and_deck_empty";
      break;
    }

    turnNum++;
  }

  if (stoppedReason === "max_turns" && deck.length <= stopAtDeck) {
    stoppedReason = "deck_low";
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

function allHandsEmpty(hands: readonly (readonly Card[])[]): boolean {
  for (const h of hands) if (h.length > 0) return false;
  return true;
}
