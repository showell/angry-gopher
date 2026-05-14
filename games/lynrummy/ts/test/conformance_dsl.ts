// conformance_dsl.ts — TS-side parser for the conformance DSL,
// producing the same Scenario shape that test_engine_conformance
// previously consumed from fixtures.json.
//
// Each .dsl scenario looks like:
//
//   scenario NAME
//     desc: TEXT
//     op: solve|enumerate_moves|find_open_loc|hint_for_hand
//     helper:
//       at (top,left): card1 card2 ...
//     trouble:
//       at (top,left): cards
//     hand: card1 card2 ...
//     card_count: N
//     existing:
//       at (top,left): cards
//     board:
//       - card1 card2 ...        # hint_for_hand shorthand (no loc)
//       OR
//       at (top,left): cards     # everything else
//     expect: scalar             # solve shorthand: `expect: no_plan`
//       OR
//     expect:
//       no_plan: true
//       plan_lines:
//         - "..."
//       plan_length: N
//       yields: text
//       narrate_contains: text
//       hint_contains: text
//       loc: (top,left)
//     expect_steps:
//       - "..."
//
// This parser covers the TS-routed op subset only. Elm-only
// blocks (replay actions, walkthrough steps, wing expects,
// etc.) are not handled.

import { type Card, parseCardLabel } from "../core/card.ts";

// ---- Output shape (matches the snake_case JSON Scenario in test_engine_conformance.ts) ----

interface ParsedCard {
  value: number;
  suit: number;
  origin_deck: number;
}

interface ParsedBoardCard {
  card: ParsedCard;
  state: number;
}

interface ParsedStack {
  board_cards: ParsedBoardCard[];
  loc: { top: number; left: number };
}

interface ParsedHandCard {
  card: ParsedCard;
  state: number;
}

interface ParsedScenario {
  name: string;
  desc: string;
  op: string;
  trick?: string;
  hand: ParsedHandCard[];
  board: ParsedStack[];
  helper?: ParsedStack[];
  trouble?: ParsedStack[];
  growing?: ParsedStack[];
  complete?: ParsedStack[];
  existing?: ParsedStack[];
  card_count?: number;
  hint_hand?: string[];
  hint_board?: string[][];
  hint_steps?: string[];
  expect: Record<string, unknown>;
}

// ---- Tokenizer line ----

interface Line {
  raw: string;
  content: string;   // trimmed, comments stripped
  indent: number;    // leading spaces in raw
  lineNum: number;   // 1-based
}

function toLines(src: string): Line[] {
  const out: Line[] = [];
  const splits = src.split("\n");
  for (let i = 0; i < splits.length; i++) {
    const raw = splits[i]!;
    // Strip `#` comments outside of strings (DSL is simple enough that
    // any `#` not in a quoted string is a comment).
    const hashIdx = raw.indexOf("#");
    const stripped = hashIdx >= 0 ? raw.slice(0, hashIdx).trimEnd() : raw.trimEnd();
    const content = stripped.trim();
    if (content === "") continue;
    let indent = 0;
    while (indent < raw.length && raw[indent] === " ") indent++;
    out.push({ raw, content, indent, lineNum: i + 1 });
  }
  return out;
}

// ---- Top-level parser ----

export function parseConformanceDsl(src: string): ParsedScenario[] {
  const lines = toLines(src);
  const scenarios: ParsedScenario[] = [];

  let i = 0;
  while (i < lines.length) {
    const line = lines[i]!;
    if (line.indent === 0 && line.content.startsWith("scenario ")) {
      const name = line.content.slice("scenario ".length).trim();
      // Body = subsequent indent > 0 lines, up to next column-0 line.
      const start = i + 1;
      let end = start;
      while (end < lines.length && lines[end]!.indent > 0) end++;
      scenarios.push(parseScenarioBody(name, lines.slice(start, end)));
      i = end;
    } else if (line.indent === 0) {
      // Column-0 noise (shouldn't happen in well-formed DSL).
      i++;
    } else {
      // Top-level continuation lines outside any scenario — skip.
      i++;
    }
  }
  return scenarios;
}

