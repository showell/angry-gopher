// tutorial.js — the whole /tutorial client. Self-contained plain JS,
// no build step, no engine. Hydrates the .lr-figure and .lr-widget
// nodes in tutorial.html: figures become static card renderings,
// widgets become small drag-to-meld boards.
//
// The rules logic is ported from Lib/Rules/StackType.elm (itself a
// port of the canonical TS stack_type.ts). The card visuals mirror
// Lib/StackView.elm so the tutorial's cards look like the game's.
"use strict";

// ── Card domain ─────────────────────────────────────────────────────
// A card is { value, suit }: value 1..13 (A=1 … K=13), suit one of
// "♠♥♦♣". No origin_deck — the tutorial never fields both copies of
// a card, and the dup check only compares (value, suit) anyway.

const RED_SUITS = "♥♦";

// Mirrors Elm: CardStack.cardWidth=27, BoardGeometry.cardHeight=40,
// pitch 33 (card box 31px + 2px gap).
const CARD_W = 27;
const CARD_H = 40;

function suitColor(suit) {
  return RED_SUITS.includes(suit) ? "red" : "black";
}

// Successor wraps King -> Ace, so K, A, 2 is a valid run.
function successor(v) {
  return v === 13 ? 1 : v + 1;
}

const VALUE_DISPLAY = ["", "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"];

const VALUE_FROM_LABEL = { A: 1, T: 10, 10: 10, J: 11, Q: 12, K: 13 };
for (let v = 2; v <= 9; v++) VALUE_FROM_LABEL[String(v)] = v;

// ── Board DSL ───────────────────────────────────────────────────────
// Same grammar the puzzle catalogs use, one stack per line:
//   at (100,90): K♠ K♥
// Parse failures throw: a bad board is a tutorial-authoring bug and
// should break the page loudly, not degrade it.

function parseBoard(text) {
  const stacks = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const m = line.match(/^at \((\d+)\s*,\s*(\d+)\):\s*(.+)$/);
    if (!m) throw new Error("tutorial board: bad line: " + line);
    const cards = m[3].trim().split(/\s+/).map(parseCard);
    stacks.push({ left: Number(m[1]), top: Number(m[2]), cards });
  }
  if (stacks.length === 0) throw new Error("tutorial board: empty");
  return stacks;
}

function parseCard(token) {
  const m = token.match(/^(10|[A2-9TJQK])([♠♥♦♣])$/);
  if (!m) throw new Error("tutorial board: bad card: " + token);
  return { value: VALUE_FROM_LABEL[m[1]], suit: m[2] };
}

// ── Stack classification ────────────────────────────────────────────
// Faithful port of getStackType — "THE MOST IMPORTANT FUNCTION OF THE
// GAME" per the Elm source. Card order matters: runs read ascending
// left to right.

function pairType(a, b) {
  if (a.value === b.value && a.suit === b.suit) return "dup";
  if (a.value === b.value) return "set";
  if (b.value === successor(a.value)) {
    if (a.suit === b.suit) return "pure_run";
    if (suitColor(a.suit) !== suitColor(b.suit)) return "rb_run";
    return "bogus";
  }
  return "bogus";
}

function hasDuplicateCards(cards) {
  for (let i = 0; i < cards.length; i++)
    for (let j = i + 1; j < cards.length; j++)
      if (cards[i].value === cards[j].value && cards[i].suit === cards[j].suit)
        return true;
  return false;
}

function getStackType(cards) {
  if (cards.length < 2) return "incomplete";
  const t = pairType(cards[0], cards[1]);
  if (t === "bogus" || t === "dup") return t;
  if (cards.length === 2) return "incomplete";
  if (t === "set" && hasDuplicateCards(cards)) return "dup";
  for (let i = 1; i + 1 < cards.length; i++)
    if (pairType(cards[i], cards[i + 1]) !== t) return "bogus";
  return t;
}

function isLegalMeld(cards) {
  const t = getStackType(cards);
  return t === "set" || t === "pure_run" || t === "rb_run";
}

function isCleanBoard(stacks) {
  return stacks.every((s) => isLegalMeld(s.cards));
}

// ── Rendering ───────────────────────────────────────────────────────
// Inline styles mirroring Lib/StackView.elm: white card, 1px blue
// border, value over suit glyph, red/black text.

