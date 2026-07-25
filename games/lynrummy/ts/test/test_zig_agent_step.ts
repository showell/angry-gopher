// test_zig_agent_step — Player Two end-to-end conformance. Runs
// `zig_agent_corpus.dsl` scenarios through the REAL solver.wasm
// (`agentStep`, the artifact the browser loads) and the TS lowering
// (`zigPlanPrimitives`), asserting string-equality on the rendered
// primitives — the DSL IS the contract, same posture as the other
// corpus runners.
//
// One invariant beyond the pins: a played recipe, applied primitive
// by primitive, must leave EVERY stack a complete meld — a zig play
// is a full cover by construction. (Hand-card consumption is the zig
// distiller's own loud invariant; it can't reach here broken.)
//
// Run via ops/check_solver, right after ops/build_lynrummy_wasm, so
// the wasm on disk can never be stale against the zig source.

import * as fs from "node:fs";
import * as path from "node:path";

import { zigAgentInput, zigPlanPrimitives, liftPlan } from "../elm_api/zig_agent.ts";
import { parseBoardDsl, parseCardList } from "../dsl/parse.ts";
import { applyLocally } from "../game_events/primitives.ts";
import type { BoardStack } from "../geometry/geometry.ts";
import { isCompleteGroup } from "../core/card_stack.ts";
import { cardLabel } from "../core/card.ts";
import { REPIN, rewritePrimitives } from "./repin_pins.ts";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const DSL_PATH = path.resolve(HERE, "../../conformance/scenarios/zig_agent_corpus.dsl");
const WASM_PATH = path.resolve(HERE, "../../zig/solver.wasm");

interface Scenario {
  readonly name: string;
  readonly desc: string;
  readonly boardDsl: string;
  readonly handDsl: string;
  readonly expectedPrimitives: readonly string[];
}

