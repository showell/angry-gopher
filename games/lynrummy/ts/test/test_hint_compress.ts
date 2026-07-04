// test_hint_compress — runs `hint_compress.dsl` scenarios through
// compressHint and asserts string-equality on the rewritten hint.
//
// Each scenario is raw hint DSL (`input:`) and the expected rewrite
// (`compressed:`), both as "- " dash lines. The DSL strings ARE the
// assertion surface — no parse-back, no struct comparison. Scenarios
// where `compressed` equals `input` pin the pass-through boundary.

import * as fs from "node:fs";
import * as path from "node:path";

import { compressHint } from "../plan/hint_compress.ts";

const DSL_PATH = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../conformance/scenarios/hint_compress.dsl",
);

interface Scenario {
  readonly name: string;
  readonly desc: string;
  readonly input: readonly string[];
  readonly compressed: readonly string[];
}

function parseDsl(text: string): Scenario[] {
  const out: Scenario[] = [];
  let cur: { name?: string; desc?: string; input: string[]; compressed: string[] } | null = null;
  let section: "input" | "compressed" | null = null;

  function commit(): void {
    if (cur && cur.name !== undefined) {
      out.push({ name: cur.name, desc: cur.desc ?? "", input: cur.input, compressed: cur.compressed });
    }
  }

  for (const raw of text.split("\n")) {
    const stripped = raw.replace(/#.*$/, "").trimEnd();
    const trimmed = stripped.trim();
    if (trimmed === "") continue;

    const sc = trimmed.match(/^scenario\s+(\S+)$/);
    if (sc) {
      commit();
      cur = { name: sc[1], input: [], compressed: [] };
      section = null;
      continue;
    }
    if (!cur) continue;

    if (trimmed.startsWith("desc:")) { cur.desc = trimmed.slice("desc:".length).trim(); continue; }
    if (trimmed === "input:") { section = "input"; continue; }
    if (trimmed === "compressed:") { section = "compressed"; continue; }
    if (trimmed.startsWith("- ") && section !== null) {
      cur[section].push(trimmed.slice(2));
      continue;
    }
    throw new Error(`unexpected line in hint_compress.dsl: ${JSON.stringify(raw)}`);
  }
  commit();
  return out;
}

interface RunResult { ok: boolean; msg: string }

function runScenario(sc: Scenario): RunResult {
  let got: readonly string[];
  try {
    got = compressHint(sc.input);
  } catch (e) {
    return { ok: false, msg: `compressHint threw: ${(e as Error).message}` };
  }
  const want = sc.compressed.join("\n");
  const gotStr = got.join("\n");
  if (gotStr !== want) {
    return { ok: false, msg: `mismatch:\n  want:\n${indent(want)}\n  got:\n${indent(gotStr)}` };
  }
  const fused = sc.input.length !== sc.compressed.length;
  return { ok: true, msg: fused ? `OK — fused ${sc.input.length} → ${sc.compressed.length}` : "OK — passed through" };
}

function indent(s: string): string {
  return s.split("\n").map(l => `    ${l}`).join("\n");
}

function main(): void {
  if (!fs.existsSync(DSL_PATH)) {
    console.error(`missing DSL: ${DSL_PATH}`);
    process.exit(1);
  }
  const scenarios = parseDsl(fs.readFileSync(DSL_PATH, "utf8"));

  let pass = 0, fail = 0;
  for (const sc of scenarios) {
    const r = runScenario(sc);
    console.log(`${r.ok ? "PASS" : "FAIL"}  ${sc.name.padEnd(36)} ${r.msg}`);
    if (r.ok) pass++; else fail++;
  }
  console.log(`\n${pass}/${pass + fail} hint_compress scenarios passed`);
  if (fail > 0) process.exit(1);
}

main();
