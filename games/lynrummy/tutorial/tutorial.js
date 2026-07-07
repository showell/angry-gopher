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

// ── Wings ───────────────────────────────────────────────────────────
// Ported from Lib/Physics/WingOracle.elm + Lib/WingView.elm: while a
// stack is dragged, every other stack that could legally accept it
// grows a "wing" on the accepting side — a drop zone one card-pitch
// wide. A merge is offered iff the concatenated cards aren't Bogus or
// Dup (Incomplete is fine: partial builds are mid-turn currency).

function isProblematic(cards) {
  const t = getStackType(cards);
  return t === "bogus" || t === "dup";
}

// side "left" means the source attaches to the LEFT of the target
// (merged order source ++ target); "right" is the mirror.
function wingsForStack(stacks, srcIdx) {
  const src = stacks[srcIdx].cards;
  const wings = [];
  stacks.forEach((s, i) => {
    if (i === srcIdx) return;
    if (!isProblematic(src.concat(s.cards))) wings.push({ target: i, side: "left" });
    if (!isProblematic(s.cards.concat(src))) wings.push({ target: i, side: "right" });
  });
  return wings;
}

const CARD_PITCH = 33;

// The visual wing rect: one pitch wide, card-high, flush against the
// target's accepting edge.
function wingRect(stacks, wing) {
  const t = stacks[wing.target];
  const left = wing.side === "left" ? t.left - CARD_PITCH : t.left + stackWidth(t);
  return { left, top: t.top, width: CARD_PITCH, height: CARD_H };
}

// Where the floater's top-left will LAND if this wing's merge fires.
// The hover hit-test checks closeness to this point, not overlap with
// the visual rect — tighter and more accurate (WingOracle's
// eventualFloaterTopLeft).
function eventualLanding(stacks, wing, sourceWidth) {
  const t = stacks[wing.target];
  const left = wing.side === "left" ? t.left - sourceWidth : t.left + stackWidth(t);
  return { left, top: t.top };
}

// Half a card-pitch of slop per axis (WingView.wingSnapTolerance).
const WING_SNAP = Math.floor(CARD_PITCH / 2);

function hoveredWing(stacks, wings, floaterLoc, sourceWidth) {
  return (
    wings.find((w) => {
      const ev = eventualLanding(stacks, w, sourceWidth);
      return Math.abs(floaterLoc.left - ev.left) < WING_SNAP && Math.abs(floaterLoc.top - ev.top) < WING_SNAP;
    }) || null
  );
}

// WingView's color constants: pastel green for "mergeable here",
// mauve when the floater is in the landing area.
const WING_GREEN = "hsl(105, 72.70%, 87.10%)";
const WING_MAUVE = "#E0B0FF";

// ── Click-split and long-press isolate ──────────────────────────────
// Ported from Lib/CardStack.elm (split / isolate geometry) and
// Lib/BoardGesture.elm (click arbitration). A click splits the stack
// at the pressed card; a 400ms hold isolates the pressed card and
// hands it straight to the drag.

const CLICK_THRESHOLD_SQ = 9; // GestureArbitration.clickThreshold (squared px)
const LONG_PRESS_MS = 400; // LongPress.holdMs

function distSquared(ax, ay, bx, by) {
  return (ax - bx) * (ax - bx) + (ay - by) * (ay - by);
}

// "User clicked card at cardIndex" → the logical leftCount of the
// split: the clicked card joins whichever chunk is smaller.
function clickToLeftCount(cardIndex, stackSize) {
  return cardIndex + 1 <= Math.floor(stackSize / 2) ? cardIndex + 1 : cardIndex;
}

// Split after the first leftCount cards. The pieces separate by 2px
// each way and the smaller chunk pops up 4px — enough daylight to
// read as two stacks. Caller guarantees 0 < leftCount < size (which
// clickToLeftCount produces for any size ≥ 2).
function splitStack(s, leftCount) {
  const rightCount = s.cards.length - leftCount;
  const leftUp = leftCount < rightCount ? -4 : 0;
  const rightUp = leftCount < rightCount ? 0 : -4;
  return [
    { left: s.left - 2, top: s.top + leftUp, cards: s.cards.slice(0, leftCount) },
    { left: s.left + leftCount * CARD_PITCH + 2, top: s.top + rightUp, cards: s.cards.slice(leftCount) },
  ];
}