function cardEl(card) {
  const el = document.createElement("div");
  Object.assign(el.style, {
    display: "inline-block",
    width: CARD_W + "px",
    height: CARD_H + "px",
    padding: "1px 1px 3px 1px",
    textAlign: "center",
    verticalAlign: "top",
    fontSize: "17px",
    // Pin the game renderer's implicit line-height: the document body
    // sets 1.55 for prose, which would push the suit glyph past the
    // card's bottom edge.
    lineHeight: "normal",
    color: suitColor(card.suit),
    backgroundColor: "white",
    border: "1px solid blue",
    userSelect: "none",
  });
  for (const s of [VALUE_DISPLAY[card.value], card.suit]) {
    const line = document.createElement("div");
    line.textContent = s;
    el.appendChild(line);
  }
  return el;
}

// The bare row of cards, unpositioned — figures center it on a
// kitchen table, widgets absolutely position it on the board.
function stackCardsEl(stack) {
  const el = document.createElement("div");
  el.style.userSelect = "none";
  el.style.whiteSpace = "nowrap";
  stack.cards.forEach((card, i) => {
    const c = cardEl(card);
    if (i > 0) c.style.marginLeft = "2px";
    el.appendChild(c);
  });
  return el;
}

function stackEl(stack) {
  const el = stackCardsEl(stack);
  Object.assign(el.style, {
    position: "absolute",
    left: stack.left + "px",
    top: stack.top + "px",
  });
  return el;
}

function boardEl(width, height) {
  const el = document.createElement("div");
  Object.assign(el.style, {
    position: "relative",
    width: width + "px",
    height: height + "px",
    backgroundColor: "khaki",
    touchAction: "none",
  });
  return el;
}

// Pixel width of a rendered stack: card box 31px (27 + 2 padding +
// 2 border) plus 33px pitch per additional card.
function stackWidth(stack) {
  return 31 + (stack.cards.length - 1) * 33;
}

const STACK_H = CARD_H + 6; // card box height incl. padding + border

// ── Figures ─────────────────────────────────────────────────────────
// A figure is a row of example stacks, each centered on its own small
// khaki square — a little kitchen table. No interaction. Figures
// ignore the DSL's (left, top): the table is the layout.

function hydrateFigure(root) {
  const stacks = parseBoard(readDsl(root));
  const row = document.createElement("div");
  Object.assign(row.style, {
    display: "flex",
    flexWrap: "wrap",
    gap: "16px",
    alignItems: "flex-start",
  });
  for (const s of stacks) row.appendChild(tableEl(s));
  root.appendChild(row);
}

function tableEl(stack) {
  const side = Math.max(stackWidth(stack) + 40, 100);
  const table = document.createElement("div");
  Object.assign(table.style, {
    width: side + "px",
    height: side + "px",
    backgroundColor: "khaki",
    border: "1px solid #b0a14e",
    borderRadius: "10px",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  });
  table.appendChild(stackCardsEl(stack));
  return table;
}

// readDsl pulls the board text out of the .lr-dsl <pre> and removes
// it — hydration consumes the fallback.
function readDsl(root) {
  const pre = root.querySelector(".lr-dsl");
  const text = pre.textContent;
  pre.remove();
  return text;
}

// ── Widgets ─────────────────────────────────────────────────────────
// A widget is a live board: grab a card to drag its whole stack;
// drop it on another stack to merge (left half prepends, right half
// appends); drop it on open felt to move it. Undo and Reset walk the
// state back. Solved = every stack is a legal meld.

const BOARD_W = 800;

const PROMPT = "Drag each loose card onto the stack where it belongs.";
const SOLVED = "✔ Solved! Every stack is a legal meld.";

