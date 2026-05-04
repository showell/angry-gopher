// test_physical_plan — runs `physical_plan_corpus.dsl` scenarios
// through `physicalPlan` and asserts (a) the emitted primitive
// sequence matches the pinned `expect.primitives`, AND (b)
// findViolation is null after every applied primitive.
//
// The per-step overlap check is the load-bearing assertion: it
// catches any moment the emitter creates an illegal board, not just
// scenarios where the violation persists to the final state.

import * as fs from "node:fs";
import * as path from "node:path";

import { parseCardLabel, cardLabel, type Card } from "../src/rules/card.ts";
import type { BoardStack, Loc } from "../src/geometry.ts";
import { findViolation } from "../src/geometry.ts";
import {
  type Primitive,
  applyLocally,
} from "../src/primitives.ts";
import type {
  Desc, Verb, AbsorberBucket,
  ExtractAbsorbDesc, FreePullDesc, PushDesc,
  ShiftDesc, SpliceDesc, DecomposeDesc,
} from "../src/move.ts";
import { physicalPlan } from "../src/physical_plan.ts";

const DSL_PATH = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../conformance/scenarios/physical_plan_corpus.dsl",
);

// --- Card label conversion ------------------------------------------

function dslLabelToTs(s: string): string {
  return s.endsWith("'") ? s.slice(0, -1) + ":1" : s;
}
function tsLabelToDsl(s: string): string {
  return s.endsWith(":1") ? s.slice(0, -2) + "'" : s;
}
function parseList(s: string): Card[] {
  return s.trim().split(/\s+/).filter(Boolean).map(t => parseCardLabel(dslLabelToTs(t)));
}
function parseOne(s: string): Card { return parseCardLabel(dslLabelToTs(s.trim())); }

function fmtCs(cs: readonly Card[]): string {
  return cs.map(c => tsLabelToDsl(cardLabel(c))).join(" ");
}
function fmtCard(c: Card): string { return tsLabelToDsl(cardLabel(c)); }

function fmtPrim(p: Primitive, board: readonly BoardStack[]): string {
  switch (p.action) {
    case "split":
      return `split [${fmtCs(board[p.stackIndex]!.cards)}]@${p.cardIndex}`;
    case "merge_stack":
      return `merge_stack [${fmtCs(board[p.sourceStack]!.cards)}] -> [${fmtCs(board[p.targetStack]!.cards)}] /${p.side}`;
    case "merge_hand":
      return `merge_hand ${fmtCard(p.handCard)} -> [${fmtCs(board[p.targetStack]!.cards)}] /${p.side}`;
    case "move_stack":
      return `move_stack [${fmtCs(board[p.stackIndex]!.cards)}] -> (${p.newLoc.top},${p.newLoc.left})`;
    case "place_hand":
      return `place_hand ${fmtCard(p.handCard)} -> (${p.loc.top},${p.loc.left})`;
  }
}

// --- DSL parser -----------------------------------------------------

interface VerbBlock {
  readonly verb: string;
  readonly fields: Record<string, string>;
}

interface Scenario {
  readonly name: string;
  readonly desc: string;
  readonly board: { top: number; left: number; cards: Card[] }[];
  readonly hand: Card[];
  readonly plan: VerbBlock[];
  readonly primitives: string[];
}

