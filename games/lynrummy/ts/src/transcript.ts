// transcript.ts — write an Elm-replayable session directory from a
// TS agent self-play game. Pure DSL on disk; no JSON envelopes.
//
// Output shape (matches what `views/lynrummy_elm.go` writes when a
// human plays in the browser, which is what Elm's
// `Wire.fetchActionLog` reads back on replay):
//
//   <sessions_dir>/<id>/meta            multi-line DSL: server-owned
//                                       scalars (created_at, label),
//                                       then the GameState block
//   <sessions_dir>/<id>/actions.dsl     one wire-DSL line per
//                                       primitive (live action-log
//                                       grammar — same syntax Elm
//                                       writes during a human game)
//
// Per Steve, 2026-05-03: agents use the file system directly (no
// HTTP). This module writes files; it doesn't talk to the Go server.

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "./rules/card.ts";
import { cardLabel } from "./rules/card.ts";
import type { BoardStack } from "./geometry.ts";
import { findViolation } from "./geometry.ts";
import {
  type Primitive,
  applyLocally,
} from "./primitives.ts";
import type { GameResult } from "../lib/full_game.ts";
import { completeTurnDsl, seqPrefix } from "./wire_action_dsl.ts";
import { formatGameState } from "./initial_state_dsl.ts";
import {
  type JsonCard,
  type JsonHand,
  type JsonCardStack,
  jsonCard,
  jsonHandCard,
  jsonStack,
} from "./wire_json.ts";


// --- Puzzle-catalog JSON encoder ------------------------------------
//
// Kept for `tools/generate_puzzles.ts`, which writes
// `mined_seeds.dsl` (the puzzle-catalog data file, consumed by
// the Go server). The puzzle catalog is DSL; this JSON encoder
// is kept only because `tools/generate_puzzles.ts` still writes
// its small a3_* catalog as JSON. Eventually that catalog
// should follow the same DSL migration.

export interface RemoteStateJson {
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

export function encodeInitialState(
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


// --- Top-level writer ------------------------------------------------

export interface TranscriptOpts {
  /** Override the data dir (defaults to the repo's
   *  `games/lynrummy/data`). */
  readonly dataDir?: string;
  /** Session label written into meta. */
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
  fs.mkdirSync(sessionDir, { recursive: true });

  // --- meta ---
  const gameStateDsl = formatGameState({
    board: inputs.initialBoard,
    hands: inputs.initialHands,
    deck: inputs.initialDeck,
    activePlayer: 0,
    turnIndex: 0,
    cardsPlayedThisTurn: 0,
    victorAwarded: false,
  });
  const metaBody = formatMeta(
    Math.floor(Date.now() / 1000),
    opts.label ?? "agent self-play",
    gameStateDsl,
  );
  fs.writeFileSync(path.join(sessionDir, "meta"), metaBody);

  // --- actions.dsl ---
  // Each primitive already carries its own DSL body (baked at
  // construction by `primitives.ts:make*` helpers). The writer
  // just prepends seq, appends line, advances sim, runs the
  // no-overlap belt.
  const actionsPath = path.join(sessionDir, "actions.dsl");
  fs.writeFileSync(actionsPath, "");
  const seqRef = { n: 1 };

  const writePrim = (
    actSim: readonly BoardStack[],
    prim: Primitive,
  ): readonly BoardStack[] => {
    fs.appendFileSync(actionsPath, seqPrefix(seqRef.n) + prim.dsl + "\n");
    seqRef.n++;
    const next = applyLocally(actSim, prim);
    assertNoOverlap(next, `after-primitive ${prim.action}`);
    return next;
  };

  let sim: readonly BoardStack[] = inputs.initialBoard;
  for (const turn of inputs.result.turns) {
    for (const step of turn.steps) {
      for (const prim of step.prims) {
        sim = writePrim(sim, prim);
      }
    }
    // CompleteTurn at end of every turn. Elm's local logic deals
    // the next 3 / 5 from initial_state.deck on receipt.
    fs.appendFileSync(actionsPath, seqPrefix(seqRef.n) + completeTurnDsl + "\n");
    seqRef.n++;
  }

  return {
    sessionId,
    sessionDir,
    actionsWritten: seqRef.n - 1,
  };
}


/** Render the on-disk meta document: top-level scalars, blank
 *  line, then the game-state DSL. Trailing newline so file ends
 *  cleanly. Symmetric to Go's FormatSessionMeta. */
function formatMeta(
  createdAt: number,
  label: string,
  gameStateDsl: string,
): string {
  let out = `created_at: ${createdAt}\nlabel: ${label}\n\n${gameStateDsl}`;
  if (!out.endsWith("\n")) out += "\n";
  return out;
}
