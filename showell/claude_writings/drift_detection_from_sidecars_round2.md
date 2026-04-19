# Drift Detection from Sidecars — Round 2

*2026-04-19. Second pass of the sidecar-only drift audit, per `project_drift_detection_via_sidecars.md`. Reading time ~8 min. Durability forecast: days as a live report; reusable as a method calibration.*

---

## Framing

Round 1 predicted this exercise would look different once the missing Elm sidecars landed — and it does. The twelve-surface gap in Round 1 (Card, CardStack, StackType, Referee, BoardGeometry, plus seven tricks on the Elm side) is entirely closed: every module I went looking for on the Elm side has a sidecar at the new dense bar. The three stale Go sidecars from Round 1 (`hand.claude`, `wire_action.claude`, `events.claude`) are all refreshed — `hand.claude` now explicitly names the `bcaea72` turn-logic landing, `wire_action.claude` names the live `/gopher/lynrummy-elm/actions` consumer, and `events.claude` is freshly labeled `VESTIGIAL` with a scorched-earth cleanup note. This is good work and the method can now do what it couldn't before: actually compare dense sidecar against dense sidecar.

And once you can, new drift shows up.

## Contradictions

**1. Referee scope — Elm's sidecar misrepresents Go.** `LynRummy/Referee.claude` asserts "Go has a referee pass but the canonical copy of these rules now lives Elm-side … server does dirty-board check only, not full referee." But `games/lynrummy/referee.claude` describes a full four-stage referee (protocol / geometry / inventory / semantics) with `ValidateGameMove` + `ValidateTurnComplete`, and `games/lynrummy/board_geometry.claude` says "The referee calls checkGeometry to reject moves whose result would push a stack off-board or overlap another stack." Both sidecars can't be right. A future-Claude reading only Elm Referee will conclude the server trusts them, skip parity thinking on validation, and be surprised when a Go-side check rejects a move. **Firm** drift: Elm sidecar is stale / wrong about Go's scope, or Go sidecars are stale about an intended server-authority retreat. Either way, they disagree and one must update.

**2. BoardGeometry counterpart existence.** `LynRummy/BoardGeometry.claude` states: "No Go counterpart — Go side doesn't validate geometry (client authority)." But `games/lynrummy/board_geometry.claude` exists, is labeled `ELEGANT`, and explicitly says the Go referee calls `checkGeometry`. Same structural drift as #1, probably the same root cause — someone restated an aspirational client-authority future as a present fact on the Elm side. **Firm**.

**3. Apply-time re-validation in tricks.** `games/lynrummy/tricks/trick.claude` claims: "Go returns (newBoard, played) — simpler, avoids TS's defensive 're-check at apply time' rescan." But `games/lynrummy/tricks/pair_peel.claude` explicitly says "belt-and-braces GetStackType check (Bogus/Dup/Incomplete rejected)." And Elm `Tricks/Trick.claude` states the opposite of the Go claim: "Empty `cardsActuallyConsumed` means refusal … This preserves the invariant that tricks validate at apply time." So Go `trick.claude` tells a story its own children contradict, and tells it in opposition to Elm's sidecar. **Firm** sidecar drift within the Go trick layer; cross-language drift is secondary.

## Stale claims

**4. `WireAction.elm` "not wired up yet."** The Elm `WireAction.claude` (still labeled `WORKHORSE (wire-action-v2)`) says: "Consumer: will be `Main.elm` (outbound on player actions) and the Go server (inbound validation + persist). Neither wired up yet. Go counterpart: pending." This is Round 1 in reverse. The Go counterpart exists (well-documented in `games/lynrummy/wire_action.claude`), is consumed by `views/lynrummy_elm.go`, and Elm sidecars for Replay and Game both describe active use of WireAction decoding. **Firm**.

