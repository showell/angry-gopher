// test_elm_find_play — runs `elm_find_play_corpus.dsl` scenarios
// through `elmFindPlay` and asserts string-equality on the rendered
// primitives.
//
// The wrapper takes board+hand DSL and returns primitives DSL; the
// runner treats those DSL strings as the assertion surface — no
// parse-back, no struct comparison. The DSL IS the contract.

import * as fs from "node:fs";
import * as path from "node:path";

import { elmFindPlay } from "../elm_api/elm_find_play.ts";

const DSL_PATH = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../conformance/scenarios/elm_find_play_corpus.dsl",
);

interface Scenario {
  readonly name: string;
  readonly desc: string;
  readonly boardDsl: string;
  readonly handDsl: string;
  readonly expectedPrimitives: readonly string[];
}

function parseDsl(text: string): Scenario[] {
  const lines = text.split("\n");
  const out: Scenario[] = [];
  let cur: {
    name?: string;
    desc?: string;
    boardLines?: string[];
    handDsl?: string;
    expectedPrimitives?: string[];
  } | null = null;
  let inBoard = false;
  let inPrims = false;

  function commit(): void {
    if (cur && cur.name !== undefined) {
      out.push({
        name: cur.name,
        desc: cur.desc ?? "",
        boardDsl: (cur.boardLines ?? []).join("\n"),
        handDsl: cur.handDsl ?? "",
        expectedPrimitives: cur.expectedPrimitives ?? [],
      });
    }
  }

  for (const raw of lines) {
    const stripped = raw.replace(/#.*$/, "").trimEnd();
    const trimmed = stripped.trim();

    const sc = trimmed.match(/^scenario\s+(\S+)$/);
    if (sc && raw.match(/^scenario\b/)) {
      commit();
      cur = { name: sc[1], boardLines: [], expectedPrimitives: [] };
      inBoard = inPrims = false;
      continue;
    }
    if (!cur) continue;

    if (trimmed === "board:") { inBoard = true; inPrims = false; continue; }
    if (trimmed === "expect:") { inBoard = false; continue; }
    if (trimmed === "primitives:") { inPrims = true; continue; }

    if (trimmed.startsWith("hand:")) {
      cur.handDsl = trimmed.slice("hand:".length).trim();
      inBoard = inPrims = false;
      continue;
    }
    if (trimmed.startsWith("desc:")) {
      cur.desc = trimmed.slice("desc:".length).trim();
      continue;
    }

    if (inBoard && trimmed.startsWith("at ")) {
      cur.boardLines!.push(trimmed);
      continue;
    }
    if (inPrims && trimmed.startsWith("- ")) {
      cur.expectedPrimitives!.push(trimmed.slice(2));
      continue;
    }
  }
  commit();
  return out;
}

interface RunResult { ok: boolean; msg: string }

function runScenario(sc: Scenario): RunResult {
  let got: string;
  try {
    got = elmFindPlay(sc.boardDsl, sc.handDsl);
  } catch (e) {
    return { ok: false, msg: `elmFindPlay threw: ${(e as Error).message}` };
  }
  const want = sc.expectedPrimitives.join("\n");
  if (got !== want) {
    return {
      ok: false,
      msg: `primitives mismatch:\n  want:\n${indent(want)}\n  got:\n${indent(got)}`,
    };
  }
  const n = sc.expectedPrimitives.length;
  return { ok: true, msg: `OK — ${n} primitive${n === 1 ? "" : "s"} string-matched` };
}

function indent(s: string): string {
  return s.split("\n").map(l => `    ${l}`).join("\n");
}

function main(): void {
  if (!fs.existsSync(DSL_PATH)) {
    console.error(`missing DSL: ${DSL_PATH}`);
    process.exit(1);
  }
  const text = fs.readFileSync(DSL_PATH, "utf8");
  const scenarios = parseDsl(text);

  let pass = 0, fail = 0;
  for (const sc of scenarios) {
    const r = runScenario(sc);
    const tag = r.ok ? "PASS" : "FAIL";
    console.log(`${tag}  ${sc.name.padEnd(40)} ${r.msg}`);
    if (r.ok) pass++; else fail++;
  }
  console.log(`\n${pass}/${pass + fail} elm_find_play scenarios passed`);
  if (fail > 0) process.exit(1);
}

main();
