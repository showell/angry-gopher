// transcript.ts — write an Elm-replayable session directory from a
// TS agent self-play game.
//
// Output shape (matches what `views/lynrummy_elm.go` writes when a
// human plays in the browser, which is what Elm's `Wire.fetchActionLog`
// reads back on replay):
//
//   <sessions_dir>/<id>/meta.json     {created_at, label, initial_state}
//   <sessions_dir>/<id>/actions/<seq>.json   {action, gesture_metadata?}
//
// The actions are wire-shaped `WireAction` envelopes — same vocabulary
// the Elm UI POSTs to the server during live play. Replay walks the
// log forward and applies each action through Elm's eager applier.
//
// Per Steve, 2026-05-03: agents use the file system directly (no HTTP).
// This module writes files; it doesn't talk to the Go server.
//
// Card-state convention: every card is FirmlyOnBoard (state=0) /
// HandNormal (state=0). Animation states (FreshlyPlayed, FreshlyDrawn)
// are runtime UI concerns Elm sets locally during gameplay; from a
// fresh-replay perspective they don't matter.

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "./rules/card.ts";
import { cardLabel } from "./rules/card.ts";
import type { BoardStack, Loc } from "./geometry.ts";
import { findOpenLoc, findViolation } from "./geometry.ts";
import {
  type Primitive,
  applyLocally,
} from "./primitives.ts";
import type { GameResult, PlayRecord } from "./agent_player.ts";
import { moveToPrimitives } from "./verbs.ts";

// --- Invariant: no two stacks ever overlap, ever ---------------------
//
// Per Steve, 2026-05-03: "you cannot place a stack on top of another
// stack. NO OVERLAPPING STACKS!!! ... It should also work by
// construction, but you need belt/suspenders." This runs after every
// primitive applies; if it fires, the geometry post-pass missed a
// case OR the placement-loc search underestimated the eventual stack
// width. Either way, surface it loud rather than write a transcript
// the UI can't render cleanly.
function assertNoOverlap(
  board: readonly BoardStack[],
  ctx: string,
): void {
  const violation = findViolation(board);
  if (violation !== null) {
    const stack = board[violation]!;
    const labels = stack.cards.map(cardLabel).join(" ");
    const dump = board.map((s, i) => {
      const w = 27 + (s.cards.length - 1) * 33;
      return `  [${i}] (${s.loc.top},${s.loc.left})..(${s.loc.top + 40},${s.loc.left + w}) ${s.cards.map(cardLabel).join(" ")}`;
    }).join("\n");
    throw new Error(
      `[transcript ${ctx}] geometry violation at stack ${violation} `
      + `[${labels}] @ (${stack.loc.top},${stack.loc.left}). Full board:\n${dump}`,
    );
  }
}

// --- Session-dir layout ----------------------------------------------

const DEFAULT_DATA_DIR = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../data",
);

interface Paths {
  readonly sessionsDir: string;
  readonly nextIdFile: string;
}

function paths(dataDir: string): Paths {
  return {
    sessionsDir: path.join(dataDir, "lynrummy-elm", "sessions"),
    nextIdFile: path.join(dataDir, "next-session-id.txt"),
  };
}

/** Read + increment + write the session-id counter. Mirrors what
 *  `views/lynrummy_elm.go` does, but TS-side (the Go server is
 *  out of the loop for agent-written transcripts). */
function allocateSessionId(p: Paths): number {
  let n = 1;
  if (fs.existsSync(p.nextIdFile)) {
    const raw = fs.readFileSync(p.nextIdFile, "utf8").trim();
    const parsed = parseInt(raw, 10);
    if (!Number.isNaN(parsed) && parsed > 0) n = parsed;
  }
  fs.writeFileSync(p.nextIdFile, String(n + 1) + "\n");
  return n;
}

// --- TS Card → Elm-wire JSON -----------------------------------------

interface JsonCard { value: number; suit: number; origin_deck: number }
interface JsonBoardCard { card: JsonCard; state: number }
interface JsonHandCard { card: JsonCard; state: number }
interface JsonLoc { top: number; left: number }
interface JsonCardStack { board_cards: JsonBoardCard[]; loc: JsonLoc }
interface JsonHand { hand_cards: JsonHandCard[] }