**5. WireAction constructor list inconsistency.** Elm `WireAction.claude` lists 9 constructors including `draw` and `discard`, and no `TrickResult`. Elm `Replay.claude` lists 9 branches and includes `TrickResult` and `PlayTrick` but not `draw` or `discard`. Go `wire_action.claude` lists 8 concrete types (including `TrickResultAction`, no draw/discard). Three sidecars, three different rosters. The most likely explanation is that WireAction.claude was written against an earlier design that has since been superseded — `discard` in particular is suspicious given no other sidecar mentions it. **Firm** sidecar drift; the wire contract itself probably has a single truth, but a future reader can't learn which from sidecars alone.

**6. `ELM_TO_GO.md` Dealer claim.** Not a sidecar, but adjacent and worth flagging: `games/lynrummy/ELM_TO_GO.md` (dated 2026-04-15) says "**`Dealer.elm`** — Go has `dealer.go`, Elm has no counterpart. Port direction is Go → Elm … Only needed when Elm wants to deal its own games server-free." As of today, `Dealer.elm` exists with a dense sidecar describing the seed-driven deal completed in the 2026-04-19 autonomy port. The parity-map doc has drifted past the Round 1 sidecar work. **Firm** doc drift.

## Asymmetries

**7. CardStack cache — still not cross-documented.** Elm `CardStack.claude` says `stackType` is derived on demand, explicitly calling out "no stored field." Go `card_stack.claude` says the opposite: "CardStack carries a cached StackType set by NewCardStack; MarshalJSON drops it and UnmarshalJSON re-derives it so stale caches can never ride the wire." This is a legitimate language-specific implementation choice, not a bug, but neither sidecar mentions the other's strategy. A future-Claude touching the shared JSON invariant could land a change on one side that the cache-aware side silently accepts with stale data. **Working** asymmetry: a one-line "Go caches; we don't" on Elm (and vice versa) would close the loop.

**8. PlayerTurn vs turn_result edge case — now explicitly named on Elm.** Elm `PlayerTurn.claude` now has a whole section titled "Cross-language drift note: the 'emptied on dirty board then tidied up' edge case" that accurately names Go's snapshot-based simplification and its own accumulator-based approach. Go `turn_result.claude` also names the simplification. Both sides acknowledge the divergence. Round 1 flagged this as a tentative drift candidate; Round 2 finds it has been promoted to a documented, mutually-acknowledged known-difference. **Resolved**.

## Sidecar gaps

**9. `Main.*` sidecars have no Go counterparts, which is fine, but some of Elm's `LynRummy.*` sidecars are now significantly fuller than their Go counterparts.** `dealer.claude` on Go is 42 lines; `Dealer.claude` on Elm is 110 lines with a full step-by-step deal algorithm, a divergence table, and a test roster. `trick.claude` on Go is 14 lines; `Trick.claude` on Elm is 57 lines with an explicit apply-time contract. For a future Claude coming in from the Go side, the sidecar-density asymmetry means "read the sister sidecar first" is often the right move — which is a methodology insight worth surfacing, not a bug.

## One-paragraph assessment

The sidecars are in dramatically better shape than they were two days ago. The Round 1 gap list (missing Elm sidecars) is fully closed, the Round 1 staleness list is fully fixed, and one previously-tentative drift (PlayerTurn edge case) has been promoted to documented known-difference on both sides. That's the good news. The new drift surface is concentrated in two places: the Referee/BoardGeometry claim about server authority (which seems to have been written aspirationally and is now factually wrong), and the WireAction sidecar on Elm which still reads like a pre-wiring first-draft. Both are fixable with a single editing pass each, and both matter — Referee because it lies to readers about where validation lives, WireAction because the constructor list itself is inconsistent with its own Replay sibling. If this exercise runs again in a week, I'd expect those two to be the drift candidates the next-Claude finds, plus the always-latent CardStack cache asymmetry. Overall: sidecars are now a trustworthy compression of the system where they've been raised to the new bar; the remaining holes are load-bearing but narrow.

— C.