function parseScenarioBody(name: string, body: Line[]): ParsedScenario {
  const sc: ParsedScenario = {
    name,
    desc: "",
    op: "",
    hand: [],
    board: [],
    expect: {},
  };

  // Body is a mix of scalar fields (`key: value`) and block fields
  // (`key:` followed by indented children). Group into top-level
  // entries by indent.
  if (body.length === 0) return sc;
  const baseIndent = body[0]!.indent;

  let i = 0;
  while (i < body.length) {
    const line = body[i]!;
    if (line.indent !== baseIndent) {
      throw new Error(`scenario ${name}: unexpected indent on line ${line.lineNum}: ${line.raw}`);
    }
    const colon = line.content.indexOf(":");
    if (colon < 0) {
      throw new Error(`scenario ${name}: expected 'key: ...' on line ${line.lineNum}: ${line.raw}`);
    }
    const key = line.content.slice(0, colon).trim();
    const rest = line.content.slice(colon + 1).trim();

    // Children: subsequent lines with indent > baseIndent.
    const childStart = i + 1;
    let childEnd = childStart;
    while (childEnd < body.length && body[childEnd]!.indent > baseIndent) childEnd++;
    const children = body.slice(childStart, childEnd);

    if (rest === "") {
      applyBlockField(sc, key, children);
    } else {
      if (children.length > 0) {
        throw new Error(`scenario ${name}: field "${key}" has both inline value and children`);
      }
      applyScalarField(sc, key, rest);
    }
    i = childEnd;
  }
  return sc;
}

// ---- Scalar field dispatch ----

function applyScalarField(sc: ParsedScenario, key: string, val: string): void {
  switch (key) {
    case "desc":
      sc.desc = val;
      return;
    case "op":
      sc.op = val;
      return;
    case "trick":
      sc.trick = val;
      return;
    case "card_count":
      sc.card_count = parseInt(val, 10);
      return;
    case "hand": {
      const cards = parseCardList(val);
      sc.hand = cards.map(toHandCard);
      // hint_for_hand reads `hint_hand` (label strings); keep it
      // populated whenever `hand` is, so consumers can find it
      // regardless of op.
      sc.hint_hand = cards.map(cardLabelString);
      return;
    }
    case "hint_hand":
      sc.hint_hand = parseCardList(val).map(cardLabelString);
      return;
    case "expect":
      // Shorthand: `expect: no_plan` or other simple kinds.
      sc.expect = parseScalarExpect(val);
      return;
    default:
      throw new Error(`unknown scalar field "${key}: ${val}"`);
  }
}

// ---- Block field dispatch ----

function applyBlockField(sc: ParsedScenario, key: string, children: Line[]): void {
  switch (key) {
    case "helper":
      if (children.length > 0) sc.helper = parseStacks(children);
      return;
    case "trouble":
      if (children.length > 0) sc.trouble = parseStacks(children);
      return;
    case "growing":
      if (children.length > 0) sc.growing = parseStacks(children);
      return;
    case "complete":
      if (children.length > 0) sc.complete = parseStacks(children);
      return;
    case "existing":
      if (children.length > 0) sc.existing = parseStacks(children);
      return;
    case "board": {
      // hint_for_hand shorthand: "- cards" rows (no loc).
      if (children.length > 0 && children[0]!.content.startsWith("- ")) {
        sc.hint_board = parseDashLines(children).map(s =>
          s.split(/\s+/).filter(Boolean),
        );
      } else {
        sc.board = parseStacks(children);
      }
      return;
    }
    case "expect_steps": {
      // Only set when non-empty (matches the historical omitempty shape).
      const steps = parseDashLines(children);
      if (steps.length > 0) sc.hint_steps = steps;
      return;
    }
    case "expect":
      sc.expect = parseExpectBlock(children);
      return;
    default:
      throw new Error(`unknown block field "${key}:"`);
  }
}

// ---- Stack and card parsing ----

function parseStacks(children: Line[]): ParsedStack[] {
  return children.map(parseStackLine);
}

function parseStackLine(line: Line): ParsedStack {
  // "at (top,left): card1 card2 ..."
  if (!line.content.startsWith("at ")) {
    throw new Error(`expected "at (t,l): cards" at line ${line.lineNum}: ${line.raw}`);
  }
  const rest = line.content.slice("at ".length);
  const close = rest.indexOf(")");
  if (!rest.startsWith("(") || close < 0) {
    throw new Error(`bad location at line ${line.lineNum}: ${line.raw}`);
  }
  const [topStr, leftStr] = rest.slice(1, close).split(",").map(s => s.trim());
  const top = parseInt(topStr!, 10);
  const left = parseInt(leftStr!, 10);
  const tail = rest.slice(close + 1).trim();
  if (!tail.startsWith(":")) {
    throw new Error(`expected ":" after location at line ${line.lineNum}: ${line.raw}`);
  }
  const cards = parseCardList(tail.slice(1).trim());
  return {
    board_cards: cards.map(toBoardCard),
    loc: { top, left },
  };
}

