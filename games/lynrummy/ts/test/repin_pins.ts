// repin_pins.ts — one-shot helper. When REPIN=1 is set, test
// runners that pin primitive sequences can call `rewritePrimitives`
// to overwrite the `- ...` lines inside a scenario's `primitives:`
// block with freshly-emitted ones.
//
// Not part of normal test runs. Lives here so the helpers used
// during the canonical-DSL convergence aren't scattered across
// individual runner files.

import * as fs from "node:fs";

export const REPIN = process.env.REPIN === "1";

/** In the .dsl file at `path`, find the scenario named `scenarioName`
 *  and replace the `- <line>` items inside the next `primitives:`
 *  block with the supplied lines. Preserves indentation and any
 *  intervening comments. */
export function rewritePrimitives(
  path: string,
  scenarioName: string,
  newPrimitives: readonly string[],
): void {
  const src = fs.readFileSync(path, "utf8");
  const lines = src.split("\n");

  const startIdx = findScenarioStart(lines, scenarioName);
  if (startIdx < 0) {
    throw new Error(`repin: scenario "${scenarioName}" not found in ${path}`);
  }
  const primsIdx = findPrimitivesHeader(lines, startIdx);
  if (primsIdx < 0) {
    throw new Error(
      `repin: no primitives: block for scenario "${scenarioName}" in ${path}`,
    );
  }
  const indent = leadingSpaces(lines[primsIdx]!) + 2; // "  - " under "primitives:"
  const [blockStart, blockEnd] = findDashBlock(lines, primsIdx + 1);
  const rendered = newPrimitives.map(p => " ".repeat(indent) + "- " + p);

  const updated = [
    ...lines.slice(0, blockStart),
    ...rendered,
    ...lines.slice(blockEnd),
  ];
  fs.writeFileSync(path, updated.join("\n"));
}

function findScenarioStart(lines: readonly string[], name: string): number {
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === `scenario ${name}`) return i;
  }
  return -1;
}

function findPrimitivesHeader(lines: readonly string[], from: number): number {
  for (let i = from + 1; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.length > 0 && !line.startsWith(" ") && !line.startsWith("\t")) {
      return -1; // exited the scenario before finding primitives:
    }
    if (line.trim() === "primitives:") return i;
  }
  return -1;
}

function findDashBlock(lines: readonly string[], from: number): [number, number] {
  let start = -1;
  let end = -1;
  for (let i = from; i < lines.length; i++) {
    const trimmed = lines[i]!.trim();
    if (trimmed.startsWith("- ")) {
      if (start < 0) start = i;
      end = i + 1;
    } else if (trimmed === "") {
      // tolerate blank lines inside the block
      if (start >= 0) end = i + 1;
    } else {
      break;
    }
  }
  if (start < 0) return [from, from]; // empty block — insert at top
  return [start, end];
}

function leadingSpaces(line: string): number {
  let n = 0;
  while (n < line.length && line[n] === " ") n++;
  return n;
}
