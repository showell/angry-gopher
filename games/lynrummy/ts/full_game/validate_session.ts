// validate_session.ts — read a session directory on disk
// (`meta` + `actions.dsl`), parse both via the production-side
// wire helpers, and replay every action through `applyLocally`.
//
// This is the "DSL through conformance" check: an agent-written
// session is rule-abiding iff every action it emitted parses
// cleanly AND applies cleanly AND leaves no geometry violation.
// Same `applyLocally + findViolation` pair the conformance
// walkthroughs use — single source of truth for rule semantics.
//
// Reports per-line which step failed, or "ok" with the
// action count. Throws nothing — returns a result struct.

import * as fs from "node:fs";
import * as path from "node:path";

import { type Primitive, applyLocally } from "../game_events/primitives.ts";
import type { BoardStack } from "../core/geometry.ts";
import { findViolation } from "../core/geometry.ts";
import { parseBoardFromMeta } from "./initial_state_dsl.ts";
import { parseWireActionLine } from "../game_events/parse_game_event.ts";


interface ValidationResult {
  readonly ok: boolean;
  readonly msg: string;
  readonly actionsApplied: number;
}


export function validateSession(sessionDir: string): ValidationResult {
  const metaPath = path.join(sessionDir, "meta");
  const actionsPath = path.join(sessionDir, "actions.dsl");

  if (!fs.existsSync(metaPath)) {
    return { ok: false, msg: `missing meta: ${metaPath}`, actionsApplied: 0 };
  }
  if (!fs.existsSync(actionsPath)) {
    return { ok: false, msg: `missing actions.dsl: ${actionsPath}`, actionsApplied: 0 };
  }

  let board: readonly BoardStack[];
  try {
    board = parseBoardFromMeta(fs.readFileSync(metaPath, "utf8"));
  } catch (e) {
    return { ok: false, msg: `meta parse: ${(e as Error).message}`, actionsApplied: 0 };
  }

  const lines = fs
    .readFileSync(actionsPath, "utf8")
    .split("\n")
    .map(l => l.trim())
    .filter(l => l !== "" && !l.startsWith("#"));

  let applied = 0;
  for (const line of lines) {
    let parsed: Primitive | { action: "complete_turn" };
    try {
      parsed = parseWireActionLine(line, board);
    } catch (e) {
      return {
        ok: false,
        msg: `parse failed at action ${applied + 1}: ${(e as Error).message} (line: ${line})`,
        actionsApplied: applied,
      };
    }
    if (parsed.action === "complete_turn") {
      // CompleteTurn doesn't touch the board (deck-draw is a
      // separate state mutation Elm handles locally). Just bump
      // the counter and move on; the geometric-validity gate is
      // satisfied trivially.
      applied++;
      continue;
    }
    try {
      board = applyLocally(board, parsed);
    } catch (e) {
      return {
        ok: false,
        msg: `applyLocally failed at action ${applied + 1}: ${(e as Error).message} (line: ${line})`,
        actionsApplied: applied,
      };
    }
    const violation = findViolation(board);
    if (violation !== null) {
      return {
        ok: false,
        msg: `geometry violation after action ${applied + 1} at stack ${violation} (line: ${line})`,
        actionsApplied: applied,
      };
    }
    applied++;
  }

  return { ok: true, msg: "", actionsApplied: applied };
}