// Isolate the card at cardIndex: up to three pieces (before slides
// 2px left, after 2px right, the singleton keeps its exact screen
// position). Returns the singleton's index within pieces so the
// caller can keep dragging it.
function isolateStack(s, cardIndex) {
  const before = s.cards.slice(0, cardIndex);
  const after = s.cards.slice(cardIndex + 1);
  const singleton = {
    left: s.left + cardIndex * CARD_PITCH,
    top: s.top,
    cards: [s.cards[cardIndex]],
  };
  const pieces = [];
  if (before.length) pieces.push({ left: s.left - 2, top: s.top, cards: before });
  const singletonIndex = pieces.length;
  pieces.push(singleton);
  if (after.length) pieces.push({ left: singleton.left + CARD_PITCH + 2, top: s.top, cards: after });
  return { pieces, singletonIndex };
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

function stackEl(stack) {
  const el = document.createElement("div");
  Object.assign(el.style, {
    position: "absolute",
    left: stack.left + "px",
    top: stack.top + "px",
    userSelect: "none",
    whiteSpace: "nowrap",
  });
  stack.cards.forEach((card, i) => {
    const c = cardEl(card);
    if (i > 0) c.style.marginLeft = "2px";
    el.appendChild(c);
  });
  return el;
}

// Every kitchen table on the page — figure or widget — is the same
// perfect square, compact enough for small screens (a 360px viewport
// minus the page padding).
const TABLE_SIDE = 320;

function tableEl() {
  const el = document.createElement("div");
  Object.assign(el.style, {
    position: "relative",
    width: TABLE_SIDE + "px",
    height: TABLE_SIDE + "px",
    backgroundColor: "khaki",
    border: "1px solid #b0a14e",
    borderRadius: "10px",
    touchAction: "none",
  });
  return el;
}

// Authoring guard: a stack laid outside the square is a tutorial bug —
// break the page loudly rather than render cards off the table.
function assertOnTable(stacks) {
  for (const s of stacks) {
    if (s.left < 0 || s.top < 0 || s.left + stackWidth(s) > TABLE_SIDE || s.top + STACK_H > TABLE_SIDE) {
      throw new Error("tutorial board: stack off the table at (" + s.left + "," + s.top + ")");
    }
  }
}

// Pixel width of a rendered stack: card box 31px (27 + 2 padding +
// 2 border) plus one pitch per additional card.
function stackWidth(stack) {
  return 31 + (stack.cards.length - 1) * CARD_PITCH;
}

const STACK_H = CARD_H + 6; // card box height incl. padding + border

// ── Figures ─────────────────────────────────────────────────────────
// A figure is one kitchen table with the example stacks laid on it at
// the DSL's (left, top) offsets. The slightly-off alignment between
// stacks is deliberate and hand-authored in the HTML — melds laid
// down by humans, not a grid. No interaction.

function hydrateFigure(root) {
  const stacks = parseBoard(readDsl(root));
  assertOnTable(stacks);
  const table = tableEl();
  for (const s of stacks) table.appendChild(stackEl(s));
  root.appendChild(table);
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
// A widget is a live kitchen table with the game's full board-card
// gesture set (ported from Lib/BoardGesture.elm):
//
//   press, move past the threshold  → drag the whole stack; wings
//                                     show legal landings, release on
//                                     a mauve wing to merge, on felt
//                                     to move
//   click (release without moving)  → split the stack at the clicked
//                                     card
//   hold 400ms (without moving)     → isolate the pressed card and
//                                     keep dragging it, no re-grab
//
// Undo and Reset walk the state back. Solved = every stack is a
// legal meld. All gesture state lives inside hydrateWidget's closure
// and the pointer listeners hang off this widget's own table element
// (which also holds the pointer capture — it survives the mid-gesture
// re-render that isolate needs), so any number of widgets coexist on
// one page.

const PROMPT = "Drag each loose card onto the stack where it belongs.";
const SOLVED = "✔ Solved! Every stack is a legal meld.";
const ISOLATED = "Isolated — drag to move.";

function hydrateWidget(root) {
  const initial = parseBoard(readDsl(root));
  assertOnTable(initial);

  let stacks = cloneStacks(initial);
  const history = [];

  const board = tableEl();

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

  let stackEls = [];

  function render(statusOverride) {
    board.replaceChildren();
    stackEls = stacks.map((stack, idx) => {
      const el = stackEl(stack);
      Array.from(el.children).forEach((cardNode, cardIndex) => {
        cardNode.addEventListener("pointerdown", (e) => onCardPointerDown(e, idx, cardIndex));
      });
      board.appendChild(el);
      return el;
    });
    const solved = isCleanBoard(stacks);
    status.textContent = solved ? SOLVED : statusOverride || PROMPT;
    status.style.color = solved ? "#1b5e20" : "#333";
    status.style.fontWeight = solved ? "600" : "normal";
    undoBtn.disabled = history.length === 0;
    resetBtn.disabled = history.length === 0;
  }

  // ── the gesture machine ──
  // One gesture at a time per widget. Phase "press" is the quiet
  // window after pointerdown: a 400ms hold isolates, escaping the
  // click threshold upgrades to phase "drag", releasing in place
  // clicks (= splits). The pointer listeners live on this widget's
  // table and stay registered; `gesture` gates them.
  let gesture = null;

  board.addEventListener("pointermove", onPointerMove);
  board.addEventListener("pointerup", onPointerUp);
  board.addEventListener("pointercancel", onPointerCancel);

  function onCardPointerDown(e, idx, cardIndex) {
    if (gesture) return;
    e.preventDefault();
    // Capture on the table, not the card: isolate re-renders the
    // stacks mid-gesture, and capture on a removed element is
    // silently released.
    board.setPointerCapture(e.pointerId);
    gesture = {
      phase: "press",
      idx,
      cardIndex,
      pointerId: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      timer: setTimeout(onLongPress, LONG_PRESS_MS),
      drag: null,
    };
  }

  // Upgrade the gesture to a whole-stack drag of stacks[idx]. Wings
  // are computed once here and pinned (the board doesn't change
  // mid-drag). Also the re-entry point after an isolate: the same
  // press continues as a drag of the fresh singleton.
  function beginDrag(idx) {
    const stack = stacks[idx];
    const el = stackEls[idx];
    el.style.zIndex = "10";
    const wings = wingsForStack(stacks, idx);
    const wingEls = wings.map((w) => {
      const r = wingRect(stacks, w);
      const wel = document.createElement("div");
      Object.assign(wel.style, {
        position: "absolute",
        left: r.left + "px",
        top: r.top + "px",
        width: r.width + "px",
        height: r.height + "px",
        backgroundColor: WING_GREEN,
        boxSizing: "border-box",
        border: "1px solid transparent",
      });
      board.appendChild(wel);
      return wel;
    });
    gesture.phase = "drag";
    gesture.idx = idx;
    gesture.drag = {
      el,
      wings,
      wingEls,
      hovered: null,
      origLeft: stack.left,
      origTop: stack.top,
      srcWidth: stackWidth(stack),
    };
  }

  function onPointerMove(ev) {
    if (!gesture || ev.pointerId !== gesture.pointerId) return;
    if (gesture.phase === "press") {
      if (distSquared(ev.clientX, ev.clientY, gesture.startX, gesture.startY) <= CLICK_THRESHOLD_SQ) {
        return; // still inside the quiet window
      }
      clearTimeout(gesture.timer);
      beginDrag(gesture.idx);
    }
    const d = gesture.drag;
    const p = floaterLocOf(gesture, ev);
    d.el.style.left = p.left + "px";
    d.el.style.top = p.top + "px";
    d.hovered = hoveredWing(stacks, d.wings, p, d.srcWidth);
    d.wings.forEach((w, i) => {
      d.wingEls[i].style.backgroundColor = w === d.hovered ? WING_MAUVE : WING_GREEN;
    });
  }

  function onLongPress() {
    if (!gesture || gesture.phase !== "press") return;
    const { idx, cardIndex } = gesture;
    const s = stacks[idx];
    if (s.cards.length > 1) {
      history.push(cloneStacks(stacks));
      const { pieces, singletonIndex } = isolateStack(s, cardIndex);
      stacks.splice(idx, 1, ...pieces);
      render(ISOLATED);
      beginDrag(idx + singletonIndex);
    } else {
      // A held singleton has nothing to isolate from; it just
      // becomes a drag, same as escaping the threshold.
      beginDrag(idx);
    }
  }

  function onPointerUp(ev) {
    if (!gesture || ev.pointerId !== gesture.pointerId) return;
    const g = endGesture();
    // Click check at RELEASE, not just escape: a drag that wanders
    // and returns to its origin is a click too (BoardGesture.
    // resolveBoardCardGesture).
    if (distSquared(ev.clientX, ev.clientY, g.startX, g.startY) <= CLICK_THRESHOLD_SQ) {
      applySplit(g.idx, g.cardIndex);
      return;
    }
    if (!g.drag) {
      // A flick can reach pointerup past the threshold with no move
      // event in between. Elm upgrades the press at release
      // (upgradePressToBoardDrag) and resolves normally — including
      // a merge if the flick landed in a landing area.
      const stack = stacks[g.idx];
      g.drag = {
        origLeft: stack.left,
        origTop: stack.top,
        srcWidth: stackWidth(stack),
        hovered: null,
      };
      g.drag.hovered = hoveredWing(stacks, wingsForStack(stacks, g.idx), floaterLocOf(g, ev), g.drag.srcWidth);
    }
    if (g.drag.hovered) {
      applyMerge(g.idx, g.drag.hovered);
    } else {
      applyMove(g.idx, floaterLocOf(g, ev));
    }
  }

  function floaterLocOf(g, ev) {
    return {
      left: g.drag.origLeft + (ev.clientX - g.startX),
      top: g.drag.origTop + (ev.clientY - g.startY),
    };
  }

  function onPointerCancel(ev) {
    if (!gesture || ev.pointerId !== gesture.pointerId) return;
    endGesture();
    render(); // snap back
  }

  // Tear down the in-flight gesture (timer, wings, capture) and hand
  // back its final state for the pointerup resolver.
  function endGesture() {
    const g = gesture;
    gesture = null;
    clearTimeout(g.timer);
    if (g.drag) for (const wel of g.drag.wingEls) wel.remove();
    try {
      board.releasePointerCapture(g.pointerId);
    } catch (err) {}
    return g;
  }

  // applySplit: the click verb. Splitting a singleton is a no-op
  // (nothing to split — not even a history entry).
  function applySplit(idx, cardIndex) {
    const s = stacks[idx];
    if (s.cards.length <= 1) {
      render();
      return;
    }
    history.push(cloneStacks(stacks));
    stacks.splice(idx, 1, ...splitStack(s, clickToLeftCount(cardIndex, s.cards.length)));
    render();
  }

  // applyMerge fires the hovered wing: merged order per the wing's
  // side, position anchored by the target (a left merge extends
  // leftward by the source's card count — CardStack.leftMerge). The
  // one tutorial divergence: the merged loc is clamped onto the
  // table, whose 320px square is far tighter than the game's board.
  function applyMerge(idx, wing) {
    const dragged = stacks[idx];
    const t = stacks[wing.target];
    history.push(cloneStacks(stacks));
    if (wing.side === "left") {
      t.cards = dragged.cards.concat(t.cards);
      t.left -= CARD_PITCH * dragged.cards.length;
    } else {
      t.cards = t.cards.concat(dragged.cards);
    }
    t.left = clamp(t.left, 0, TABLE_SIDE - stackWidth(t));
    stacks.splice(idx, 1);
    render();
  }

  // applyMove drops the stack on open felt (clamped onto the table).
  function applyMove(idx, dropLoc) {
    const dragged = stacks[idx];
    history.push(cloneStacks(stacks));
    dragged.left = clamp(dropLoc.left, 0, TABLE_SIDE - stackWidth(dragged));
    dragged.top = clamp(dropLoc.top, 0, TABLE_SIDE - STACK_H);
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
  module.exports = {
    parseBoard,
    getStackType,
    isCleanBoard,
    successor,
    assertOnTable,
    wingsForStack,
    hoveredWing,
    eventualLanding,
    clickToLeftCount,
    splitStack,
    isolateStack,
  };
}
