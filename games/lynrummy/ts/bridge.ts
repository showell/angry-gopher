// bridge.ts — JSON-in / JSON-out CLI entry point for the TS engine.
//
// Reads one JSON request from stdin, dispatches to the engine, writes
// one JSON response to stdout, exits. Designed for subprocess
// invocation from Python (and eventually Elm via ports, sharing the
// same wire format).
//
// Wire format is snake_case throughout (matching Python's native
// shape); the TS layer does snake↔camel conversion internally so the
// engine code keeps its TS conventions.
//
// Cards on the wire: [value, suit, deck] arrays.
// Buckets on the wire: { helper, trouble, growing, complete } each
// holding arrays of stacks (each stack an array of cards).
//
// Usage:
//   echo '{"op":"find_play","hand":[...],"board":[...]}' | node bridge.ts
//   echo '{"op":"solve","buckets":{...}}' | node bridge.ts
//
// Errors go to stderr with a non-zero exit. The caller's subprocess
// wrapper turns these into exceptions.

import * as fs from "node:fs";

import type { Card } from "./src/rules/card.ts";
import type { RawBuckets } from "./src/buckets.ts";
import { solveStateWithDescs } from "./src/bfs.ts";
import { findPlay, formatHint } from "./src/hand_play.ts";

interface FindPlayRequest {
  op: "find_play";
  hand: number[][];
  board: number[][][];
}

interface SolveRequest {
  op: "solve";
  buckets: {
    helper: number[][][];
    trouble: number[][][];
    growing: number[][][];
    complete: number[][][];
  };
  max_trouble_outer?: number;
  max_states?: number;
}

type Request = FindPlayRequest | SolveRequest;

function asCard(arr: number[]): Card {
  if (arr.length !== 3) {
    throw new Error(`card must be [value, suit, deck]; got ${JSON.stringify(arr)}`);
  }
  return [arr[0]!, arr[1]!, arr[2]!] as const;
}

function asStack(arr: number[][]): readonly Card[] {
  return arr.map(asCard);
}

function asRawBuckets(b: SolveRequest["buckets"]): RawBuckets {
  return {
    helper: b.helper.map(asStack),
    trouble: b.trouble.map(asStack),
    growing: b.growing.map(asStack),
    complete: b.complete.map(asStack),
  };
}

function handleFindPlay(req: FindPlayRequest) {
  const hand = req.hand.map(asCard);
  const board = req.board.map(asStack);
  const t0 = performance.now();
  const result = findPlay(hand, board);
  const engine_wall_ms = performance.now() - t0;
  if (result === null) {
    return { placements: null, plan: null, steps: [], engine_wall_ms };
  }
  return {
    placements: result.placements.map(c => [c[0], c[1], c[2]]),
    plan: [...result.plan],
    steps: [...formatHint(result)],
    engine_wall_ms,
  };
}

function handleSolve(req: SolveRequest) {
  const buckets = asRawBuckets(req.buckets);
  const t0 = performance.now();
  const plan = solveStateWithDescs(buckets, {
    maxTroubleOuter: req.max_trouble_outer ?? 8,
    maxStates: req.max_states ?? 10000,
  });
  const engine_wall_ms = performance.now() - t0;
  if (plan === null) return { plan: null, engine_wall_ms };
  return { plan: plan.map(p => p.line), engine_wall_ms };
}

function main() {
  const raw = fs.readFileSync(0, "utf8");
  let req: Request;
  try {
    req = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`bridge.ts: invalid JSON on stdin: ${(e as Error).message}\n`);
    process.exit(2);
  }
  let res: unknown;
  try {
    if (req.op === "find_play") {
      res = handleFindPlay(req);
    } else if (req.op === "solve") {
      res = handleSolve(req);
    } else {
      process.stderr.write(`bridge.ts: unknown op ${JSON.stringify((req as { op: unknown }).op)}\n`);
      process.exit(2);
    }
  } catch (e) {
    process.stderr.write(`bridge.ts: dispatch error: ${(e as Error).message}\n`);
    process.exit(3);
  }
  process.stdout.write(JSON.stringify(res) + "\n");
}

main();
