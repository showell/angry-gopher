// test_split_physics.ts — both-sides physics conformance for split.
//
// Reads `split_physics.dsl` and, for each scenario:
//   - parses the input stack at its loc + the `left_count`
//   - runs `applySplit` (production code path)
//   - compares the two emitted pieces' content + loc against
//     `expect_left:` and `expect_right:`
//
// The Elm side runs the same scenarios against `Lib.CardStack.split`
// via `Lib.ConformanceTests`. Together they enforce bit-identical
// physics between TS and Elm — drift on either side fails its own
// gate immediately.
//
// Bespoke DSL parser because the shared `conformance_dsl.ts`
// rejects unknown scalar/block keys; this fixture's `left_count`,
// `expect_left`, `expect_right` would all be unknowns there.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import { type BoardStack, type Loc } from "../geometry/geometry.ts";
import { cardLabel } from "../core/card.ts";
import { parseBoardStackLine } from "../dsl/parse.ts";
import { applyLocally, makeSplit } from "../game_events/primitives.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DSL_PATH = path.resolve(
  __dirname,
  "../../conformance/scenarios/split_physics.dsl",
);

interface Scenario {
  name: string;
  desc: string;
  input: BoardStack;
  leftCount: number;
  expectLeft: BoardStack;
  expectRight: BoardStack;
}

function parseScenarios(src: string): Scenario[] {
  const lines = src.split("\n").map(l => {
    const hashIdx = l.indexOf("#");
    return hashIdx >= 0 ? l.slice(0, hashIdx) : l;
  });

  const scenarios: Scenario[] = [];
  let cur: Partial<Scenario> & { name?: string } = {};
  let pendingBlock: "board" | "expect_left" | "expect_right" | null = null;

  const flush = () => {
    if (cur.name === undefined) return;
    if (cur.input === undefined) throw new Error(`${cur.name}: missing board:`);
    if (cur.leftCount === undefined) throw new Error(`${cur.name}: missing left_count:`);
    if (cur.expectLeft === undefined) throw new Error(`${cur.name}: missing expect_left:`);
    if (cur.expectRight === undefined) throw new Error(`${cur.name}: missing expect_right:`);
    scenarios.push(cur as Scenario);
    cur = {};
    pendingBlock = null;
  };

  for (const raw of lines) {
    if (raw.trim() === "") continue;
    const indent = raw.length - raw.trimStart().length;
    const content = raw.trim();

    if (indent === 0 && content.startsWith("scenario ")) {
      flush();
      cur = { name: content.slice("scenario ".length).trim() };
      pendingBlock = null;
      continue;
    }
    if (cur.name === undefined) continue; // pre-amble

    if (indent === 2) {
      pendingBlock = null;
      const colon = content.indexOf(":");
      if (colon < 0) throw new Error(`${cur.name}: expected key: at "${content}"`);
      const key = content.slice(0, colon).trim();
      const val = content.slice(colon + 1).trim();
      switch (key) {
        case "desc":
          cur.desc = val;
          break;
        case "op":
          if (val !== "split_physics") throw new Error(`${cur.name}: op must be split_physics`);
          break;
        case "left_count":
          cur.leftCount = parseInt(val, 10);
          break;
        case "board":
        case "expect_left":
        case "expect_right":
          if (val !== "") throw new Error(`${cur.name}: ${key} expects a block, got inline`);
          pendingBlock = key;
          break;
        default:
          throw new Error(`${cur.name}: unknown key "${key}"`);
      }
    } else if (indent >= 4 && pendingBlock !== null) {
      const stack = parseBoardStackLine(content);
      if (pendingBlock === "board") cur.input = stack;
      else if (pendingBlock === "expect_left") cur.expectLeft = stack;
      else cur.expectRight = stack;
    }
  }
  flush();
  return scenarios;
}

function locEq(a: Loc, b: Loc): boolean {
  return a.left === b.left && a.top === b.top;
}

function cardsEqual(a: BoardStack, b: BoardStack): boolean {
  if (a.cards.length !== b.cards.length) return false;
  for (let i = 0; i < a.cards.length; i++) {
    if (cardLabel(a.cards[i]!) !== cardLabel(b.cards[i]!)) return false;
  }
  return true;
}

function stackStr(s: BoardStack): string {
  return `[${s.cards.map(cardLabel).join(" ")}] at (${s.loc.left},${s.loc.top})`;
}

function runScenario(sc: Scenario): { ok: boolean; msg: string } {
  const board = [sc.input];
  const prim = makeSplit(board, 0, sc.leftCount);
  const after = applyLocally(board, prim);
  if (after.length !== 2) {
    return { ok: false, msg: `expected 2 pieces, got ${after.length}` };
  }
  // applyLocally appends new pieces in order [left, right] after removing the source.
  const [gotLeft, gotRight] = after;
  if (!cardsEqual(gotLeft!, sc.expectLeft)) {
    return {
      ok: false,
      msg: `left cards: expected ${stackStr(sc.expectLeft)}, got ${stackStr(gotLeft!)}`,
    };
  }
  if (!locEq(gotLeft!.loc, sc.expectLeft.loc)) {
    return {
      ok: false,
      msg: `left loc: expected ${stackStr(sc.expectLeft)}, got ${stackStr(gotLeft!)}`,
    };
  }
  if (!cardsEqual(gotRight!, sc.expectRight)) {
    return {
      ok: false,
      msg: `right cards: expected ${stackStr(sc.expectRight)}, got ${stackStr(gotRight!)}`,
    };
  }
  if (!locEq(gotRight!.loc, sc.expectRight.loc)) {
    return {
      ok: false,
      msg: `right loc: expected ${stackStr(sc.expectRight)}, got ${stackStr(gotRight!)}`,
    };
  }
  return { ok: true, msg: "" };
}

function main(): void {
  const src = fs.readFileSync(DSL_PATH, "utf8");
  const scenarios = parseScenarios(src);
  let pass = 0;
  let fail = 0;
  for (const sc of scenarios) {
    const r = runScenario(sc);
    if (r.ok) {
      pass++;
    } else {
      fail++;
      console.log(`FAIL  ${sc.name}: ${r.msg}`);
    }
  }
  console.log(`\n${pass}/${pass + fail} split_physics scenarios passed`);
  if (fail > 0) process.exit(1);
}

main();
