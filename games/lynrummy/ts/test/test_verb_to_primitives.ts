// test_verb_to_primitives.ts — TS-only DSL runner for the verb→primitive
// pipeline. Reads two sibling DSL files:
//
//   verb_to_primitives.dsl         — hand-authored, one scenario per
//                                    verb category + edge cases (~8)
//   verb_to_primitives_corpus.dsl  — auto-converted from the former
//                                    primitives_fixtures.json; one
//                                    scenario per BFS plan step
//                                    across the 25 mined puzzles (94)
//
// For each scenario, asserts that `verbs.moveToPrimitives(desc,
// board)` emits the expected primitive sequence after the geometry
// post-pass.
//
// TS-only because the verb pipeline is TS-canonical going forward.
// Card-label convention: `4D'` for deck-1 (matches replay_walkthroughs);
// the parser converts `'` → `:1` for parseCardLabel.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import type { Card } from "../src/rules/card.ts";
import { parseCardLabel, cardLabel } from "../src/rules/card.ts";
import type {
  Desc, Side,
  ExtractAbsorbDesc, FreePullDesc, PushDesc,
  SpliceDesc, ShiftDesc, DecomposeDesc,
  Verb,
  AbsorberBucket,
} from "../src/move.ts";
import type { BoardStack, Loc } from "../src/geometry.ts";
import { findViolation } from "../src/geometry.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import {
  type Primitive,
} from "../src/primitives.ts";
import { moveToPrimitives } from "../src/verbs.ts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DSL_DIR = path.resolve(__dirname, "../../conformance/scenarios");
const DSL_FILES = [
  "verb_to_primitives.dsl",
  "verb_to_primitives_corpus.dsl",
];

// Card-label convention. The corpus DSL (and replay_walkthroughs.dsl)
// uses `'` for deck-1 (`4D'` = 4 of diamonds, deck-1). parseCardLabel
// expects `:1`. Convert at the parse boundary; emit with `'` so
// expected/got strings round-trip.
function dslLabelToTsLabel(s: string): string {
  return s.endsWith("'") ? s.slice(0, -1) + ":1" : s;
}

function tsLabelToDslLabel(s: string): string {
  return s.endsWith(":1") ? s.slice(0, -2) + "'" : s;
}

// --- DSL parser -------------------------------------------------------

interface ScenarioRaw {
  readonly name: string;
  readonly fields: Record<string, string>;
  readonly board: { top: number; left: number; cards: readonly Card[] }[];
  readonly primitives: readonly string[];
}

function stripInlineComment(line: string): string {
  const i = line.indexOf("#");
  return (i < 0 ? line : line.slice(0, i)).trimEnd();
}

function parseDsl(contents: string): ScenarioRaw[] {
  const out: ScenarioRaw[] = [];
  const lines = contents.split("\n");
  let cur: ScenarioRaw | null = null;
  let inBoard = false;
  let inPrimitives = false;
  let inExpect = false;
  let i = 0;
  for (i = 0; i < lines.length; i++) {
    const raw = lines[i]!;
    const stripped = stripInlineComment(raw);
    const trimmed = stripped.trim();
    if (trimmed === "") continue;

    // Top-of-line `scenario <name>` starts a new block.
    const sc = trimmed.match(/^scenario\s+(\S+)$/);
    if (sc && raw.match(/^scenario\b/)) {
      if (cur) out.push(cur);
      cur = { name: sc[1]!, fields: {}, board: [], primitives: [] };
      inBoard = false;
      inPrimitives = false;
      inExpect = false;
      continue;
    }
    if (cur === null) continue;

    // Indent level (count leading spaces).
    const indent = raw.length - raw.replace(/^ +/, "").length;

    if (indent <= 2 || inExpect && indent <= 4 && trimmed.startsWith("primitives:")) {
      inBoard = false;
      inPrimitives = false;
    }

    if (trimmed === "board:") { inBoard = true; continue; }
    if (trimmed === "expect:") { inExpect = true; continue; }
    if (inExpect && trimmed === "primitives:") { inPrimitives = true; continue; }

    if (inBoard) {
      const m = trimmed.match(/^at\s*\((-?\d+)\s*,\s*(-?\d+)\)\s*:\s*(.+)$/);
      if (m) {
        const top = parseInt(m[1]!, 10);
        const left = parseInt(m[2]!, 10);
        const cards = m[3]!.trim().split(/\s+/)
          .map(s => parseCardLabel(dslLabelToTsLabel(s)));
        cur.board.push({ top, left, cards });
        continue;
      }
    }

    if (inPrimitives) {
      const m = trimmed.match(/^-\s*(.+)$/);
      if (m) { cur.primitives = [...cur.primitives, m[1]!.trim()]; continue; }
    }

    // Plain `key: value` line.
    const kv = trimmed.match(/^([a-z_]+)\s*:\s*(.*)$/);
    if (kv) {
      const key = kv[1]!;
      const val = kv[2]!;
      if (key === "board" || key === "expect" || key === "primitives") continue;
      cur.fields[key] = val;
    }
  }
  if (cur) out.push(cur);
  return out;
}

