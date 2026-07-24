// transcript.ts — write an Elm-replayable session directory from a
// TS agent self-play game. Pure DSL on disk; no JSON envelopes.
//
// Output shape (matches what a human-played browser session writes,
// which is what Elm's `Wire.fetchActionLog` reads back on replay):
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
// HTTP). This module writes files; it doesn't talk to the server.

import * as fs from "node:fs";
import * as path from "node:path";

import type { Card } from "../core/card.ts";
import { cardLabel } from "../core/card.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { findViolation } from "../geometry/geometry.ts";
import {
  type Primitive,
  applyLocally,
} from "../game_events/primitives.ts";
import type { GameResult } from "./full_game.ts";
import { completeTurnDsl, formatPrimitive, seqPrefix } from "../dsl/emit.ts";
import { formatGameState } from "./initial_state_dsl.ts";


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
      return `  [${i}] (${s.loc.left},${s.loc.top})..(${s.loc.left + w},${s.loc.top + 40}) ${s.cards.map(cardLabel).join(" ")}`;
    }).join("\n");
    throw new Error(
      `[transcript ${ctx}] geometry violation at stack ${violation} `
      + `[${labels}] @ (${stack.loc.left},${stack.loc.top}). Full board:\n${dump}`,
    );
  }
}


// --- Session-dir layout ----------------------------------------------

const DATA_DIR = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../data",
);
const SESSIONS_DIR = path.join(DATA_DIR, "lynrummy-elm", "sessions");
const NEXT_ID_FILE = path.join(DATA_DIR, "next-session-id.txt");

/** Defensive check — the data layout must already exist on disk
 *  before writeSession runs. Silent mkdir would paper over a
 *  misconfigured deployment; a loud error tells the operator
 *  exactly what's missing. */
function assertSessionsDirExists(): void {
  if (!fs.existsSync(DATA_DIR)) {
    throw new Error(
      `[transcript] data dir missing: ${DATA_DIR} — repository layout is broken or this script is running outside the repo`,
    );
  }
  if (!fs.existsSync(SESSIONS_DIR)) {
    throw new Error(
      `[transcript] sessions dir missing: ${SESSIONS_DIR} — initialize the deployment before writing session transcripts`,
    );
  }
}

/** Read + increment + write the session-id counter. Mirrors what
 *  a human-played browser session does, but TS-side (the server is
 *  out of the loop for agent-written transcripts). */
function allocateSessionId(): number {
  return allocateSessionIdAt(NEXT_ID_FILE);
}

function allocateSessionIdAt(nextIdFile: string): number {
  let n = 1;
  if (fs.existsSync(nextIdFile)) {
    const raw = fs.readFileSync(nextIdFile, "utf8").trim();
    const parsed = parseInt(raw, 10);
    if (!Number.isNaN(parsed) && parsed > 0) n = parsed;
  }
  fs.writeFileSync(nextIdFile, String(n + 1) + "\n");
  return n;
}


// --- Top-level writer ------------------------------------------------

interface TranscriptInputs {
  readonly initialBoard: readonly BoardStack[];
  readonly initialHands: readonly (readonly Card[])[];
  readonly initialDeck: readonly Card[];
  readonly result: GameResult;
  /** Human-readable session label written into the meta file. */
  readonly label: string;
}

interface TranscriptResult {
  readonly sessionId: number;
  readonly sessionDir: string;
  readonly actionsWritten: number;
}


/** Write an Elm-replayable session for one agent self-play game.
 *  Returns the allocated session id + on-disk path. */
export function writeSession(inputs: TranscriptInputs): TranscriptResult {
  assertSessionsDirExists();
  const sessionId = allocateSessionId();
  const sessionDir = path.join(SESSIONS_DIR, String(sessionId));
  fs.mkdirSync(sessionDir);

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
    inputs.label,
    gameStateDsl,
  );
  fs.writeFileSync(path.join(sessionDir, "meta"), metaBody);

  // --- actions.dsl ---
  // Render each primitive via dsl/emit's canonical formatter. The
  // formatter takes the live board snapshot at this primitive's
  // moment so stack refs reflect post-prior-primitive state.
  const actionsPath = path.join(sessionDir, "actions.dsl");
  fs.writeFileSync(actionsPath, "");
  const seqRef = { n: 1 };

  const writePrim = (
    actSim: readonly BoardStack[],
    prim: Primitive,
  ): readonly BoardStack[] => {
    fs.appendFileSync(actionsPath, seqPrefix(seqRef.n) + formatPrimitive(prim, actSim) + "\n");
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


interface StateSessionInputs {
  readonly board: readonly BoardStack[];
  readonly hands: readonly (readonly Card[])[];
  readonly deck: readonly Card[];
  readonly activePlayer: number;
  readonly turnIndex: number;
  readonly label: string;
  /** The player's data subtree in the LIVE server tree — e.g.
   *  ~/AngryGopher/local/lynrummy/16 — holding lynrummy-elm/sessions
   *  and next-session-id.txt. Unlike writeSession's repo-relative
   *  legacy layout, published cut states go where the running zig
   *  server actually reads. */
  readonly userRoot: string;
}

/** Write a session whose INITIAL state is an arbitrary mid-game
 *  state, with an empty action log — how a zig-sim cut state (a
 *  board whose next decision exceeded the solver budget) becomes a
 *  playable session. The Elm resume path bootstraps entirely from
 *  the meta GameState block, so no primitive history is needed. */
export function writeStateSession(inputs: StateSessionInputs): TranscriptResult {
  const sessionsDir = path.join(inputs.userRoot, "lynrummy-elm", "sessions");
  const nextIdFile = path.join(inputs.userRoot, "next-session-id.txt");
  if (!fs.existsSync(sessionsDir)) {
    throw new Error(
      `[transcript] sessions dir missing: ${sessionsDir} — is the user root right and the server initialized?`,
    );
  }
  assertNoOverlap(inputs.board, "state-session initial board");
  const sessionId = allocateSessionIdAt(nextIdFile);
  const sessionDir = path.join(sessionsDir, String(sessionId));
  fs.mkdirSync(sessionDir);
  const gameStateDsl = formatGameState({
    board: inputs.board,
    hands: inputs.hands,
    deck: inputs.deck,
    activePlayer: inputs.activePlayer,
    turnIndex: inputs.turnIndex,
    cardsPlayedThisTurn: 0,
    victorAwarded: false,
  });
  fs.writeFileSync(
    path.join(sessionDir, "meta"),
    formatMeta(Math.floor(Date.now() / 1000), inputs.label, gameStateDsl),
  );
  fs.writeFileSync(path.join(sessionDir, "actions.dsl"), "");
  return { sessionId, sessionDir, actionsWritten: 0 };
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
