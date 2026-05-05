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
//
// Public surface:
//   - `writeSession` — write a full agent self-play session directory.
//   - `encodeInitialState` — encode (board, hands, deck) to the
//     Wire.initialStateDecoder JSON shape; reused by tools/generate_puzzles.ts
//     for board-only puzzle catalogs.

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
import { planMergeStackOnBoard } from "./verbs.ts";
import type { GameResult, JoinEvent } from "./agent_player.ts";
import { physicalPlan } from "./physical_plan.ts";

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
//
// Encoders live in wire_json.ts (browser-safe; no fs). Re-exported
// here so older imports (paths that read this file) keep working.

import {
  type JsonCard,
  type JsonHand,
  type JsonCardStack,
  type WireActionJson,
  jsonCard,
  jsonHandCard,
  jsonStack,
  primToWire,
} from "./wire_json.ts";

export { jsonStack, primToWire, type WireActionJson } from "./wire_json.ts";

// --- Initial-state encoder -------------------------------------------
//
// `encodeInitialState` is exported (used by tools/generate_puzzles.ts
// for board-only puzzles, where hands and deck come in empty). It
// produces the Wire.initialStateDecoder-compatible JSON shape — the
// same shape `views/lynrummy_elm.go` writes for live human sessions.
// Callers control the puzzle-vs-game distinction by what they pass:
// puzzles pass `[[], []]` for hands and `[]` for deck; live sessions
// pass real ones. No sibling encoder needed — the surface is the same
// shape, only the inputs differ.

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

// --- Join-event materialization --------------------------------------
//
// `joinBoardRuns` (agent_player.ts) records each greedy run-merge as a
// `JoinEvent { src, tgt }`. The merged stack reads `[...src, ...tgt]`,
// matching `merge_stack` with side="left". We materialize each event
// into a `merge_stack` primitive at apply time, looking up indices on
// the LIVE sim board (the agent's index space differs from the
// transcript's, since `applyMergeStack` appends the merged stack to
// the end of the array).

function applyJoinEvents(
  sim: readonly BoardStack[],
  joins: readonly JoinEvent[],
  writePrim: (sim: readonly BoardStack[], prim: Primitive) => readonly BoardStack[],
): readonly BoardStack[] {
  let cur = sim;
  for (const j of joins) {
    // Reuse the verb-level planner: handles geometry pre-flight
    // (injects a `move_stack` ahead of the merge if the in-place
    // result would crowd). Always side="left" because joinBoardRuns
    // builds the merged stack as `[...src, ...tgt]`.
    const planned = planMergeStackOnBoard(cur, j.src, j.tgt, "left");
    for (const p of planned.prims) cur = writePrim(cur, p);
  }
  return cur;
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

  // Local helper: write one primitive as the next action file and
  // advance `actSim`. Captures `actionsDir`, `seq` (mutable closure
  // via the ref object), and the assertNoOverlap discipline.
  const seqRef = { n: 1 };
  const writePrim = (
    actSim: readonly BoardStack[],
    prim: Primitive,
  ): readonly BoardStack[] => {
    const wire = primToWire(prim, actSim);
    fs.writeFileSync(
      path.join(actionsDir, `${seqRef.n}.json`),
      JSON.stringify({ action: wire }) + "\n",
    );
    seqRef.n++;
    const next = applyLocally(actSim, prim);
    assertNoOverlap(next, `after-primitive ${prim.action}`);
    return next;
  };

  let sim: readonly BoardStack[] = inputs.initialBoard;
  for (const turn of inputs.result.turns) {
    // Walk the turn's interleaved step stream. Each step is either a
    // groom (replay run-merges as `merge_stack` primitives) or a
    // play (expand into physical primitives via `physicalPlan`).
    for (const step of turn.steps) {
      if (step.kind === "groom") {
        sim = applyJoinEvents(sim, step.joins, writePrim);
      } else {
        const prims = physicalPlan(sim, step.placements, step.planDescs);
        for (const prim of prims) sim = writePrim(sim, prim);
      }
    }
    // CompleteTurn at end of every turn (Elm's local logic deals
    // the next 3 / 5 from initial_state.deck on receipt).
    fs.writeFileSync(
      path.join(actionsDir, `${seqRef.n}.json`),
      JSON.stringify({ action: { action: "complete_turn" } }) + "\n",
    );
    seqRef.n++;
  }
  const seq = seqRef.n;

  return {
    sessionId,
    sessionDir,
    actionsWritten: seq - 1,
  };
}
