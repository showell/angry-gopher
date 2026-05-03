// verify_clean_board.ts — independent verification of a BFS solution.
//
// Take initial Buckets + the plan_lines (with descs), re-walk the
// plan via enumerateMoves at each step to derive the final state,
// then check:
//   1. All initial cards are present in final state (no losses, no duplicates).
//   2. Every final stack classifies as a legal length-3+ kind (run/rb/set).
//   3. trouble + length-2 partials in growing are gone.
//
// This sidesteps trusting the BFS's internal bookkeeping — re-walking
// uses the enumerator independently and the final-state check uses
// classifyStack as ground truth.

import { type Buckets, type RawBuckets, classifyBuckets } from "../src/buckets.ts";
import { classifyStack } from "../src/classified_card_stack.ts";
import { enumerateMoves } from "../src/enumerator.ts";
import { describe, type Desc } from "../src/move.ts";
import { type Card } from "../src/rules/card.ts";

export interface VerifyResult {
  readonly ok: boolean;
  readonly msg: string;
}

function cardKey(c: Card): string {
  return `${c[0]},${c[1]},${c[2]}`;
}

function collectCards(b: Buckets): string[] {
  const out: string[] = [];
  for (const bucket of [b.helper, b.partials ?? [], b.complete] as const) {
    for (const stack of bucket) for (const c of stack.cards) out.push(cardKey(c));
  }
  // Backwards-compat: handle old-shape Buckets with trouble + growing.
  const t = (b as { trouble?: typeof b.helper }).trouble;
  const g = (b as { growing?: typeof b.helper }).growing;
  if (t) for (const stack of t) for (const c of stack.cards) out.push(cardKey(c));
  if (g) for (const stack of g) for (const c of stack.cards) out.push(cardKey(c));
  return out;
}

function applyPlan(initial: Buckets, plan: readonly { desc: Desc }[]): Buckets {
  let state: Buckets = initial;
  for (let step = 0; step < plan.length; step++) {
    const want = describe(plan[step]!.desc);
    let matched: Buckets | null = null;
    for (const [desc, next] of enumerateMoves(state)) {
      if (describe(desc) === want) { matched = next; break; }
    }
    if (matched === null) {
      throw new Error(`step ${step + 1}: enumerator did not yield matching move "${want}"`);
    }
    state = matched;
  }
  return state;
}

export function verifyCleanBoard(
  initial: Buckets,
  plan: readonly { desc: Desc }[],
): VerifyResult {
  let final: Buckets;
  try {
    final = applyPlan(initial, plan);
  } catch (e) {
    return { ok: false, msg: `replay failed: ${(e as Error).message}` };
  }

  // (1) Card conservation.
  const initialCards = collectCards(initial).sort();
  const finalCards = collectCards(final).sort();
  if (initialCards.length !== finalCards.length) {
    return { ok: false, msg: `card count drift: initial ${initialCards.length}, final ${finalCards.length}` };
  }
  for (let i = 0; i < initialCards.length; i++) {
    if (initialCards[i] !== finalCards[i]) {
      return { ok: false, msg: `card mismatch at sorted index ${i}: initial ${initialCards[i]}, final ${finalCards[i]}` };
    }
  }

  // (2) + (3) Every stack in final state is a legal length-3+ group.
  // trouble (if present) must be empty; growing (if present) must have
  // only length-3+ entries; partials (collapsed bucket) likewise.
  const allBucketsAfter: Array<readonly { kind: string; n: number; cards: readonly Card[] }[]> = [];
  for (const name of ["helper", "trouble", "growing", "partials", "complete"] as const) {
    const bucket = (final as { [k: string]: unknown })[name];
    if (Array.isArray(bucket)) allBucketsAfter.push(bucket as never);
  }

  for (const bucket of allBucketsAfter) {
    for (const stack of bucket) {
      const reclassified = classifyStack(stack.cards);
      if (reclassified === null) {
        return { ok: false, msg: `final stack [${stack.cards.map(cardKey).join(" ")}] failed to re-classify` };
      }
      if (reclassified.n < 3) {
        return { ok: false, msg: `final stack [${stack.cards.map(cardKey).join(" ")}] is length ${reclassified.n}; not graduated` };
      }
      if (reclassified.kind !== "run" && reclassified.kind !== "rb" && reclassified.kind !== "set") {
        return { ok: false, msg: `final stack [${stack.cards.map(cardKey).join(" ")}] kind ${reclassified.kind} is not a length-3+ legal kind` };
      }
    }
  }

  return { ok: true, msg: `final state clean (${initialCards.length} cards, all stacks legal length-3+)` };
}

// --- Test the verifier on the 5 newly-solvable scenarios ----------------

import { solveStateWithDescs } from "../src/bfs.ts";
import * as fs from "node:fs";
import * as path from "node:path";

interface BoardCard { card: { value: number; suit: number; origin_deck: number } }
interface BoardStack { board_cards: BoardCard[] }
interface Scenario {
  name: string;
  op: string;
  helper?: BoardStack[];
  trouble?: BoardStack[];
  growing?: BoardStack[];
  complete?: BoardStack[];
  expect: Record<string, unknown>;
}

const FIXTURES = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../python/conformance_fixtures.json",
);

function bucketToTuples(stacks: BoardStack[] | undefined): Card[][] {
  if (!stacks) return [];
  return stacks.map(s => s.board_cards.map(bc => [bc.card.value, bc.card.suit, bc.card.origin_deck] as const));
}

function buildRaw(sc: Scenario): RawBuckets {
  return {
    helper: bucketToTuples(sc.helper),
    trouble: bucketToTuples(sc.trouble),
    growing: bucketToTuples(sc.growing),
    complete: bucketToTuples(sc.complete),
  };
}

const TARGETS = ["extra_003_5D_6C", "extra_004_5D_6C", "extra_008_4S_5Dp", "extra_011_THp", "extra_012_THp"];

const all: Scenario[] = JSON.parse(fs.readFileSync(FIXTURES, "utf8"));
for (const name of TARGETS) {
  const sc = all.find(s => s.name === name);
  if (!sc) { console.log(`${name}: NOT FOUND`); continue; }
  const initial = classifyBuckets(buildRaw(sc));
  const plan = solveStateWithDescs(initial, { maxTroubleOuter: 12, maxStates: 200000 });
  if (plan === null) { console.log(`${name}: STUCK (unexpected)`); continue; }
  const result = verifyCleanBoard(initial, plan);
  console.log(`${name}: ${result.ok ? "OK" : "FAIL"}  (plan ${plan.length} lines)  ${result.msg}`);
}