function parseDsl(text: string): Scenario[] {
  const lines = text.split("\n");
  const out: Scenario[] = [];
  let cur: {
    name?: string;
    desc?: string;
    boardLines?: string[];
    handDsl?: string;
    expectedPrimitives?: string[];
  } | null = null;
  let inBoard = false;
  let inPrims = false;

  function commit(): void {
    if (cur && cur.name !== undefined) {
      out.push({
        name: cur.name,
        desc: cur.desc ?? "",
        boardDsl: (cur.boardLines ?? []).join("\n"),
        handDsl: cur.handDsl ?? "",
        expectedPrimitives: cur.expectedPrimitives ?? [],
      });
    }
  }

  for (const raw of lines) {
    const stripped = raw.replace(/#.*$/, "").trimEnd();
    const trimmed = stripped.trim();

    const sc = trimmed.match(/^scenario\s+(\S+)$/);
    if (sc && raw.match(/^scenario\b/)) {
      commit();
      cur = { name: sc[1], boardLines: [], expectedPrimitives: [] };
      inBoard = inPrims = false;
      continue;
    }
    if (!cur) continue;

    if (trimmed === "board:") { inBoard = true; inPrims = false; continue; }
    if (trimmed === "expect:") { inBoard = false; continue; }
    if (trimmed === "primitives:") { inPrims = true; continue; }

    if (trimmed.startsWith("hand:")) {
      cur.handDsl = trimmed.slice("hand:".length).trim();
      inBoard = inPrims = false;
      continue;
    }
    if (trimmed.startsWith("desc:")) {
      cur.desc = trimmed.slice("desc:".length).trim();
      continue;
    }

    if (inBoard && trimmed.startsWith("at ")) {
      cur.boardLines!.push(trimmed);
      continue;
    }
    if (inPrims && trimmed.startsWith("- ")) {
      cur.expectedPrimitives!.push(trimmed.slice(2));
      continue;
    }
  }
  commit();
  return out;
}

// --- the wasm, loaded once (same ABI walk as engine_glue.js) ---------

interface SolverWasm {
  readonly memory: WebAssembly.Memory;
  ioPtr(): number;
  ioCap(): number;
  agentStep(len: number): number;
}

function loadWasm(): SolverWasm {
  const bytes = fs.readFileSync(WASM_PATH);
  const mod = new WebAssembly.Module(bytes);
  return new WebAssembly.Instance(mod).exports as unknown as SolverWasm;
}

function wasmAgentPlan(wasm: SolverWasm, input: string): string | null {
  const bytes = new TextEncoder().encode(input);
  if (bytes.length > wasm.ioCap()) throw new Error("input exceeds io buffer");
  new Uint8Array(wasm.memory.buffer, wasm.ioPtr(), bytes.length).set(bytes);
  const rc = wasm.agentStep(bytes.length);
  if (rc === 0) return null; // stuck
  if (rc < 0) throw new Error(`agentStep returned ${rc}`);
  return new TextDecoder().decode(
    new Uint8Array(wasm.memory.buffer, wasm.ioPtr(), rc));
}

// --- invariants -------------------------------------------------------

/** Re-lift the recipe at the primitive level and apply it; throw
 *  unless every resulting stack is a complete meld (a zig play is a
 *  full cover). */
function assertCoverApplied(sc: Scenario, plan: string): void {
  const board = parseBoardDsl(sc.boardDsl);
  let sim: readonly BoardStack[] = board;
  for (const p of liftPlan(board, parseCardList(sc.handDsl), plan)) {
    sim = applyLocally(sim, p);
  }
  for (const s of sim) {
    if (!isCompleteGroup(s.cards)) {
      throw new Error(
        `post-play stack is not a meld: [${s.cards.map(cardLabel).join(" ")}]`);
    }
  }
}

// --- runner -----------------------------------------------------------

interface RunResult { ok: boolean; msg: string }

function runScenario(wasm: SolverWasm, sc: Scenario): RunResult {
  let got: string;
  let plan: string | null;
  try {
    plan = wasmAgentPlan(wasm, zigAgentInput(sc.boardDsl, sc.handDsl));
    got = plan === null ? "" : zigPlanPrimitives(sc.boardDsl, sc.handDsl, plan);
  } catch (e) {
    return { ok: false, msg: `threw: ${(e as Error).message}` };
  }
  const gotLines = got === "" ? [] : got.split("\n");
  if (plan !== null) {
    try {
      assertCoverApplied(sc, plan);
    } catch (e) {
      return { ok: false, msg: `cover invariant: ${(e as Error).message}` };
    }
  }
  if (REPIN) {
    rewritePrimitives(DSL_PATH, sc.name, gotLines);
    return { ok: true, msg: `REPIN — wrote ${gotLines.length} primitive(s)` };
  }
  const want = sc.expectedPrimitives.join("\n");
  if (got !== want) {
    return {
      ok: false,
      msg: `primitives mismatch:\n  want:\n${indent(want)}\n  got:\n${indent(got)}`,
    };
  }
  const n = gotLines.length;
  return {
    ok: true,
    msg: n === 0 ? "OK — stuck, turn yielded" : `OK — ${n} primitive(s), cover verified`,
  };
}

function indent(s: string): string {
  return s.split("\n").map(l => `    ${l}`).join("\n");
}

function main(): void {
  if (!fs.existsSync(DSL_PATH)) {
    console.error(`missing DSL: ${DSL_PATH}`);
    process.exit(1);
  }
  if (!fs.existsSync(WASM_PATH)) {
    console.error(`missing wasm: ${WASM_PATH} — run ops/build_lynrummy_wasm`);
    process.exit(1);
  }
  const wasm = loadWasm();
  const scenarios = parseDsl(fs.readFileSync(DSL_PATH, "utf8"));

  let pass = 0, fail = 0;
  for (const sc of scenarios) {
    const r = runScenario(wasm, sc);
    const tag = r.ok ? "PASS" : "FAIL";
    console.log(`${tag}  ${sc.name.padEnd(40)} ${r.msg}`);
    if (r.ok) pass++; else fail++;
  }
  console.log(`\n${pass}/${pass + fail} zig_agent scenarios passed`);
  if (fail > 0) process.exit(1);
}

main();
