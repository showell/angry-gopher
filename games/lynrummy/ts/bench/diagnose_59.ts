// diagnose_59.ts — Run findPlay on capture #59 with shift disabled,
// instrument every projection's cap-exhaustion records.

import * as fs from "node:fs";
import { findPlay, type PlayStats } from "../src/hand_play.ts";

const XCHECK = "/home/steve/showell_repos/angry-gopher/games/lynrummy/python/captures/xcheck_full.jsonl";
const lines = fs.readFileSync(XCHECK, "utf8").split("\n").filter(l => l.trim());
const e = JSON.parse(lines[58]!);  // 0-indexed: capture #59 → index 58

const hand = e.hand.map((c: number[]) => [c[0], c[1], c[2]] as const);
const board = e.board.map((s: number[][]) => s.map((c: number[]) => [c[0], c[1], c[2]] as const));

const stats: PlayStats = { totalWallMs: 0, projections: [] };
const result = findPlay(hand, board, { stats, maxStates: 500000 });

console.log(`findPlay result: ${result === null ? "STUCK" : result.plan.length + "-step plan"}`);
console.log(`Total wall: ${stats.totalWallMs.toFixed(1)}ms`);
console.log(`Projections (${stats.projections.length}):`);

for (let i = 0; i < stats.projections.length; i++) {
  const p = stats.projections[i]!;
  const cards = p.cards.map(c => {
    const RANKS = "A23456789TJQK", SUITS = "CDHS";
    return RANKS[c[0]-1] + SUITS[c[1]] + (c[2] ? "'" : "");
  }).join(" ");
  console.log(`\n  [${i+1}] kind=${p.kind}  cards=[${cards}]  wall=${p.wallMs.toFixed(1)}ms  found=${p.foundPlan}`);
  if (p.exhaustions.length > 0) {
    console.log(`      exhaustions:`);
    for (const ex of p.exhaustions) {
      const tag = ex.hitMaxStates ? "HIT_MAX" : "natural";
      console.log(`        cap=${String(ex.cap).padStart(2)} expansions=${String(ex.expansions).padStart(6)} seen=${String(ex.seenCount).padStart(6)} ${tag}`);
    }
  }
}
