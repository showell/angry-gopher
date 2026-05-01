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
  canPeel,
  canPluck,
  canSplitOut,
  canSteal,
  canYank,
  classifyStack,
  extendsTables,
  findSpliceCandidates,
  kindAfterAbsorbLeft,
  kindAfterAbsorbRight,
  kindsAfterSpliceLeft,
  kindsAfterSpliceRight,
  KIND_RB,
  KIND_RUN,
  peel,
  pluck,
  shapeFrom,
  shapeId,
  splitOut,
  steal,
  yank,
  type ClassifiedCardStack,
  type ExtenderMap,
  type Kind,
  type SpliceCandidate,
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

interface BodyLine {
  readonly lineno: number;
  readonly text: string; // stripped, no inline comment
  readonly comment: string;
}

interface Scenario {
  readonly lineno: number;
  readonly raw: string;
  readonly verb: string;
  readonly args: readonly string[];
  readonly expected: string | null; // null for multi-line block scenarios
  readonly comment: string;
  readonly body: readonly BodyLine[] | null;
}

function stripComment(line: string): { line: string; comment: string } {
  if (!line.includes("#")) return { line, comment: "" };
  const idx = line.indexOf("#");
  return {
    line: line.slice(0, idx).trimEnd(),
    comment: line.slice(idx + 1).trim(),
  };
}