function parseCardList(s: string): Card[] {
  if (s.trim() === "") return [];
  return s.trim().split(/\s+/).filter(Boolean).map(parseCardLabel);
}

function toBoardCard(c: Card): ParsedBoardCard {
  return {
    card: { value: c.rank, suit: c.suit, origin_deck: c.deck },
    state: 0,
  };
}

function toHandCard(c: Card): ParsedHandCard {
  return {
    card: { value: c.rank, suit: c.suit, origin_deck: c.deck },
    state: 0,
  };
}

function cardLabelString(c: Card): string {
  const RANKS = "A23456789TJQK";
  const SUITS = "CDSH";
  const base = RANKS[c.rank - 1]! + SUITS[c.suit]!;
  return c.deck === 0 ? base : `${base}'`;
}

function parseDashLines(children: Line[]): string[] {
  return children.map(line => {
    if (!line.content.startsWith("- ")) {
      throw new Error(`expected "- ..." at line ${line.lineNum}: ${line.raw}`);
    }
    let rest = line.content.slice(2).trim();
    // Strip surrounding quotes if present.
    if (rest.startsWith('"') && rest.endsWith('"')) {
      rest = rest.slice(1, -1);
    }
    return rest;
  });
}

// ---- Expect dispatch ----

function parseScalarExpect(val: string): Record<string, unknown> {
  // `expect: no_plan` shorthand.
  if (val === "no_plan") return { no_plan: true };
  // Other scalars: caller can extend; for now, treat as `kind` tag.
  return { kind: val };
}

function parseExpectBlock(children: Line[]): Record<string, unknown> {
  if (children.length === 0) return {};
  const baseIndent = children[0]!.indent;
  const out: Record<string, unknown> = {};

  let i = 0;
  while (i < children.length) {
    const line = children[i]!;
    if (line.indent !== baseIndent) {
      throw new Error(`expect: unexpected indent at line ${line.lineNum}: ${line.raw}`);
    }
    const colon = line.content.indexOf(":");
    if (colon < 0) {
      throw new Error(`expect: expected "key: ..." at line ${line.lineNum}: ${line.raw}`);
    }
    const key = line.content.slice(0, colon).trim();
    const rest = line.content.slice(colon + 1).trim();

    // Capture children for this expect field.
    const subStart = i + 1;
    let subEnd = subStart;
    while (subEnd < children.length && children[subEnd]!.indent > baseIndent) subEnd++;
    const subChildren = children.slice(subStart, subEnd);

    if (rest === "" && subChildren.length > 0) {
      // Block: plan_lines is the main case.
      if (key === "plan_lines") {
        out["plan_lines"] = parseDashLines(subChildren);
      } else {
        throw new Error(`expect: unknown block field "${key}"`);
      }
    } else {
      // Scalar.
      applyExpectScalar(out, key, rest);
    }
    i = subEnd;
  }
  return out;
}

function applyExpectScalar(out: Record<string, unknown>, key: string, val: string): void {
  switch (key) {
    case "no_plan":
      out["no_plan"] = val === "true";
      return;
    case "plan_length":
      out["plan_length"] = parseInt(val, 10);
      return;
    case "yields":
      out["yields"] = val;
      return;
    case "narrate_contains":
      out["narrate_contains"] = val;
      return;
    case "hint_contains":
      out["hint_contains"] = val;
      return;
    case "loc": {
      // "(top,left)"
      const m = val.match(/^\((-?\d+)\s*,\s*(-?\d+)\)$/);
      if (!m) throw new Error(`expect.loc: bad syntax: ${val}`);
      out["loc"] = { top: parseInt(m[1]!, 10), left: parseInt(m[2]!, 10) };
      return;
    }
    case "kind":
      out["kind"] = val;
      return;
    default:
      throw new Error(`expect: unknown scalar field "${key}"`);
  }
}
