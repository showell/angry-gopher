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
  ["K♠ K♣' K♦", "set"], // catalog deck-2 markers parse and are ignored
  ["A♠ A♠' A♦", "dup"], // ...including for the dup rule, as in the game
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

// ── wing semantics (port of WingOracle + WingView hit-test) ─────────

{
  // Dragging K♦ near K♠ K♥: both sides of the pair make a legal set,
  // so it grows both wings; the 5♣ 6♣ pair offers neither.
  const board = t.parseBoard("at (100,50): K♠ K♥\nat (300,50): 5♣ 6♣\nat (200,200): K♦");
  const wings = t.wingsForStack(board, 2);
  assert.deepStrictEqual(
    wings.map((w) => w.target + ":" + w.side),
    ["0:left", "0:right"]
  );

  // 7♣ dragged near 5♣ 6♣: only the right side continues the run.
  const wings7 = t.wingsForStack(t.parseBoard("at (300,50): 5♣ 6♣\nat (200,200): 7♣"), 1);
  assert.deepStrictEqual(wings7.map((w) => w.target + ":" + w.side), ["0:right"]);

  // Hover hit-test: the right wing's landing is flush against the
  // target's right edge (100 + 64 = 164, top 50). Within half a
  // pitch → hovered; a card-width away → not.
  const rightWing = wings.find((w) => w.side === "right");
  assert.deepStrictEqual(t.eventualLanding(board, rightWing, 31), { left: 164, top: 50 });
  assert.strictEqual(t.hoveredWing(board, wings, { left: 170, top: 55 }, 31), rightWing);
  assert.strictEqual(t.hoveredWing(board, wings, { left: 195, top: 55 }, 31), null);

  // The left wing's landing backs off by the source width.
  const leftWing = wings.find((w) => w.side === "left");
  assert.deepStrictEqual(t.eventualLanding(board, leftWing, 31), { left: 69, top: 50 });
}

// ── click-split and isolate (port of CardStack.split / .isolate) ────

{
  // The clicked card joins the smaller chunk: first-half click ends
  // the left piece, second-half click starts the right piece.
  assert.strictEqual(t.clickToLeftCount(0, 2), 1);
  assert.strictEqual(t.clickToLeftCount(1, 2), 1);
  assert.strictEqual(t.clickToLeftCount(0, 5), 1);
  assert.strictEqual(t.clickToLeftCount(2, 5), 2);
  assert.strictEqual(t.clickToLeftCount(4, 5), 4);

  // Split geometry: pieces separate ±2px; the smaller chunk pops up
  // 4px (the left one here: 1 card vs 3).
  const run = t.parseBoard("at (100,50): 5♥ 6♥ 7♥ 8♥")[0];
  const [l, r] = t.splitStack(run, 1);
  assert.deepStrictEqual(
    { left: l.left, top: l.top, n: l.cards.length },
    { left: 98, top: 46, n: 1 }
  );
  assert.deepStrictEqual(
    { left: r.left, top: r.top, n: r.cards.length },
    { left: 135, top: 50, n: 3 }
  );

  // Isolate a middle card: three pieces, singleton keeps its exact
  // screen position (left + index*pitch), sides slide 2px out.
  const iso = t.isolateStack(run, 2);
  assert.strictEqual(iso.pieces.length, 3);
  assert.strictEqual(iso.singletonIndex, 1);
  const [before, single, after] = iso.pieces;
  assert.deepStrictEqual(
    { left: single.left, top: single.top, card: single.cards[0].value },
    { left: 166, top: 50, card: 7 }
  );
  assert.strictEqual(before.left, 98);
  assert.strictEqual(after.left, 201);

  // Isolate an end card: the empty side piece is omitted.
  const isoEnd = t.isolateStack(run, 0);
  assert.strictEqual(isoEnd.pieces.length, 2);
  assert.strictEqual(isoEnd.singletonIndex, 0);
}

// ── 2. tutorial.html boards ─────────────────────────────────────────

const html = fs.readFileSync(path.join(__dirname, "tutorial.html"), "utf8");
// Each board is a figure/widget div (optionally carrying a
// data-table="WxH" size override) wrapping its lr-dsl pre.
const boards = [...html.matchAll(
  /<div class="lr-(figure|widget)"(?: data-table="([^"]*)")?>[\s\S]*?<pre class="lr-dsl">([\s\S]*?)<\/pre>/g
)].map((m) => ({ kind: m[1], dims: t.parseTableDims(m[2]), text: m[3] }));
assert.ok(boards.length > 0, "tutorial.html has no lr-dsl boards");
assert.strictEqual(
  boards.length,
  [...html.matchAll(/<pre class="lr-dsl">/g)].length,
  "an lr-dsl board escaped the figure/widget extraction"
);

let stackCount = 0;
let figureCount = 0;
for (const b of boards) {
  const stacks = t.parseBoard(b.text);
  t.assertOnTable(stacks, b.dims);
  stackCount += stacks.length;
  if (b.kind !== "figure") continue;
  figureCount += 1;
  for (const s of stacks) {
    const got = t.getStackType(s.cards);
    assert.ok(
      ["set", "pure_run", "rb_run"].includes(got),
      "figure stack is not a legal meld: " + JSON.stringify(s.cards) + " → " + got
    );
  }
}

console.log(
  "tutorial gate: rules cases pass; " +
    boards.length + " boards (" + stackCount + " stacks) parse and fit their tables; " +
    figureCount + " figures hold only legal melds."
);
