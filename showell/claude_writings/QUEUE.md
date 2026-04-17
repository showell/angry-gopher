# Writing queue

Articles agreed-on but not yet written. Append when a topic earns its place; prune when shipped.

| Topic | Source | Status |
|---|---|---|
| Plateau skills / free throws | Steve comment on `chunking_and_mode.md` ¶5 | **shipped** 2026-04-16 |
| Nanoseconds and Years | Steve comment on `chunking_and_mode.md` ¶10 | **shipped** 2026-04-16 |
| The Nanosecond End | Steve pushback on Nanoseconds and Years — arithmetic not feel, floor not spread | **shipped** 2026-04-16 |
| Human-Factor Arithmetic | Senior-junior gap reframe from The Nanosecond End — arithmetic on humans not cycles | **shipped** 2026-04-16 |
| Polynomials of Polynomials | Steve-requested tangent; ~3500 words on the `polynomial` repo as an exemplar of small-universe engineering | **shipped** 2026-04-16 |
| Concentration, Not Pressure | Steve comment on `plateau_skills.md` ¶13 — the real gap isn't pressure but attention drift; LynRummy mouse-slip as canonical example | **shipped** 2026-04-16 |
| Technical Debt | Steve comment on `human_factor_arithmetic.md` ¶11 — flagged as huge omission; likely doesn't fit the arithmetic frame, more like adversarial process | queued (wait for reading backlog to settle) |
| Chaos threshold | Steve comment on `human_factor_arithmetic.md` ¶6 — time horizon past which even senior estimates fail; seniors mitigate risk but can't predict | queued |
| A Cook-Levin in Miniature | Steve-requested tangent on `virtual-machine` repo; companion to Polynomials of Polynomials; walks the 4-opcode VM + polynomial stepper as a runnable Cook-Levin demo | **shipped** 2026-04-16 |
| Going Forward: Bridges in Angry Gopher | Steve comment on `polynomials_of_polynomials.md` ¶36 (anchor = cluster with ¶35 redundancy-as-asset); applies enumerate-and-bridge paradigm to Gopher's present + future; ends with 3 decisions for Steve | **shipped** 2026-04-16 |
| Memory Index Parity | Steve pick of decision #1 from `going_forward_bridges_in_gopher.md` — tactical piece on the cheapest first bridge; lived-through-today failure mode, 30-min Python checker, Python vs Go + hook-timing decisions | **shipped** 2026-04-16 |
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

## Working rule
Don't preempt the queue. Wait for explicit go-signal before starting a queued piece, so reading cadence stays in Steve's control.
