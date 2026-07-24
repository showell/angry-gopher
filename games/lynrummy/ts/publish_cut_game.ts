// publish_cut_game.ts — read a zig sim cut-state dump (cut_dump.zig
// via ops/publish_lynrummy_cut) and publish it as a playable session:
// a real late-game board whose next decision exceeded the solver
// budget, cut so a human can play from exactly where the machine ran
// out. No flags; the dump path is the constant below.

import { type Card, parseCardLabel } from "./core/card.ts";
import type { BoardStack } from "./geometry/geometry.ts";
import { findViolation } from "./geometry/geometry.ts";
import { writeStateSession } from "./full_game/transcript.ts";
import { validateSession } from "./full_game/validate_session.ts";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const DUMP_PATH = "/tmp/lynrummy_cut.dsl";

// Publish under Stephen2 (uid 16) — the account Steve plays lynrummy
// from — in the LIVE local server tree, so the session shows up in
// his game list at localhost:9001.
const USER_ROOT = path.join(os.homedir(), "AngryGopher", "local", "lynrummy", "16");

// Row-wrap layout inside Elm's 800px board (BoardView.elm): stacks
// flow left to right, wrapping before the right edge. Disjoint by
// construction; findViolation double-checks below.
const LEFT_START = 20;
const TOP_START = 20;
const GAP_X = 24;
const ROW_HEIGHT = 60;
const RIGHT_EDGE = 780;
const CARD_WIDTH = 27;
const CARD_PITCH = 33;

function layoutStacks(stacks: readonly (readonly Card[])[]): BoardStack[] {
  const out: BoardStack[] = [];
  let left = LEFT_START;
  let top = TOP_START;
  for (const cards of stacks) {
    const width = CARD_WIDTH + (cards.length - 1) * CARD_PITCH;
    if (left + width > RIGHT_EDGE && left > LEFT_START) {
      left = LEFT_START;
      top += ROW_HEIGHT;
    }
    out.push({ cards: [...cards], loc: { left, top } });
    left += width + GAP_X;
  }
  return out;
}

function parseCards(s: string): Card[] {
  return s.split(/\s+/).filter(t => t !== "").map(parseCardLabel);
}

interface CutDump {
  readonly seed: number;
  readonly turn: number;
  readonly active: number;
  readonly stacks: readonly (readonly Card[])[];
  readonly hands: readonly (readonly Card[])[];
  readonly deck: readonly Card[];
}

function parseDump(text: string): CutDump {
  const fields = new Map<string, string>();
  const stacks: Card[][] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const sep = line.indexOf(": ");
    if (sep < 0) throw new Error(`[publish_cut_game] bad dump line: ${line}`);
    const key = line.slice(0, sep);
    const val = line.slice(sep + 2);
    if (key === "stack") {
      stacks.push(parseCards(val));
    } else {
      fields.set(key, val);
    }
  }
  const need = (k: string): string => {
    const v = fields.get(k);
    if (v === undefined) throw new Error(`[publish_cut_game] dump missing ${k}:`);
    return v;
  };
  return {
    seed: parseInt(need("seed"), 10),
    turn: parseInt(need("turn"), 10),
    active: parseInt(need("active"), 10),
    stacks,
    hands: [parseCards(need("hand0")), parseCards(need("hand1"))],
    deck: parseCards(need("deck")),
  };
}

function main(): void {
  const dump = parseDump(fs.readFileSync(DUMP_PATH, "utf8"));
  const board = layoutStacks(dump.stacks);
  const violation = findViolation(board);
  if (violation !== null) {
    throw new Error(`[publish_cut_game] layout produced overlap at stack ${violation}`);
  }
  const total = board.reduce((n, s) => n + s.cards.length, 0)
    + dump.hands.reduce((n, h) => n + h.length, 0)
    + dump.deck.length;
  if (total !== 104) {
    throw new Error(`[publish_cut_game] card count ${total}, expected 104`);
  }
  const t = writeStateSession({
    board,
    hands: dump.hands,
    deck: dump.deck,
    activePlayer: dump.active,
    turnIndex: dump.turn - 1,
    label: `zig sim cut: seed ${dump.seed}, turn ${dump.turn} (solver give-up)`,
    userRoot: USER_ROOT,
  });
  const v = validateSession(t.sessionDir);
  if (!v.ok) {
    throw new Error(`session #${t.sessionId} validation failed: ${v.msg}`);
  }
  console.log(`wrote cut session #${t.sessionId} (seed ${dump.seed}, turn ${dump.turn}) to ${t.sessionDir}`);
  console.log(`play at http://localhost:9001/game/${t.sessionId}`);
}

main();