function jsonCard(c: Card): JsonCard {
  return { value: c[0], suit: c[1], origin_deck: c[2] };
}

function jsonBoardCard(c: Card): JsonBoardCard {
  return { card: jsonCard(c), state: 0 };  // FirmlyOnBoard
}

function jsonHandCard(c: Card): JsonHandCard {
  return { card: jsonCard(c), state: 0 };  // HandNormal
}

function jsonStack(s: BoardStack): JsonCardStack {
  return {
    board_cards: s.cards.map(jsonBoardCard),
    loc: { top: s.loc.top, left: s.loc.left },
  };
}

// --- Initial-state encoder -------------------------------------------

interface RemoteStateJson {
  board: JsonCardStack[];
  hands: JsonHand[];
  scores: number[];
  active_player_index: number;
  turn_index: number;
  deck: JsonCard[];
  cards_played_this_turn: number;
  victor_awarded: boolean;
  turn_start_board_score: number;
}

function encodeInitialState(
  board: readonly BoardStack[],
  hands: readonly (readonly Card[])[],
  deck: readonly Card[],
): RemoteStateJson {
  return {
    board: board.map(jsonStack),
    hands: hands.map(h => ({ hand_cards: h.map(jsonHandCard) })),
    scores: hands.map(() => 0),
    active_player_index: 0,
    turn_index: 0,
    deck: deck.map(jsonCard),
    cards_played_this_turn: 0,
    victor_awarded: false,
    turn_start_board_score: 0,
  };
}

// --- Primitive → WireAction envelope ---------------------------------

type WireActionJson =
  | { action: "split"; stack: JsonCardStack; card_index: number }
  | { action: "merge_stack"; source: JsonCardStack; target: JsonCardStack; side: "left" | "right" }
  | { action: "merge_hand"; hand_card: JsonCard; target: JsonCardStack; side: "left" | "right" }
  | { action: "place_hand"; hand_card: JsonCard; loc: JsonLoc }
  | { action: "move_stack"; stack: JsonCardStack; new_loc: JsonLoc }
  | { action: "complete_turn" };

function primToWire(prim: Primitive, sim: readonly BoardStack[]): WireActionJson {
  switch (prim.action) {
    case "split":
      return {
        action: "split",
        stack: jsonStack(sim[prim.stackIndex]!),
        card_index: prim.cardIndex,
      };
    case "merge_stack":
      return {
        action: "merge_stack",
        source: jsonStack(sim[prim.sourceStack]!),
        target: jsonStack(sim[prim.targetStack]!),
        side: prim.side,
      };
    case "merge_hand":
      return {
        action: "merge_hand",
        hand_card: jsonCard(prim.handCard),
        target: jsonStack(sim[prim.targetStack]!),
        side: prim.side,
      };
    case "place_hand":
      return {
        action: "place_hand",
        hand_card: jsonCard(prim.handCard),
        loc: { top: prim.loc.top, left: prim.loc.left },
      };
    case "move_stack":
      return {
        action: "move_stack",
        stack: jsonStack(sim[prim.stackIndex]!),
        new_loc: { top: prim.newLoc.top, left: prim.newLoc.left },
      };
  }
}

// --- Per-play expansion (placements + plan steps) --------------------

/** Expand one play into a primitive sequence:
 *    - first placement → PlaceHand
 *    - additional placements → MergeHand onto the just-placed stack
 *    - then each plan-desc → moveToPrimitives expansion
 *  Returns the primitive list paired with the post-play sim board. */
