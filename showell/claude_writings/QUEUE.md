# Writing queue

Articles agreed-on but not yet written. Append when a topic earns its place; prune when shipped.

| Topic | Source | Status |
|---|---|---|
| Load-Bearing | Steve asked for a short vocabulary piece unpacking the term; intended as a reorientation-to-process read; ~half the length of peer essays | **shipped** 2026-04-16 |
| Phase, Not Motion | Retrospective on the VM-simulator UI iteration — protagonist must be visible, vertical axis as time's arrow, proxy vs real constraints. Paired with 3 memory files | **shipped** 2026-04-17 |
| Writing the Sidecars | Retrospective on the sidecar-parity bridge exercise in virtual-machine-go — labels as commitments, cheap bridges ship, enumerate-and-bridge applied to documentation | **shipped** 2026-04-17 |
| The Dog as Opcode | Retrospective on the cow study V2 exercise — indirect manipulation as a design frame, pressure vs bump physics, recoil as physical-event cue, start-garish iteration. Prototype code ripped; essay carries the rewrite recipe | **shipped** 2026-04-17 |
| Two Directions | Follow-up to The Dog as Opcode. Pulls out the oscillation pattern Steve named in comments: adding complexity for framing, scaling back to study a single interaction, re-introducing complexity. Walks VM (1→4→1→4) and cows (3→2→3). Analogue to controlled-vs-ecological methodology in psychology. ~40% longer than usual per request | **shipped** 2026-04-17 |
| The Elm Study Rip | Brief status report on ripping the gesture-study layer from elm-port-docs. Calls out where recently-earned vocabulary (ebb and flow, clarifying-question discipline, asset-preservation checklist, TS-as-source-of-truth, display-vs-identity memory, rip methodology, consolidate knowledge) did real work. | **shipped** 2026-04-17 |
| Inventory of a Partial Port | First step of finishing the LynRummy TS → Elm port: enumerate what's already ported so the remainder is cleanly scoped. Includes the Elm index, the unported-by-role breakdown, scope proposal (knobs + MVP surface), and a meta-note proposing "Partial ports start with inventory" as a cheat-sheet addition. | **shipped** 2026-04-17 |
| The Opening Board | Status report after five modules ported; proposes "display the opening board" as the next checkpoint; outlines how Steve helps (look at rendered board, gut-react). | **shipped** 2026-04-17 |
| State-Flow Audit of game.ts | Pre-port audit of the 3046 LOC `game.ts`. Maps 14 module-level globals into domain/UI/meta layers, walks the action flow from user input to re-render, proposes 12-module Elm decomposition (~1400-1700 LOC) and porting order. Ends with 3 yes/no rulings for Steve. | **shipped** 2026-04-17 |
| Drag and Wings | Pivot essay. Plan for drag-drop + wings on the opening board as the next checkpoint, ahead of game.ts decomposition. Three parts (base physics / merge oracle / wings decoration); Model+Msg snippet; wings-oracle snippet; out-of-scope + risk flags. | **shipped** 2026-04-17 |
| The Port So Far | End-of-day status report covering the full LynRummy TS→Elm port work of 2026-04-17: five model-layer ports, opening-board checkpoint, shelved state-flow audit, drag-and-wings pivot with three-pass implementation, fidelity-per-component crystallization. Verbose, mildly reflective, no next-steps section. | **shipped** 2026-04-17 |
| Hand to Board | Forward plan for the next checkpoint: render player hands, allow hand-card drag to the board (merge via wing OR place as singleton). Three code snippets (DragSource extension, branched wing oracle, MouseUp with new branch). Notes on opponent rendering, board-relative coords, scope of each file change. | **shipped** 2026-04-17 |
| The Fast Day | Short end-of-day consolidation essay. What shipped in ~4 wall hours (from the go signal), what made it fast (pivot / per-component fidelity / sidecar-first / "just port it" / infrastructure reuse), what to do differently. Preserves signal from a day that moved quickly. | **shipped** 2026-04-17 |
| Serving from Gopher | Prep essay for the last task of the day: serve the Elm client through the Gopher UI. Two-part shape — Part 1 (get it working at all: new route, build-on-start, landing link) and Part 2 (real integration: flags, server round-trip, SSE, turn logic, go:embed deployment). Names what's out of scope for tonight. | **shipped** 2026-04-17 |
| Insights from First Few Days of Essay Workflow | Meta-reflection on the essay system, written before the pre-today rip. Covers what's working (comment→memory distillation, chain links, dated-sequence discipline, parking-to-repo), what's not (chain-level findings lost, rip criterion ad-hoc), per-essay insights from the 13 ripped pieces, and parking recommendations for three durable ones. | **shipped** 2026-04-17 |
| For the Next Session | Present-Claude to future-Claude recovery note. 90% practical (where state lives, what's safe to touch, git anchors) + 10% discretionary (what today felt like, the comment→memory discipline, ops/start is yours). Written as the last essay before signing off 2026-04-17. | **shipped** 2026-04-17 |

## Working rule
Don't preempt the queue. Wait for explicit go-signal before starting a queued piece, so reading cadence stays in Steve's control.

## Rip log
2026-04-17 — ripped the 2026-04-16 batch (13 essays) per the rolling-window durability rule. Three parked into repos as DEEP_READ / BRIDGES (polynomial, virtual-machine, angry-gopher). Insights compressed into `insights_from_first_few_days_of_essay_workflow.md`.
