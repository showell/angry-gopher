// hunt_shift_alternative.ts — On the minimal subproblem
// (`solve_shift_subproblem_capture_59`), the two-line equivalent
// of shift is:
//
//   MOVE A: steal 3S from [AS 2S 3S], absorb onto [4H 5S]
//           → graduates [3S 4H 5S]; spawns trouble [AS 2S]
//   MOVE B: peel  KS from [KS AD:1 2C 3D:1], absorb onto [AS 2S]
//           → graduates [KS AS 2S]
//
// Walk the BFS tree (with shift disabled) and log loudly whenever
// either move is admissible. We expect MOVE A early; the question
// is whether the chain reaches a state where MOVE B fires.

import { classifyBuckets, stateSig, type Buckets, type Lineage, type RawBuckets } from "../src/buckets.ts";
import { enumerateFocused, initialLineage } from "../src/enumerator.ts";
import { describe } from "../src/move.ts";
import { type Card, RANKS, SUITS } from "../src/rules/card.ts";

function p(label: string): Card {
  let s = label, deck = 0;
  if (s.endsWith("'")) { deck = 1; s = s.slice(0, -1); }
  return [RANKS.indexOf(s[0]!) + 1, SUITS.indexOf(s[1]!), deck] as const;
}
const P = (...ls: string[]) => ls.map(p);

const raw: RawBuckets = {
  helper: [
    P("3C", "4C'", "5C'"),
    P("AS", "2S", "3S"),
    P("3D", "4C", "5H", "6S", "7D'"),
    P("7S", "7D", "7C", "7H"),
    P("KH", "AC", "2H'"),
    P("KS", "AD'", "2C", "3D'"),
    P("TD", "JD", "QD", "KD"),
  ],
  trouble: [P("4H", "5S"), [p("AC'")], [p("AD")]],
  growing: [],
  complete: [],
};
const initial = classifyBuckets(raw);
const initialLin: Lineage = initialLineage(initial.trouble, initial.growing);

// Patterns to hunt for. Match against describe() output substrings.
const MOVE_A = "steal 3S from HELPER [AS 2S 3S]";
const MOVE_B = "peel KS from HELPER [KS AD:1 2C 3D:1]";

// BFS up to a generous depth. At each state expansion, scan the
// admissible moves for either pattern and log loudly when seen.

interface QState {
  buckets: Buckets;
  lineage: Lineage;
  depth: number;
  trail: string[];   // sequence of move strings to reach this state
}

const seen = new Set<string>();
const queue: QState[] = [{ buckets: initial, lineage: initialLin, depth: 0, trail: [] }];
seen.add(stateSig(initial, initialLin));

let visited = 0;
let aSeen = 0;
let bSeen = 0;
let aReachedFromInit = false;
const MAX_DEPTH = 8;
const MAX_VISITED = 100000;

while (queue.length > 0) {
  const s = queue.shift()!;
  visited++;
  if (visited >= MAX_VISITED) {
    console.log(`[abort] hit visit cap ${MAX_VISITED}`);
    break;
  }
  if (s.depth > MAX_DEPTH) continue;

  for (const [desc, next] of enumerateFocused(s)) {
    const line = describe(desc);
    const isA = line.includes(MOVE_A);
    const isB = line.includes(MOVE_B);

    if (isA) {
      aSeen++;
      if (s.depth === 0) aReachedFromInit = true;
      console.log(`\n>>> MOVE A SEEN <<<  (depth=${s.depth}, state #${visited})`);
      console.log(`    trail to here:`);
      for (let i = 0; i < s.trail.length; i++) console.log(`      ${i+1}. ${s.trail[i]}`);
      console.log(`    move: ${line}`);
    }
    if (isB) {
      bSeen++;
      console.log(`\n>>> MOVE B SEEN <<<  (depth=${s.depth}, state #${visited})`);
      console.log(`    trail to here:`);
      for (let i = 0; i < s.trail.length; i++) console.log(`      ${i+1}. ${s.trail[i]}`);
      console.log(`    move: ${line}`);
    }

    const sig = stateSig(next.buckets, next.lineage);
    if (seen.has(sig)) continue;
    seen.add(sig);
    queue.push({
      buckets: next.buckets,
      lineage: next.lineage,
      depth: s.depth + 1,
      trail: [...s.trail, line],
    });
  }
}

console.log(`\n\n=== Summary ===`);
console.log(`states visited:    ${visited}`);
console.log(`unique states:     ${seen.size}`);
console.log(`MOVE A admissions: ${aSeen}  (from initial state: ${aReachedFromInit})`);
console.log(`MOVE B admissions: ${bSeen}`);
console.log(`max depth reached: ${MAX_DEPTH}`);