function parseDsl(filepath: string): Scenario[] {
  const content = fs.readFileSync(filepath, "utf8");
  const lines = content.split("\n");
  const out: Scenario[] = [];
  let i = 0;
  while (i < lines.length) {
    const raw = lines[i]!;
    const lineno = i + 1;
    const stripped = raw.trim();
    if (!stripped || stripped.startsWith("#")) {
      i++;
      continue;
    }
    if (raw[0] === " " || raw[0] === "\t") {
      throw new Error(
        `${filepath}:${lineno}: indented line outside a block: ${raw}`,
      );
    }
    const { line: noComment, comment } = stripComment(raw);
    if (noComment.includes(ARROW)) {
      // Single-line scenario.
      const arrowIdx = noComment.indexOf(ARROW);
      const lhs = noComment.slice(0, arrowIdx);
      const rhs = noComment.slice(arrowIdx + ARROW.length);
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
      out.push({ lineno, raw: noComment, verb, args, expected, comment, body: null });
      i++;
      continue;
    }
    // Multi-line block scenario: header opens it, indented lines are body.
    const headerTokens = noComment.trim().split(/\s+/).filter(Boolean);
    if (headerTokens.length === 0) {
      throw new Error(`${filepath}:${lineno}: empty header line`);
    }
    const verb = headerTokens[0]!;
    const args = headerTokens.slice(1);
    const body: BodyLine[] = [];
    i++;
    while (i < lines.length) {
      const braw = lines[i]!;
      const bstripped = braw.trim();
      if (!bstripped || bstripped.startsWith("#")) {
        i++;
        continue;
      }
      if (braw[0] !== " " && braw[0] !== "\t") {
        break; // next column-0 line ends the block
      }
      const { line: bline, comment: bcomment } = stripComment(braw);
      body.push({ lineno: i + 1, text: bline.trim(), comment: bcomment });
      i++;
    }
    out.push({
      lineno,
      raw: noComment,
      verb,
      args,
      expected: null,
      comment,
      body,
    });
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

// --- Source-side verb runners (peel / pluck / yank / steal / split_out) ---

type SourceVerbPredicate = (stack: ClassifiedCardStack, i: number) => boolean;
type SourceVerbExecutor = (
  stack: ClassifiedCardStack,
  i: number,
) => readonly ClassifiedCardStack[];

/** Split source-verb args at the `@` separator into (target_tokens, position). */
function splitAtArgs(args: readonly string[]): [string[], number] {
  const atIdx = args.indexOf("@");
  if (atIdx < 0) {
    throw new Error(`source-verb scenario missing '@' separator: ${args.join(" ")}`);
  }
  const targetTokens = args.slice(0, atIdx);
  const posTokens = args.slice(atIdx + 1);
  if (targetTokens.length === 0) {
    throw new Error(`source-verb scenario missing target cards: ${args.join(" ")}`);
  }
  if (posTokens.length !== 1) {
    throw new Error(
      `source-verb scenario expects exactly 1 token after '@': ${args.join(" ")}`,
    );
  }
  const pos = parseInt(posTokens[0]!, 10);
  if (!Number.isInteger(pos)) {
    throw new Error(`source-verb position not an int: ${posTokens[0]}`);
  }
  return [targetTokens, pos];
}

/** Compare two card lists for equality (deep, by component). */
function cardsEqual(a: readonly Card[], b: readonly Card[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (x[0] !== y[0] || x[1] !== y[1] || x[2] !== y[2]) return false;
  }
  return true;
}

function renderCards(cards: readonly Card[]): string {
  return cards.map(c => {
    const base = "A23456789TJQK"[c[0] - 1]! + "CDSH"[c[1]]!;
    return c[2] === 0 ? base : `${base}:${c[2]}`;
  }).join(" ");
}

/** Build a runner for one source-side verb. The runner parses the
 *  `@ <pos>` syntax, classifies the target, checks the predicate against
 *  the expected legal/illegal status, and (when legal) verifies the
 *  card content of each piece against the `|`-separated expected list. */
function makeSourceVerbRunner(
  verbName: string,
  predicate: SourceVerbPredicate,
  executor: SourceVerbExecutor,
): Runner {
  return (args, expected) => {
    const [targetTokens, pos] = splitAtArgs(args);
    const target = classifyStack(targetTokens.map(parseCardLabel));
    if (target === null) {
      return `${verbName} target failed to classify: ${targetTokens.join(" ")}`;
    }
    const predOk = predicate(target, pos);
    if (expected === "none") {
      return predOk ? `expected none, predicate returned true` : null;
    }
    if (!predOk) {
      return `expected pieces, predicate returned false (expected ${expected})`;
    }
    // Parse expected pieces from the `|`-split RHS.
    const pieces = expected.split("|").map(p => p.trim()).filter(Boolean);
    if (pieces.length === 0) {
      return `expected RHS has no pieces: ${expected}`;
    }
    const expectedCardLists: Card[][] = pieces.map(piece =>
      piece.split(/\s+/).filter(Boolean).map(parseCardLabel),
    );
    const result = executor(target, pos);
    if (result.length !== expectedCardLists.length) {
      return `${verbName} returned ${result.length} pieces, expected ${expectedCardLists.length}`;
    }
    for (let k = 0; k < result.length; k++) {
      const got = result[k]!.cards;
      const want = expectedCardLists[k]!;
      if (!cardsEqual(got, want)) {
        return `piece ${k}: expected [${renderCards(want)}], got [${renderCards(got)}]`;
      }
    }
    return null;
  };
}

const runPeel = makeSourceVerbRunner("peel", canPeel, peel);
const runPluck = makeSourceVerbRunner("pluck", canPluck, pluck);
const runYank = makeSourceVerbRunner("yank", canYank, yank);
const runSteal = makeSourceVerbRunner("steal", canSteal, steal);
const runSplitOut = makeSourceVerbRunner("split_out", canSplitOut, splitOut);

// --- Splice runners ----------------------------------------------------

/** Split splice args at `+` and `@` separators into
 *  (target_tokens, card_token, position). */
function splitSpliceArgs(args: readonly string[]): [string[], string, number] {
  const plusIdx = args.indexOf("+");
  if (plusIdx < 0) {
    throw new Error(`splice scenario missing '+' separator: ${args.join(" ")}`);
  }
  const atIdx = args.indexOf("@");
  if (atIdx < 0) {
    throw new Error(`splice scenario missing '@' separator: ${args.join(" ")}`);
  }
  if (atIdx <= plusIdx) {
    throw new Error(`splice scenario '@' must follow '+': ${args.join(" ")}`);
  }
  const targetTokens = args.slice(0, plusIdx);
  const cardTokens = args.slice(plusIdx + 1, atIdx);
  const posTokens = args.slice(atIdx + 1);
  if (targetTokens.length === 0) {
    throw new Error(`splice scenario missing target cards: ${args.join(" ")}`);
  }
  if (cardTokens.length !== 1) {
    throw new Error(
      `splice scenario expects exactly 1 card between '+' and '@': ${args.join(" ")}`,
    );
  }
  if (posTokens.length !== 1) {
    throw new Error(
      `splice scenario expects exactly 1 token after '@': ${args.join(" ")}`,
    );
  }
  const pos = parseInt(posTokens[0]!, 10);
  if (!Number.isInteger(pos)) {
    throw new Error(`splice position not an int: ${posTokens[0]}`);
  }
  return [targetTokens, cardTokens[0]!, pos];
}

/** Build a runner for one splice variant. The runner parses the
 *  `<target>... + <card> @ <pos>` syntax, classifies the target, calls
 *  the probe, and compares against the `<left_kind> | <right_kind>`
 *  expected RHS (or `none`). */
function makeSpliceRunner(
  verbName: string,
  probe: (
    stack: ClassifiedCardStack,
    card: Card,
    position: number,
  ) => readonly [Kind, Kind] | null,
): Runner {
  return (args, expected) => {
    const [targetTokens, cardToken, pos] = splitSpliceArgs(args);
    const target = classifyStack(targetTokens.map(parseCardLabel));
    if (target === null) {
      return `${verbName} target failed to classify: ${targetTokens.join(" ")}`;
    }
    const card = parseCardLabel(cardToken);
    const result = probe(target, card, pos);
    if (expected === "none") {
      if (result === null) return null;
      return `expected none, got ${result[0]} | ${result[1]}`;
    }
    if (result === null) {
      return `expected ${expected}, got none`;
    }
    const parts = expected.split("|").map(p => p.trim()).filter(Boolean);
    if (parts.length !== 2) {
      return `splice expected RHS must be '<left_kind> | <right_kind>': ${expected}`;
    }
    const [wantLeft, wantRight] = parts as [string, string];
    if (result[0] !== wantLeft || result[1] !== wantRight) {
      return `expected ${wantLeft} | ${wantRight}, got ${result[0]} | ${result[1]}`;
    }
    return null;
  };
}

const runLeftSplice = makeSpliceRunner("left_splice", kindsAfterSpliceLeft);
const runRightSplice = makeSpliceRunner("right_splice", kindsAfterSpliceRight);

// --- splice_targets runner ---------------------------------------------
//
// Format: `splice_targets <parent>... + <card> → <cand>, <cand>, ...`
// where each <cand> is `<side>@<pos> <leftKind>|<rightKind>`. RHS `none`
// means no candidates. The order of candidates in the RHS must exactly
// match `findSpliceCandidates`'s emission order (ascending m, then
// left@m before right@(m+1)).

/** Split splice_targets args at `+` into (target_tokens, card_token).
 *  No `@` suffix on the LHS — position lives in the RHS list. */
function splitSpliceTargetsArgs(args: readonly string[]): [string[], string] {
  const plusIdx = args.indexOf("+");
  if (plusIdx < 0) {
    throw new Error(`splice_targets scenario missing '+' separator: ${args.join(" ")}`);
  }
  const targetTokens = args.slice(0, plusIdx);
  const cardTokens = args.slice(plusIdx + 1);
  if (targetTokens.length === 0) {
    throw new Error(`splice_targets scenario missing target cards: ${args.join(" ")}`);
  }
  if (cardTokens.length !== 1) {
    throw new Error(
      `splice_targets scenario expects exactly 1 card after '+': ${args.join(" ")}`,
    );
  }
  return [targetTokens, cardTokens[0]!];
}

function renderCandidate(c: SpliceCandidate): string {
  return `${c.side}@${c.position} ${c.leftKind}|${c.rightKind}`;
}

function parseCandidate(text: string, ctx: string): SpliceCandidate {
  // Format: "<side>@<pos> <lkind>|<rkind>"
  const parts = text.trim().split(/\s+/);
  if (parts.length !== 2) {
    throw new Error(`${ctx}: candidate must be '<side>@<pos> <lkind>|<rkind>': ${text}`);
  }
  const [head, kinds] = parts as [string, string];
  const atIdx = head.indexOf("@");
  if (atIdx < 0) {
    throw new Error(`${ctx}: candidate head missing '@': ${head}`);
  }
  const sideStr = head.slice(0, atIdx);
  const posStr = head.slice(atIdx + 1);
  if (sideStr !== "left" && sideStr !== "right") {
    throw new Error(`${ctx}: candidate side must be 'left' or 'right', got: ${sideStr}`);
  }
  const pos = parseInt(posStr, 10);
  if (!Number.isInteger(pos)) {
    throw new Error(`${ctx}: candidate position not an int: ${posStr}`);
  }
  const pipeIdx = kinds.indexOf("|");
  if (pipeIdx < 0) {
    throw new Error(`${ctx}: candidate kinds missing '|': ${kinds}`);
  }
  const leftKind = kinds.slice(0, pipeIdx) as Kind;
  const rightKind = kinds.slice(pipeIdx + 1) as Kind;
  return { side: sideStr as "left" | "right", position: pos, leftKind, rightKind };
}

function candidatesEqual(a: SpliceCandidate, b: SpliceCandidate): boolean {
  return a.side === b.side
    && a.position === b.position
    && a.leftKind === b.leftKind
    && a.rightKind === b.rightKind;
}

function runSpliceTargets(args: readonly string[], expected: string): RunResult {
  const [targetTokens, cardToken] = splitSpliceTargetsArgs(args);
  const target = classifyStack(targetTokens.map(parseCardLabel));
  if (target === null) {
    return `splice_targets target failed to classify: ${targetTokens.join(" ")}`;
  }
  const card = parseCardLabel(cardToken);
  const result = findSpliceCandidates(target, card);
  const expectedCands: SpliceCandidate[] =
    expected === "none"
      ? []
      : expected.split(",").map((p, i) => parseCandidate(p, `candidate ${i}`));
  if (result.length !== expectedCands.length) {
    const got = result.map(renderCandidate).join(", ") || "none";
    const want = expectedCands.map(renderCandidate).join(", ") || "none";
    return `expected ${expectedCands.length} candidates [${want}], got ${result.length} [${got}]`;
  }
  for (let i = 0; i < result.length; i++) {
    if (!candidatesEqual(result[i]!, expectedCands[i]!)) {
      return `candidate ${i}: expected ${renderCandidate(expectedCands[i]!)}, got ${renderCandidate(result[i]!)}`;
    }
  }
  return null;
}

// --- Multi-line block runner: extenders --------------------------------

type MultiRunner = (args: readonly string[], body: readonly BodyLine[]) => RunResult;

/** Parse the body of an `extenders` block into expected per-bucket
 *  shape→kind maps. */
function parseExtenderBody(body: readonly BodyLine[]): {
  left: ExtenderMap;
  right: ExtenderMap;
  set: ExtenderMap;
} {
  const expected = {
    left: new Map<number, Kind>(),
    right: new Map<number, Kind>(),
    set: new Map<number, Kind>(),
  };
  const seen = new Set<string>();
  for (const bl of body) {
    const colonIdx = bl.text.indexOf(":");
    if (colonIdx < 0) {
      throw new Error(
        `line ${bl.lineno}: bucket line missing ':': ${bl.text}`,
      );
    }
    const bucket = bl.text.slice(0, colonIdx).trim();
    const rest = bl.text.slice(colonIdx + 1).trim();
    if (bucket !== "left" && bucket !== "right" && bucket !== "set") {
      throw new Error(
        `line ${bl.lineno}: unknown bucket '${bucket}' (must be left / right / set)`,
      );
    }
    if (seen.has(bucket)) {
      throw new Error(`line ${bl.lineno}: bucket '${bucket}' listed twice`);
    }
    seen.add(bucket);
    if (rest === "-") continue;
    for (const entryRaw of rest.split(",")) {
      const entry = entryRaw.trim();
      const eqIdx = entry.indexOf("=");
      if (eqIdx < 0) {
        throw new Error(`line ${bl.lineno}: entry missing '=': ${entry}`);
      }
      const cardLabel = entry.slice(0, eqIdx).trim();
      const kindStr = entry.slice(eqIdx + 1).trim() as Kind;
      const card = parseCardLabel(cardLabel);
      const id = shapeId(card[0], card[1]);
      const map = expected[bucket];
      if (map.has(id)) {
        throw new Error(
          `line ${bl.lineno}: duplicate shape ${cardLabel} in bucket '${bucket}'`,
        );
      }
      map.set(id, kindStr);
    }
  }
  return expected;
}

function shapeLabel(id: number): string {
  const [v, s] = shapeFrom(id);
  // Render as "value,suit" — adequate for failure messages.
  return `(${v},${s})`;
}

function diffMap(
  bucketName: string,
  expected: ExtenderMap,
  actual: ExtenderMap,
  errors: string[],
): void {
  for (const [id, kind] of expected) {
    if (!actual.has(id)) {
      errors.push(`${bucketName}: missing entry ${shapeLabel(id)}=${kind}`);
    } else if (actual.get(id) !== kind) {
      errors.push(
        `${bucketName}: ${shapeLabel(id)} expected=${kind} got=${actual.get(id)}`,
      );
    }
  }
  for (const [id, kind] of actual) {
    if (!expected.has(id)) {
      errors.push(`${bucketName}: unexpected entry ${shapeLabel(id)}=${kind}`);
    }
  }
}

function runExtenders(args: readonly string[], body: readonly BodyLine[]): RunResult {
  const cards = args.map(parseCardLabel);
  const target = classifyStack(cards);
  if (target === null) {
    return `extenders target does not classify: ${args.join(" ")}`;
  }
  const expected = parseExtenderBody(body);
  const [actualLeft, actualRight, actualSet] = extendsTables(target);
  const errors: string[] = [];
  diffMap("left", expected.left, actualLeft, errors);
  diffMap("right", expected.right, actualRight, errors);
  diffMap("set", expected.set, actualSet, errors);
  return errors.length > 0 ? errors.join("; ") : null;
}

const RUNNERS: Readonly<Record<string, Runner>> = {
  classify: runClassify,
  right_absorb: runRightAbsorb,
  left_absorb: runLeftAbsorb,
  peel: runPeel,
  pluck: runPluck,
  yank: runYank,
  steal: runSteal,
  split_out: runSplitOut,
  left_splice: runLeftSplice,
  right_splice: runRightSplice,
  splice_targets: runSpliceTargets,
};

const RUNNERS_MULTI: Readonly<Record<string, MultiRunner>> = {
  extenders: runExtenders,
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
    let err: string | null;
    if (sc.body === null) {
      const runner = RUNNERS[sc.verb];
      if (!runner) {
        skipped++;
        continue;
      }
      total++;
      try {
        err = runner(sc.args, sc.expected!);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        err = `${e instanceof Error ? e.constructor.name : "Error"}: ${msg}`;
      }
    } else {
      const runner = RUNNERS_MULTI[sc.verb];
      if (!runner) {
        skipped++;
        continue;
      }
      total++;
      try {
        err = runner(sc.args, sc.body);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        err = `${e instanceof Error ? e.constructor.name : "Error"}: ${msg}`;
      }
    }
    if (err !== null) {
      const label = sc.comment || sc.raw;
      console.log(`FAIL ${filepath}:${sc.lineno} (${label}): ${err}`);
      failures++;
    }
  }
  return { total, passed: total - failures, failed: failures, skipped };
}

// --- Splice-candidates cross-check -------------------------------------
//
// Independently validates `findSpliceCandidates` against the existing
// `kindsAfterSpliceLeft/Right` probes. For each (parent, card) pair in
// a generated sweep, we compute:
//
//   - PROBE_SET: every (side, position) where the corresponding probe
//     returns a length-3+/length-3+ family-kind result.
//   - CAND_SET:  every (side, position) returned by findSpliceCandidates.
//
// The two sets must be EQUAL. Any mismatch surfaces a real bug rather
// than a paper-over. Runs once at startup before the DSL files.

function isLengthThreePlus(k: Kind): boolean {
  return k === KIND_RUN || k === KIND_RB;
}

function probeSetFor(parent: ClassifiedCardStack, card: Card): Set<string> {
  const out = new Set<string>();
  const n = parent.n;
  for (let p = 0; p <= n; p++) {
    const lr = kindsAfterSpliceLeft(parent, card, p);
    if (lr !== null && isLengthThreePlus(lr[0]) && isLengthThreePlus(lr[1])) {
      out.add(`left@${p} ${lr[0]}|${lr[1]}`);
    }
    const rr = kindsAfterSpliceRight(parent, card, p);
    if (rr !== null && isLengthThreePlus(rr[0]) && isLengthThreePlus(rr[1])) {
      out.add(`right@${p} ${rr[0]}|${rr[1]}`);
    }
  }
  return out;
}

function candSetFor(parent: ClassifiedCardStack, card: Card): Set<string> {
  const out = new Set<string>();
  for (const c of findSpliceCandidates(parent, card)) {
    out.add(`${c.side}@${c.position} ${c.leftKind}|${c.rightKind}`);
  }
  return out;
}

/** Generate rb run starting at (startValue, startSuit) with given length.
 *  Alternates colors strictly (each step flips red/black). Returns null
 *  if no rb of that length is buildable (e.g., wraparound conflict). */
function buildRbCards(startV: number, startSuit: number, len: number, deck = 0): Card[] | null {
  const cards: Card[] = [[startV, startSuit, deck]];
  let v = startV;
  let prevRed = [1, 3].includes(startSuit);
  // Pick a fixed alternating partner pattern: black ↔ red.
  // Choose suits 0=C (black), 1=D (red), 2=S (black), 3=H (red).
  const blackSuits = [0, 2];
  const redSuits = [1, 3];
  let blackIdx = blackSuits.indexOf(startSuit);
  let redIdx = redSuits.indexOf(startSuit);
  for (let i = 1; i < len; i++) {
    v = v === 13 ? 1 : v + 1;
    let s: number;
    if (prevRed) {
      blackIdx = (blackIdx + 1) % blackSuits.length;
      s = blackSuits[blackIdx]!;
    } else {
      redIdx = (redIdx + 1) % redSuits.length;
      s = redSuits[redIdx]!;
    }
    cards.push([v, s, deck]);
    prevRed = !prevRed;
  }
  return cards;
}

function buildRunCards(startV: number, suit: number, len: number, deck = 0): Card[] {
  const cards: Card[] = [];
  let v = startV;
  for (let i = 0; i < len; i++) {
    cards.push([v, suit, deck]);
    v = v === 13 ? 1 : v + 1;
  }
  return cards;
}

function spliceCrossCheck(): void {
  let parents = 0;
  let pairs = 0;
  // RB sweep: lengths 4..8, starting values 1..10, two starting suit choices.
  for (let len = 4; len <= 8; len++) {
    for (let startV = 1; startV <= 10; startV++) {
      for (const startSuit of [0, 1]) {
        const cards = buildRbCards(startV, startSuit, len);
        if (cards === null) continue;
        const stack = classifyStack(cards);
        if (stack === null || stack.kind !== KIND_RB) continue;
        parents++;
        // Sweep insert cards over a useful range: every (value, suit).
        for (let cv = 1; cv <= 13; cv++) {
          for (let cs = 0; cs < 4; cs++) {
            for (const cd of [0, 1]) {
              const card: Card = [cv, cs, cd];
              const ps = probeSetFor(stack, card);
              const cs2 = candSetFor(stack, card);
              pairs++;
              if (ps.size !== cs2.size) {
                throw new Error(
                  `crosscheck mismatch: parent=[${renderCards(cards)}] card=${renderCards([card])} probe={${[...ps].sort().join(",")}} cand={${[...cs2].sort().join(",")}}`,
                );
              }
              for (const e of ps) {
                if (!cs2.has(e)) {
                  throw new Error(
                    `crosscheck missing-candidate: parent=[${renderCards(cards)}] card=${renderCards([card])} probe-has=${e} cand={${[...cs2].sort().join(",")}}`,
                  );
                }
              }
              for (const e of cs2) {
                if (!ps.has(e)) {
                  throw new Error(
                    `crosscheck spurious-candidate: parent=[${renderCards(cards)}] card=${renderCards([card])} cand-has=${e} probe={${[...ps].sort().join(",")}}`,
                  );
                }
              }
            }
          }
        }
      }
    }
  }
  // Pure-run sweep: lengths 4..8, starting values 1..10, all four suits.
  for (let len = 4; len <= 8; len++) {
    for (let startV = 1; startV <= 10; startV++) {
      for (let suit = 0; suit < 4; suit++) {
        const cards = buildRunCards(startV, suit, len);
        const stack = classifyStack(cards);
        if (stack === null || stack.kind !== KIND_RUN) continue;
        parents++;
        for (let cv = 1; cv <= 13; cv++) {
          for (let cs = 0; cs < 4; cs++) {
            for (const cd of [0, 1]) {
              const card: Card = [cv, cs, cd];
              const ps = probeSetFor(stack, card);
              const cs2 = candSetFor(stack, card);
              pairs++;
              if (ps.size !== cs2.size) {
                throw new Error(
                  `crosscheck mismatch: parent=[${renderCards(cards)}] card=${renderCards([card])} probe={${[...ps].sort().join(",")}} cand={${[...cs2].sort().join(",")}}`,
                );
              }
              for (const e of ps) {
                if (!cs2.has(e)) {
                  throw new Error(
                    `crosscheck missing-candidate: parent=[${renderCards(cards)}] card=${renderCards([card])} probe-has=${e} cand={${[...cs2].sort().join(",")}}`,
                  );
                }
              }
              for (const e of cs2) {
                if (!ps.has(e)) {
                  throw new Error(
                    `crosscheck spurious-candidate: parent=[${renderCards(cards)}] card=${renderCards([card])} cand-has=${e} probe={${[...ps].sort().join(",")}}`,
                  );
                }
              }
            }
          }
        }
      }
    }
  }
  console.log(`splice-candidates crosscheck: ${parents} parents × insert sweep = ${pairs} pairs verified.`);
}

function main(): void {
  if (!fs.existsSync(LEAF_DSL_DIR)) {
    console.error(`no leaf-DSL dir at ${LEAF_DSL_DIR}`);
    process.exit(1);
  }
  spliceCrossCheck();
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