function hydrateWidget(root) {
  const initial = parseBoard(readDsl(root));
  const boardH = Math.max(...initial.map((s) => s.top + STACK_H)) + 120;

  let stacks = cloneStacks(initial);
  const history = [];

  const board = boardEl(BOARD_W, boardH);
  board.style.border = "1px solid #999";

  const status = document.createElement("div");
  Object.assign(status.style, { marginTop: "8px", fontSize: "15px", minHeight: "22px" });

  const undoBtn = widgetButton("Undo");
  const resetBtn = widgetButton("Reset");
  const buttons = document.createElement("div");
  Object.assign(buttons.style, { marginTop: "6px", display: "flex", gap: "8px" });
  buttons.append(undoBtn, resetBtn);

  root.append(board, status, buttons);

  undoBtn.addEventListener("click", () => {
    if (history.length === 0) return;
    stacks = history.pop();
    render();
  });

  resetBtn.addEventListener("click", () => {
    stacks = cloneStacks(initial);
    history.length = 0;
    render();
  });

  function render() {
    board.replaceChildren();
    stacks.forEach((stack, idx) => {
      const el = stackEl(stack);
      el.addEventListener("pointerdown", (e) => startDrag(e, idx, el));
      board.appendChild(el);
    });
    const solved = isCleanBoard(stacks);
    status.textContent = solved ? SOLVED : PROMPT;
    status.style.color = solved ? "#1b5e20" : "#333";
    status.style.fontWeight = solved ? "600" : "normal";
    undoBtn.disabled = history.length === 0;
    resetBtn.disabled = history.length === 0;
  }

  function startDrag(e, idx, el) {
    e.preventDefault();
    const stack = stacks[idx];
    const startX = e.clientX;
    const startY = e.clientY;
    const origLeft = stack.left;
    const origTop = stack.top;
    el.style.zIndex = "10";
    el.setPointerCapture(e.pointerId);

    function place(ev) {
      return {
        left: origLeft + (ev.clientX - startX),
        top: origTop + (ev.clientY - startY),
      };
    }

    function onMove(ev) {
      const p = place(ev);
      el.style.left = p.left + "px";
      el.style.top = p.top + "px";
    }

    function onUp(ev) {
      cleanup();
      applyDrop(idx, place(ev));
    }

    function onCancel() {
      cleanup();
      render(); // snap back
    }

    function cleanup() {
      el.removeEventListener("pointermove", onMove);
      el.removeEventListener("pointerup", onUp);
      el.removeEventListener("pointercancel", onCancel);
    }

    el.addEventListener("pointermove", onMove);
    el.addEventListener("pointerup", onUp);
    el.addEventListener("pointercancel", onCancel);
  }

  // applyDrop resolves a released drag: merge into the most-overlapped
  // stack if any, else move to the drop spot (clamped onto the board).
  function applyDrop(idx, dropLoc) {
    const dragged = stacks[idx];
    const dropRect = {
      left: dropLoc.left,
      top: dropLoc.top,
      right: dropLoc.left + stackWidth(dragged),
      bottom: dropLoc.top + STACK_H,
    };

    let target = -1;
    let bestArea = 0;
    stacks.forEach((s, i) => {
      if (i === idx) return;
      const w = Math.min(dropRect.right, s.left + stackWidth(s)) - Math.max(dropRect.left, s.left);
      const h = Math.min(dropRect.bottom, s.top + STACK_H) - Math.max(dropRect.top, s.top);
      if (w > 0 && h > 0 && w * h > bestArea) {
        bestArea = w * h;
        target = i;
      }
    });

    history.push(cloneStacks(stacks));
    if (target >= 0) {
      // Left half of the target prepends, right half appends. The
      // full game offers wing previews; the tutorial keeps just the
      // side rule.
      const t = stacks[target];
      const dropCenter = (dropRect.left + dropRect.right) / 2;
      const targetCenter = t.left + stackWidth(t) / 2;
      t.cards = dropCenter < targetCenter ? dragged.cards.concat(t.cards) : t.cards.concat(dragged.cards);
      stacks.splice(idx, 1);
    } else {
      dragged.left = clamp(dropLoc.left, 0, BOARD_W - stackWidth(dragged));
      dragged.top = clamp(dropLoc.top, 0, boardH - STACK_H);
    }
    render();
  }

  render();
}

function widgetButton(label) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = label;
  Object.assign(b.style, {
    padding: "4px 12px",
    fontSize: "14px",
    cursor: "pointer",
  });
  return b;
}

function cloneStacks(stacks) {
  return stacks.map((s) => ({ left: s.left, top: s.top, cards: s.cards.slice() }));
}

function clamp(x, lo, hi) {
  return Math.min(Math.max(x, lo), hi);
}

// ── Boot ────────────────────────────────────────────────────────────

if (typeof document !== "undefined") {
  document.querySelectorAll(".lr-figure").forEach(hydrateFigure);
  document.querySelectorAll(".lr-widget").forEach(hydrateWidget);
}

// Node-visible exports so the pure logic can be smoke-tested without
// a browser.
if (typeof module !== "undefined") {
  module.exports = { parseBoard, getStackType, isCleanBoard, successor };
}
