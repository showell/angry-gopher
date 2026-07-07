// check_tutorial.js — the /tutorial authoring gate, run by
// ops/test_tutorial (composed into ops/check_lynrummy). Two layers:
//
//   1. Unit cases pinning the rules port (getStackType) against the
//      Elm/TS semantics: wraps, dups, descending, mixed patterns.
//   2. Every board authored in tutorial.html must parse, fit the
//      square table, and — for figures — hold only legal melds. This
//      is what keeps a typo'd example from quietly shipping as bogus.
//
// Exits nonzero with the offending stack on any failure.
"use strict";

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const t = require(path.join(__dirname, "tutorial.js"));

// ── 1. rules-port unit cases ────────────────────────────────────────

const P = (s) => t.parseBoard("at (0,0): " + s)[0].cards;

const CASES = [
  ["A♠ A♥ A♦", "set"],
  ["7♣ 7♦ 7♥ 7♠", "set"],
  ["5♣ 6♣ 7♣", "pure_run"],
  ["9♥ T♠ J♦", "rb_run"],
  ["Q♠ K♠ A♠", "pure_run"], // K -> A wrap
  ["K♠ A♠ 2♠", "pure_run"], // wrap through the ace
  ["J♠ Q♠ K♠ A♠ 2♠", "pure_run"],
  ["Q♦ K♣ A♥ 2♠ 3♦", "rb_run"],
  ["A♠ K♠ Q♠", "bogus"], // descending is not a run
  ["A♠ A♠ A♦", "dup"],
  ["A♠ A♥", "incomplete"],
  ["A♠", "incomplete"],
  ["5♣ 6♣ 7♥", "bogus"], // mixed pattern
  ["5♣ 6♣ 7♦", "bogus"], // suit changes mid-pure-run
];

for (const [s, want] of CASES) {
  assert.strictEqual(t.getStackType(P(s)), want, s);
}

assert.ok(!t.isCleanBoard(t.parseBoard("at (0,0): A♠ A♥")));
assert.ok(t.isCleanBoard(t.parseBoard("at (0,0): K♠ K♥ K♦\nat (0,60): 5♣ 6♣ 7♣")));

// ── 2. tutorial.html boards ─────────────────────────────────────────

const html = fs.readFileSync(path.join(__dirname, "tutorial.html"), "utf8");
const blocks = [...html.matchAll(/<pre class="lr-dsl">([\s\S]*?)<\/pre>/g)].map((m) => m[1]);
assert.ok(blocks.length > 0, "tutorial.html has no lr-dsl boards");

const figureBlocks = [...html.matchAll(/<div class="lr-figure">\s*<pre class="lr-dsl">([\s\S]*?)<\/pre>/g)].map((m) => m[1]);

let stackCount = 0;
for (const b of blocks) {
  const stacks = t.parseBoard(b);
  t.assertOnTable(stacks);
  stackCount += stacks.length;
}

for (const b of figureBlocks) {
  for (const s of t.parseBoard(b)) {
    const got = t.getStackType(s.cards);
    assert.ok(
      ["set", "pure_run", "rb_run"].includes(got),
      "figure stack is not a legal meld: " + JSON.stringify(s.cards) + " → " + got
    );
  }
}

console.log(
  "tutorial gate: rules cases pass; " +
    blocks.length + " boards (" + stackCount + " stacks) parse and fit the table; " +
    figureBlocks.length + " figures hold only legal melds."
);