// --- Build inputs from parsed scenario -------------------------------

function parseCardList(s: string): readonly Card[] {
  if (!s.trim()) return [];
  return s.trim().split(/\s+/).map(t => parseCardLabel(dslLabelToTsLabel(t)));
}

function parseSingleCard(s: string): Card {
  const tokens = s.trim().split(/\s+/);
  if (tokens.length !== 1) throw new Error(`expected single card, got "${s}"`);
  return parseCardLabel(dslLabelToTsLabel(tokens[0]!));
}

function buildBoardStacks(sc: ScenarioRaw): readonly BoardStack[] {
  return sc.board.map(b => ({
    cards: b.cards,
    loc: { top: b.top, left: b.left } as Loc,
  }));
}

function buildDesc(sc: ScenarioRaw): Desc {
  const f = sc.fields;
  const verb = f["verb"];
  if (!verb) throw new Error(`scenario ${sc.name}: missing verb:`);
  const side = (f["side"] ?? "right") as Side;
  // ExtractAbsorb-shaped verbs (peel/pluck/yank/steal/split_out)
  if (["peel", "pluck", "yank", "steal", "split_out"].includes(verb)) {
    const source = parseCardList(f["source"] ?? "");
    const extCard = parseSingleCard(f["ext_card"] ?? "");
    const targetBefore = parseCardList(f["target_before"] ?? "");
    // Reconstruct `result` and other fields well enough for the
    // pipeline to run. moveToPrimitives only uses verb / source /
    // ext_card / target_before / side; the others are placeholders.
    const desc: ExtractAbsorbDesc = {
      type: "extract_absorb",
      verb: verb as Verb,
      source,
      extCard,
      targetBefore,
      targetBucketBefore: (f["target_bucket"] ?? "trouble") as AbsorberBucket,
      result: [...targetBefore, extCard],
      side,
      graduated: false,
      spawned: [],
    };
    return desc;
  }
  if (verb === "free_pull") {
    const loose = parseSingleCard(f["loose"] ?? "");
    const targetBefore = parseCardList(f["target_before"] ?? "");
    const desc: FreePullDesc = {
      type: "free_pull",
      loose,
      targetBefore,
      targetBucketBefore: (f["target_bucket"] ?? "trouble") as AbsorberBucket,
      result: side === "left" ? [loose, ...targetBefore] : [...targetBefore, loose],
      side,
      graduated: false,
    };
    return desc;
  }
  if (verb === "push") {
    const troubleBefore = parseCardList(f["trouble_before"] ?? "");
    const targetBefore = parseCardList(f["target_before"] ?? "");
    const desc: PushDesc = {
      type: "push",
      troubleBefore,
      targetBefore,
      result: side === "left"
        ? [...troubleBefore, ...targetBefore]
        : [...targetBefore, ...troubleBefore],
      side,
    };
    return desc;
  }
  if (verb === "splice") {
    const loose = parseSingleCard(f["loose"] ?? "");
    const source = parseCardList(f["source"] ?? "");
    const k = parseInt(f["k"] ?? "0", 10);
    const desc: SpliceDesc = {
      type: "splice",
      loose, source, k, side,
      leftResult: side === "left" ? [...source.slice(0, k), loose] : source.slice(0, k),
      rightResult: side === "right" ? [loose, ...source.slice(k)] : source.slice(k),
    };
    return desc;
  }
  if (verb === "shift") {
    const source = parseCardList(f["source"] ?? "");
    const donor = parseCardList(f["donor"] ?? "");
    const stolen = parseSingleCard(f["stolen"] ?? "");
    const pCard = parseSingleCard(f["p_card"] ?? "");
    // which_end: corpus DSL uses string ("left"/"right"); the runtime
    // type is int (0 = left, 2 = right). Accept either.
    const weRaw = f["which_end"] ?? "0";
    const whichEnd = weRaw === "left" ? 0
      : weRaw === "right" ? 2
      : parseInt(weRaw, 10);
    const targetBefore = parseCardList(f["target_before"] ?? "");
    // newSource / newDonor / merged are reconstructed below well
    // enough for shape; moveToPrimitives doesn't read them.
    const desc: ShiftDesc = {
      type: "shift",
      source, donor, stolen, pCard, whichEnd,
      newSource: source,
      newDonor: donor,
      targetBefore,
      targetBucketBefore: (f["target_bucket"] ?? "trouble") as AbsorberBucket,
      merged: [...targetBefore, stolen],
      side,
      graduated: false,
    };
    return desc;
  }
  if (verb === "decompose") {
    const pairBefore = parseCardList(f["pair_before"] ?? "");
    if (pairBefore.length !== 2) {
      throw new Error(`decompose pair_before must be length 2; got ${pairBefore.length}`);
    }
    const desc: DecomposeDesc = {
      type: "decompose",
      pairBefore,
      leftCard: pairBefore[0]!,
      rightCard: pairBefore[1]!,
    };
    return desc;
  }
  throw new Error(`unknown verb ${verb}`);
}

