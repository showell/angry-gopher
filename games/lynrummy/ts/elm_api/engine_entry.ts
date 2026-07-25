// engine_entry.ts — browser-bundle entry point for the TS engine.
// Re-exports the Elm-facing surface for esbuild → IIFE bundling.
//
// The surface is small on purpose: the thinking (hints, futility
// certificates, Player Two) lives in the zig solver (solver.wasm),
// and this bundle is its DSL/geometry layer. The glue
// (elm/engine_glue.js) drives the round trip: build the wasm
// agentStep input from the request's board/hand DSL, call the wasm,
// then lift the returned build recipe into the primitives DSL — ""
// when the agent is stuck (the turn's end signal).

import { zigAgentInput, zigPlanPrimitives } from "./zig_agent.ts";

export function elmZigAgentInput(boardDsl: string, handDsl: string): string {
  return zigAgentInput(boardDsl, handDsl);
}

export function elmZigPlanPrimitives(
  boardDsl: string,
  handDsl: string,
  planText: string,
): string {
  return zigPlanPrimitives(boardDsl, handDsl, planText);
}
