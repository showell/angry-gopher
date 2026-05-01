// test_conformance_leaf.ts — TS DSL conformance runner.
//
// Reads the same `.dsl` files in `games/lynrummy/conformance/leaf/`
// that the Python runner consumes. Currently registers handlers for
// the leaves that are ported; skips any verb without a registered
// handler. Skipped scenarios are reported as such (not counted as
// pass or fail) so it's clear what's still to port.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel } from "../src/rules/card.ts";
import {
  classifyStack,
  kindAfterAbsorbLeft,
  kindAfterAbsorbRight,
} from "../src/classified_card_stack.ts";

const ARROW = "→";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const LEAF_DSL_DIR = path.resolve(__dirname, "../../conformance/leaf");

// --- DSL parser (single-line scenarios only for now) ---
//
// The Python parser also handles multi-line block scenarios (e.g.,
// the `extenders` fixture). The TS port adds those as new leaves get
// implemented. Until then, header lines without `→` are skipped.

interface Scenario {
  readonly lineno: number;
  readonly raw: string;
  readonly verb: string;
  readonly args: readonly string[];
  readonly expected: string;
  readonly comment: string;
}

function parseDsl(filepath: string): Scenario[] {
  const content = fs.readFileSync(filepath, "utf8");
  const lines = content.split("\n");
  const out: Scenario[] = [];
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i]!;
    const lineno = i + 1;
    const stripped = raw.trim();
    if (!stripped || stripped.startsWith("#")) continue;
    if (raw[0] === " " || raw[0] === "\t") continue; // indented body — multi-line block, skip for now
    let line = raw;
    let comment = "";
    if (line.includes("#")) {
      const idx = line.indexOf("#");
      comment = line.slice(idx + 1).trim();
      line = line.slice(0, idx).trimEnd();
    }
    if (!line.includes(ARROW)) {
      // header line of a multi-line block — skip until parser supports it.
      continue;
    }
    const arrowIdx = line.indexOf(ARROW);
    const lhs = line.slice(0, arrowIdx);
    const rhs = line.slice(arrowIdx + ARROW.length);
    const tokens = lhs.trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0) {
      throw new Error(`${filepath}:${lineno}: scenario has no verb`);
    }
    const verb = tokens[0]!;
    const args = tokens.slice(1);
    const expected = rhs.trim();
    if (!expected) {
      throw new Error(`${filepath}:${lineno}: scenario missing expected value`);
    }
    out.push({ lineno, raw: line, verb, args, expected, comment });
  }
  return out;
}

// --- Per-verb runners --------------------------------------------------

type RunResult = string | null;
type Runner = (args: readonly string[], expected: string) => RunResult;

function parseCards(args: readonly string[]): Card[] {
  if (args.length === 1 && args[0] === "[]") return [];
  return args.map(parseCardLabel);
}

function runClassify(args: readonly string[], expected: string): RunResult {
  const cards = parseCards(args);
  const result = classifyStack(cards);
  const actual = result === null ? "none" : result.kind;
  if (actual !== expected) {
    return `expected ${expected}, got ${actual}`;
  }
  return null;
}

/** Split absorb args at the `+` separator into (target_cards, inserted_card). */
function splitAbsorbArgs(args: readonly string[]): [string[], string] {
  const plusIdx = args.indexOf("+");
  if (plusIdx < 0) {
    throw new Error(`absorb scenario missing '+' separator: ${args.join(" ")}`);
  }
  const targetTokens = args.slice(0, plusIdx);
  const cardTokens = args.slice(plusIdx + 1);
  if (targetTokens.length === 0) {
    throw new Error(`absorb scenario missing target cards: ${args.join(" ")}`);
  }
  if (cardTokens.length !== 1) {
    throw new Error(`absorb scenario expects exactly 1 card after '+': ${args.join(" ")}`);
  }
  return [targetTokens, cardTokens[0]!];
}