// --- Render primitives back to DSL strings ----------------------------

function fmtCards(cards: readonly Card[]): string {
  return cards.map(c => tsLabelToDslLabel(cardLabel(c))).join(" ");
}

function fmtCard(c: Card): string {
  return tsLabelToDslLabel(cardLabel(c));
}

function fmtPrimitive(p: Primitive, board: readonly BoardStack[]): string {
  // Convention: coords as (top,left) no-space, matching
  // replay_walkthroughs.dsl + the corpus DSL.
  switch (p.action) {
    case "split":
      return `split [${fmtCards(board[p.stackIndex]!.cards)}]@${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack [${fmtCards(board[p.sourceStack]!.cards)}] -> [${fmtCards(board[p.targetStack]!.cards)}] /${p.side}`;
    case "merge_hand":
      return `merge_hand ${fmtCard(p.handCard)} -> [${fmtCards(board[p.targetStack]!.cards)}] /${p.side}`;
    case "move_stack":
      return `move_stack [${fmtCards(board[p.stackIndex]!.cards)}] -> (${p.newLoc.top},${p.newLoc.left})`;
    case "place_hand":
      return `place_hand ${fmtCard(p.handCard)} -> (${p.loc.top},${p.loc.left})`;
  }
}

function applyPrimitiveLocal(
  board: readonly BoardStack[],
  p: Primitive,
): readonly BoardStack[] {
  // Re-import to avoid circular weirdness in test file.
  // (Same logic as primitives.applyLocally.)
  // Defer to the canonical impl.
  return applyLocallyForRender(board, p);
}

import { applyLocally as applyLocallyForRender } from "../src/primitives.ts";

void applyPrimitiveLocal; // kept for clarity above; the real call is below.

// --- Runner ---------------------------------------------------------

interface RunResult {
  readonly ok: boolean;
  readonly msg: string;
}