function parseDsl(text: string): Scenario[] {
  const lines = text.split("\n");
  const out: Scenario[] = [];
  let cur: Partial<Scenario> & {
    name?: string; desc?: string;
    board?: { top: number; left: number; cards: Card[] }[];
    hand?: Card[]; plan?: VerbBlock[]; primitives?: string[];
  } | null = null;
  let inBoard = false, inHand = false, inPlan = false, inPrims = false;
  let curVerb: VerbBlock | null = null;

  function commit() {
    if (cur && cur.name) {
      out.push({
        name: cur.name,
        desc: cur.desc ?? "",
        board: cur.board ?? [],
        hand: cur.hand ?? [],
        plan: cur.plan ?? [],
        primitives: cur.primitives ?? [],
      });
    }
  }

  for (const raw of lines) {
    const stripped = raw.replace(/#.*$/, "").trimEnd();
    const trimmed = stripped.trim();
    const m = trimmed.match(/^scenario\s+(\S+)$/);
    if (m && raw.match(/^scenario\b/)) {
      commit();
      cur = { name: m[1], board: [], hand: [], plan: [], primitives: [] };
      inBoard = inHand = inPlan = inPrims = false;
      curVerb = null;
      continue;
    }
    if (!cur) continue;

    if (trimmed === "board:") { inBoard = true; inHand = inPlan = inPrims = false; continue; }
    if (trimmed === "plan:")  { inPlan  = true; inBoard = inHand = inPrims = false; curVerb = null; continue; }
    if (trimmed === "expect:") { inBoard = inHand = inPlan = false; continue; }
    if (trimmed === "primitives:") { inPrims = true; continue; }

    if (trimmed.startsWith("hand:")) {
      const after = trimmed.slice("hand:".length).trim();
      cur.hand = after.length > 0 ? parseList(after) : [];
      inHand = false;  // single-line for now
      inBoard = inPlan = inPrims = false;
      continue;
    }

    if (inBoard && trimmed.startsWith("at ")) {
      const bm = trimmed.match(/^at\s*\((-?\d+)\s*,\s*(-?\d+)\)\s*:\s*(.+)$/);
      if (bm) cur.board!.push({ top: +bm[1]!, left: +bm[2]!, cards: parseList(bm[3]!) });
      continue;
    }

    if (inPlan) {
      const verbStart = trimmed.match(/^-\s*verb:\s*(\S+)$/);
      if (verbStart) {
        curVerb = { verb: verbStart[1]!, fields: {} };
        cur.plan!.push(curVerb);
        continue;
      }
      const kv = trimmed.match(/^([a-z_]+)\s*:\s*(.*)$/);
      if (kv && curVerb) {
        curVerb.fields[kv[1]!] = kv[2]!;
        continue;
      }
    }

    if (inPrims && trimmed.startsWith("- ")) {
      cur.primitives!.push(trimmed.slice(2));
      continue;
    }

    const kv = trimmed.match(/^([a-z_]+)\s*:\s*(.*)$/);
    if (kv && cur && !inPlan) {
      const k = kv[1]!;
      if (k === "desc") cur.desc = kv[2];
    }
  }
  commit();
  return out;
}

// --- Verb-block → Desc ----------------------------------------------

function buildDesc(vb: VerbBlock): Desc {
  const f = vb.fields;
  const verb = vb.verb;
  const side = (f.side ?? "right") as "left" | "right";
  if (["peel", "pluck", "yank", "steal", "split_out"].includes(verb)) {
    const d: ExtractAbsorbDesc = {
      type: "extract_absorb",
      verb: verb as Verb,
      source: parseList(f.source!),
      extCard: parseOne(f.ext_card!),
      targetBefore: parseList(f.target_before!),
      targetBucketBefore: (f.target_bucket ?? "trouble") as AbsorberBucket,
      result: [], side, graduated: false, spawned: [],
    };
    return d;
  }
  if (verb === "free_pull") {
    const d: FreePullDesc = {
      type: "free_pull",
      loose: parseOne(f.loose!),
      targetBefore: parseList(f.target_before!),
      targetBucketBefore: (f.target_bucket ?? "trouble") as AbsorberBucket,
      result: [], side, graduated: false,
    };
    return d;
  }
  if (verb === "push") {
    const d: PushDesc = {
      type: "push",
      troubleBefore: parseList(f.trouble_before!),
      targetBefore: parseList(f.target_before!),
      result: [], side,
    };
    return d;
  }
  if (verb === "splice") {
    const d: SpliceDesc = {
      type: "splice",
      loose: parseOne(f.loose!),
      source: parseList(f.source!),
      k: +f.k!, side,
      leftResult: [], rightResult: [],
    };
    return d;
  }
  if (verb === "shift") {
    const we = f.which_end!;
    const whichEnd = we === "left" ? 0 : we === "right" ? 2 : +we;
    const d: ShiftDesc = {
      type: "shift",
      source: parseList(f.source!),
      donor: parseList(f.donor!),
      stolen: parseOne(f.stolen!),
      pCard: parseOne(f.p_card!),
      whichEnd,
      newSource: [], newDonor: [],
      targetBefore: parseList(f.target_before!),
      targetBucketBefore: (f.target_bucket ?? "trouble") as AbsorberBucket,
      merged: [], side, graduated: false,
    };
    return d;
  }
  if (verb === "decompose") {
    const pair = parseList(f.pair_before!);
    const d: DecomposeDesc = {
      type: "decompose",
      pairBefore: pair,
      leftCard: pair[0]!,
      rightCard: pair[1]!,
    };
    return d;
  }
  throw new Error(`unknown verb: ${verb}`);
}

// --- Runner ---------------------------------------------------------

interface RunResult { ok: boolean; msg: string }

function runScenario(sc: Scenario): RunResult {
  const board: BoardStack[] = sc.board.map(b => ({
    cards: b.cards, loc: { top: b.top, left: b.left },
  }));
  let descs: Desc[];
  try {
    descs = sc.plan.map(buildDesc);
  } catch (e) {
    return { ok: false, msg: `desc-build error: ${(e as Error).message}` };
  }

  let prims: readonly Primitive[];
  try {
    prims = physicalPlan(board, sc.hand, descs);
  } catch (e) {
    return { ok: false, msg: `physicalPlan threw: ${(e as Error).message}` };
  }

  // Walk + per-step overlap check + render.
  const got: string[] = [];
  let sim: readonly BoardStack[] = board;
  for (let i = 0; i < prims.length; i++) {
    const p = prims[i]!;
    got.push(fmtPrim(p, sim));
    sim = applyLocally(sim, p);
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

  if (got.length !== sc.primitives.length) {
    return {
      ok: false,
      msg: `primitive count mismatch: want ${sc.primitives.length}, got ${got.length}\n  want: ${JSON.stringify(sc.primitives)}\n  got:  ${JSON.stringify(got)}`,
    };
  }
  for (let i = 0; i < got.length; i++) {
    if (got[i] !== sc.primitives[i]) {
      return {
        ok: false,
        msg: `primitive[${i}] mismatch:\n  want: ${sc.primitives[i]}\n  got:  ${got[i]}`,
      };
    }
  }

  return { ok: true, msg: `OK — ${prims.length} primitives (per-step geometry clean)` };
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
    console.log(`${tag}  ${sc.name.padEnd(48)} ${r.msg}`);
    if (r.ok) pass++; else fail++;
  }
  console.log(`\n${pass}/${pass + fail} physical_plan scenarios passed`);
  if (fail > 0) process.exit(1);
}

main();