function runRightAbsorb(args: readonly string[], expected: string): RunResult {
  const [targetTokens, cardToken] = splitAbsorbArgs(args);
  const target = classifyStack(targetTokens.map(parseCardLabel));
  if (target === null) {
    return `target failed to classify: ${targetTokens.join(" ")}`;
  }
  const card = parseCardLabel(cardToken);
  const result = kindAfterAbsorbRight(target, card);
  const actual = result === null ? "none" : result;
  if (actual !== expected) {
    return `expected ${expected}, got ${actual}`;
  }
  return null;
}

function runLeftAbsorb(args: readonly string[], expected: string): RunResult {
  const [targetTokens, cardToken] = splitAbsorbArgs(args);
  const target = classifyStack(targetTokens.map(parseCardLabel));
  if (target === null) {
    return `target failed to classify: ${targetTokens.join(" ")}`;
  }
  const card = parseCardLabel(cardToken);
  const result = kindAfterAbsorbLeft(target, card);
  const actual = result === null ? "none" : result;
  if (actual !== expected) {
    return `expected ${expected}, got ${actual}`;
  }
  return null;
}

const RUNNERS: Readonly<Record<string, Runner>> = {
  classify: runClassify,
  right_absorb: runRightAbsorb,
  left_absorb: runLeftAbsorb,
};

// --- Driver ------------------------------------------------------------

interface FileResult {
  readonly total: number;
  readonly passed: number;
  readonly failed: number;
  readonly skipped: number;
}

function runFile(filepath: string): FileResult {
  const scenarios = parseDsl(filepath);
  let total = 0;
  let failures = 0;
  let skipped = 0;
  for (const sc of scenarios) {
    const runner = RUNNERS[sc.verb];
    if (!runner) {
      skipped++;
      continue;
    }
    total++;
    let err: string | null;
    try {
      err = runner(sc.args, sc.expected);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      err = `${e instanceof Error ? e.constructor.name : "Error"}: ${msg}`;
    }
    if (err !== null) {
      const label = sc.comment || sc.raw;
      console.log(`FAIL ${filepath}:${sc.lineno} (${label}): ${err}`);
      failures++;
    }
  }
  return { total, passed: total - failures, failed: failures, skipped };
}

function main(): void {
  if (!fs.existsSync(LEAF_DSL_DIR)) {
    console.error(`no leaf-DSL dir at ${LEAF_DSL_DIR}`);
    process.exit(1);
  }
  const files = fs
    .readdirSync(LEAF_DSL_DIR)
    .filter(f => f.endsWith(".dsl"))
    .sort();
  if (files.length === 0) {
    console.error(`no .dsl files in ${LEAF_DSL_DIR}`);
    process.exit(1);
  }

  let grandTotal = 0;
  let grandPassed = 0;
  let grandFailed = 0;
  let grandSkipped = 0;
  for (const f of files) {
    const fp = path.join(LEAF_DSL_DIR, f);
    const r = runFile(fp);
    grandTotal += r.total;
    grandPassed += r.passed;
    grandFailed += r.failed;
    grandSkipped += r.skipped;
    const skip = r.skipped > 0 ? ` (${r.skipped} skipped — verb not yet ported)` : "";
    if (r.failed > 0) {
      console.log(`  ${f}: ${r.passed}/${r.total} passed (${r.failed} failed)${skip}`);
    } else if (r.total > 0) {
      console.log(`  ${f}: ${r.total}/${r.total} passed${skip}`);
    } else {
      console.log(`  ${f}: 0/0 (all ${r.skipped} scenarios skipped — verb not yet ported)`);
    }
  }

  console.log();
  console.log(
    `${grandPassed}/${grandTotal} leaf conformance scenarios passed` +
      (grandSkipped > 0 ? ` (${grandSkipped} skipped — TS port in progress)` : "")
  );
  if (grandFailed > 0) process.exit(1);
}

main();