function runScenario(sc: ScenarioRaw): RunResult {
  let desc: Desc;
  try {
    desc = buildDesc(sc);
  } catch (e) {
    return { ok: false, msg: `desc-build error: ${(e as Error).message}` };
  }
  const board = buildBoardStacks(sc);

  let prims: readonly Primitive[];
  try {
    prims = moveToPrimitives(desc, board);
  } catch (e) {
    return { ok: false, msg: `pipeline error: ${(e as Error).message}` };
  }

  // Render the primitive sequence by walking through board states so
  // each primitive's referenced stacks resolve to readable card-list
  // strings (matching DSL syntax). At each step, assert no geometry
  // violation — catches drift the moment the emitter creates one.
  const got: string[] = [];
  let sim = board;
  for (let i = 0; i < prims.length; i++) {
    const p = prims[i]!;
    got.push(fmtPrimitive(p, sim));
    sim = applyLocallyForRender(sim, p);
    const v = findViolation(sim);
    if (v !== null) {
      const s = sim[v]!;
      return {
        ok: false,
        msg: `intermediate geometry violation after primitive[${i}] (${got[i]}) `
          + `at stack ${v} [${s.cards.map(c => c.join(",")).join(" ")}] @ (${s.loc.top},${s.loc.left})`,
      };
    }
  }
  const want = sc.primitives;

  if (got.length !== want.length) {
    return {
      ok: false,
      msg: `primitive count mismatch: want ${want.length}, got ${got.length}\n  want: ${JSON.stringify(want)}\n  got:  ${JSON.stringify(got)}`,
    };
  }
  for (let i = 0; i < got.length; i++) {
    if (got[i] !== want[i]) {
      return {
        ok: false,
        msg: `primitive[${i}] mismatch:\n  want: ${want[i]}\n  got:  ${got[i]}`,
      };
    }
  }

  // Sanity check: every final-board stack classifies legally is too
  // strong (some scenarios leave intermediate-shape boards). Just
  // verify no crash + cards conserved.
  const initialCount = board.reduce((n, s) => n + s.cards.length, 0);
  const finalCount = sim.reduce((n, s) => n + s.cards.length, 0);
  if (initialCount !== finalCount) {
    return {
      ok: false,
      msg: `card count drift: initial ${initialCount}, final ${finalCount}`,
    };
  }

  // GEOMETRY INVARIANT: post-sequence board has no overlapping
  // stacks. Per Steve, 2026-05-03: NO OVERLAPPING STACKS. If the
  // verb pipeline emits a primitive sequence whose final state has
  // two stacks colliding, that's a bug at the verb→primitive layer
  // — surface it loud, don't silently ship a transcript that the
  // UI can't render cleanly.
  const violation = findViolation(sim);
  if (violation !== null) {
    const s = sim[violation]!;
    return {
      ok: false,
      msg: `geometry violation at stack ${violation} `
        + `[${s.cards.map(c => c.join(",")).join(" ")}] @ (${s.loc.top},${s.loc.left})`,
    };
  }

  // Suppress unused-warning for classifyStack (kept for future
  // assertions on final-board shape).
  void classifyStack;

  return { ok: true, msg: `OK — ${prims.length} primitives (geometry clean)` };
}

// --- Main --------------------------------------------------------------

function main(): void {
  let totalPassed = 0;
  let totalFailed = 0;
  const failures: string[] = [];
  let totalScenarios = 0;
  let quietCorpus = false;

  for (const fname of DSL_FILES) {
    const filepath = path.join(DSL_DIR, fname);
    if (!fs.existsSync(filepath)) {
      console.error(`no DSL at ${filepath}`);
      process.exit(1);
    }
    const contents = fs.readFileSync(filepath, "utf8");
    const scenarios = parseDsl(contents);
    totalScenarios += scenarios.length;

    // The corpus DSL has 94 scenarios — too noisy to print every PASS.
    // Print failures only; show a summary line per file.
    quietCorpus = fname.endsWith("_corpus.dsl");

    let filePassed = 0;
    let fileFailed = 0;
    for (const sc of scenarios) {
      const res = runScenario(sc);
      if (res.ok) {
        filePassed++;
        if (!quietCorpus) console.log(`PASS  ${sc.name.padEnd(50)}  ${res.msg}`);
      } else {
        fileFailed++;
        const line = `FAIL  ${sc.name.padEnd(50)}  ${res.msg}`;
        console.log(line);
        failures.push(line);
      }
    }
    console.log(`  ${fname}: ${filePassed}/${scenarios.length} passed`);
    totalPassed += filePassed;
    totalFailed += fileFailed;
  }

  console.log();
  console.log(`TOTAL: ${totalPassed}/${totalScenarios} passed`);
  if (totalFailed > 0) {
    process.exit(1);
  }
}

main();