function playToPrimitives(
  sim: readonly BoardStack[],
  play: PlayRecord,
): { prims: Primitive[]; sim: readonly BoardStack[] } {
  let cur = sim;
  const out: Primitive[] = [];

  if (play.placements.length > 0) {
    // Reserve loc for the EVENTUAL stack width — placeHand creates a
    // singleton and subsequent merge_hand calls grow rightward,
    // keeping the original loc. Using card_count=1 (the python
    // legacy) underestimates and lets the grown stack overlap a
    // neighbor when the agent plays 2-3 cards together. Reserving
    // for play.placements.length keeps the post-merge stack clear.
    const placeLoc = findOpenLoc(cur, play.placements.length);
    const placeAction: Primitive = {
      action: "place_hand",
      handCard: play.placements[0]!,
      loc: placeLoc,
    };
    out.push(placeAction);
    cur = applyLocally(cur, placeAction);
    for (let i = 1; i < play.placements.length; i++) {
      // Just-placed stack is the last one; right-side merges keep
      // its loc and append the new card.
      const targetIdx = cur.length - 1;
      const mergeAction: Primitive = {
        action: "merge_hand",
        targetStack: targetIdx,
        handCard: play.placements[i]!,
        side: "right",
      };
      out.push(mergeAction);
      cur = applyLocally(cur, mergeAction);
    }
    // Assert at the boundary where the player has finished placing
    // their hand-cards (the placements form one clean stack on the
    // board; no in-flight pre-flights pending).
    assertNoOverlap(cur, "after-placements");
  }

  for (const desc of play.planDescs) {
    const prims = moveToPrimitives(desc, cur);
    for (const p of prims) {
      out.push(p);
      cur = applyLocally(cur, p);
    }
    // Assert after each whole plan-desc completes (geometry_plan's
    // pre-flights resolve in pairs: move_stack + the actual
    // split/merge that follows; the intermediate frame between them
    // can carry a transient overlap that the very next primitive
    // resolves). The boundary that matters is post-desc.
    assertNoOverlap(cur, `after-plan-desc ${describeShort(desc)}`);
  }
  return { prims: out, sim: cur };
}

function describeShort(d: { type: string }): string {
  return d.type;
}

// --- Top-level writer ------------------------------------------------

export interface TranscriptOpts {
  /** Override the data dir (defaults to the repo's
   *  `games/lynrummy/data`). */
  readonly dataDir?: string;
  /** Session label written into meta.json. */
  readonly label?: string;
}

export interface TranscriptInputs {
  readonly initialBoard: readonly BoardStack[];
  readonly initialHands: readonly (readonly Card[])[];
  readonly initialDeck: readonly Card[];
  readonly result: GameResult;
}

export interface TranscriptResult {
  readonly sessionId: number;
  readonly sessionDir: string;
  readonly actionsWritten: number;
}

/** Write an Elm-replayable session for one agent self-play game.
 *  Returns the allocated session id + on-disk path. */
export function writeSession(
  inputs: TranscriptInputs,
  opts: TranscriptOpts = {},
): TranscriptResult {
  const dataDir = opts.dataDir ?? DEFAULT_DATA_DIR;
  const p = paths(dataDir);
  const sessionId = allocateSessionId(p);
  const sessionDir = path.join(p.sessionsDir, String(sessionId));
  const actionsDir = path.join(sessionDir, "actions");
  fs.mkdirSync(actionsDir, { recursive: true });

  const meta = {
    created_at: Math.floor(Date.now() / 1000),
    label: opts.label ?? "agent self-play",
    initial_state: encodeInitialState(
      inputs.initialBoard, inputs.initialHands, inputs.initialDeck),
  };
  fs.writeFileSync(
    path.join(sessionDir, "meta.json"),
    JSON.stringify(meta, null, 2) + "\n",
  );

  let seq = 1;
  let sim: readonly BoardStack[] = inputs.initialBoard;
  for (const turn of inputs.result.turns) {
    for (const play of turn.plays) {
      const { prims, sim: nextSim } = playToPrimitives(sim, play);
      // Write each primitive as a discrete action file. We re-thread
      // sim per primitive so each action carries the correct full
      // CardStack at its referenced indices.
      let actSim = sim;
      for (const prim of prims) {
        const wire = primToWire(prim, actSim);
        const envelope = { action: wire };
        fs.writeFileSync(
          path.join(actionsDir, `${seq}.json`),
          JSON.stringify(envelope) + "\n",
        );
        seq++;
        actSim = applyLocally(actSim, prim);
      }
      sim = nextSim;
    }
    // CompleteTurn at end of every turn (Elm's local logic deals
    // the next 3 / 5 from initial_state.deck on receipt).
    fs.writeFileSync(
      path.join(actionsDir, `${seq}.json`),
      JSON.stringify({ action: { action: "complete_turn" } }) + "\n",
    );
    seq++;
  }

  return {
    sessionId,
    sessionDir,
    actionsWritten: seq - 1,
  };
}
