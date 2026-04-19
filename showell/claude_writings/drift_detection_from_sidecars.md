# Drift Detection from Sidecars — A Field Report

*2026-04-19. An exercise in diagnosing LynRummy Go↔Elm drift using only the `.claude` sidecars on both sides, per `project_drift_detection_via_sidecars.md`. Reading time ~10 min. Durability forecast: a few days as a live report; indefinite as a methodology write-up.*

---

## The ground rules I gave myself

No `.elm` files. No `.go` files. Nothing but sidecars. I enumerated 22 Go LynRummy sidecars and 19 Elm LynRummy sidecars (plus six `Main.*` sidecars on the Elm app side, which have no Go correspondents), then paired them by module correspondence and compared stated invariants, algorithms, and deliberate non-concerns. The output is a drift report with a confidence rating per finding, and — unavoidably — a sidecar-gap report, because half of what the exercise teaches you is which sidecars are holding their weight and which aren't.

## Sidecar-density asymmetry

Before any drift: the two sides are not at parity as artifacts. Go sidecars average ~24 lines; Elm sidecars average ~65. Today's work raised three Elm sidecars (`Game`, `Dealer`, `Hint`) well above 100 lines with full algorithm sketches, invariant tables, and deliberate-non-concerns sections — what the raised bar aims for. Their Go counterparts (`replay.claude` at 59 lines, `dealer.claude` at 14, `hint.claude` at 45) describe the same modules at a different register: more narrative, fewer exhaustive bullets. That's already a form of drift — not in behaviour, but in documentation density. A cross-language comparison against a shallow sidecar forces you to note the gap and move on, rather than diagnose through it.

## Candidate drifts I'd investigate

**1. The `Hand.resetState` stale claim on the Go side.** `games/lynrummy/hand.claude` says flatly:

> Elm has `resetState`; Go doesn't (no consumer yet — turn logic isn't modeled on Go side yet either).

This is almost certainly wrong now. The Go side has had full turn logic since bcaea72 (two-player + ceremony + hint rebuild, 2026-04-18), and `applyCompleteTurn` — per `replay.claude` — does "reset + draw cards, age board." The reset step almost certainly calls a `Hand.ResetState` method; the sidecar hasn't been updated since before turn logic landed. **Firm** drift: not in the code itself, but in the sidecar's account of the code. A read of `hand.go` would confirm in a line.

**2. The `wire_action.claude` "not wired into the server yet" claim.** The Go `wire_action.claude` says:

> Consumer: not wired into the server yet (no handler reads this). Next step: HTTP endpoint for player-action submission that decodes via `DecodeWireAction`, validates, persists.

This is demonstrably false — `views/lynrummy_elm.go` handles `/gopher/lynrummy-elm/actions` and decodes via `DecodeWireAction`. Same class of failure as the Hand one: the sidecar tells an accurate story about the past and a wrong story about the present. **Firm** sidecar drift.

**3. The `events.claude` reference to legacy UI.** `events.claude` still speaks of "the existing game-replay UI" and the `wire*` types that would go away "when the clean cut is complete." The clean cut landed 2026-04-18 (bcaea72 ripped the legacy game-lobby and `games/games.go`). The sidecar treats deprecated types as current, which will mislead future-Claude into thinking the old dispatch is still live. **Working** drift: not dangerous, but misdirectional.

**4. The `dealer` shuffle-divergence, acknowledged on Elm side only.** Elm `Dealer.claude` explicitly states:

> Elm ↔ Go parity note: the server shuffles with `math/rand`; Elm shuffles with Mulberry32 (`LynRummy.Random`). Same seed → different shuffles, which is fine because the modes are separate (offline: client seeds; online: client hydrates from server's `/state`).

Go `dealer.claude` does NOT mention this divergence at all. That's not a behavioural drift — both sides do what they say — but it's an **asymmetric claim**: the Elm sidecar warns readers; the Go sidecar doesn't. A future-Claude starting from the Go side might assume "same seed produces same deal across languages" and walk into a confusion. **Firm** asymmetric-documentation drift worth fixing with a one-line addition to `dealer.claude`.

**5. The hint `action` field split.** Go `tricks/hint.claude` describes the `Suggestion.action` field in detail (direct_play becomes `merge_hand`; everything else becomes `trick_result` with pre-diffed `stacks_to_remove` + `stacks_to_add` + `hand_cards_released`). Elm `Tricks/Hint.claude` says explicitly that the `action` field is *not* ported on the Elm side because the client applies plays locally via each trick module's `apply` function. Both sidecars name this as a deliberate shape choice — so: **known asymmetry, not drift**, but a consumer reading only one side's sidecar would miss that the wire field doesn't round-trip in the Elm client's mental model.

**6. The `turn_result` edge case documented on both sides differently.** Go `turn_result.claude`:

> TS's `declares_me_victor()` checks board cleanness at the moment hand became empty (mid-move). Go only sees the replay snapshot AT CompleteTurn time, so it treats every "hand-empty at CompleteTurn" as a potential victor … Differs from TS only in the edge case "emptied on dirty board, then tidied up."

Elm `PlayerTurn.claude` doesn't mention that edge case at all. Whether Elm's `turnResult` exhibits the same TS-vs-Go simplification is invisible from the sidecars — because Elm's `PlayerTurn` is accumulator-driven (tracks `empty_hand_bonus` / `victory_bonus` as mutable fields over the turn) while Go's is snapshot-driven (derives classification from end-of-turn state). Different data shapes, same nominal classifications — but the edge-case behaviour "emptied on dirty board, then tidied up" could land differently, and neither sidecar confirms they match. **Tentative** drift candidate; requires code read to resolve.

## The gaps the sidecars can't cover

- **Elm has no sidecar for `Card.elm`, `CardStack.elm`, `StackType.elm`, `Referee.elm`, or `BoardGeometry.elm`.** Go has a `.claude` for each corresponding module. Any drift in these — suit enumeration order, stack-type classification, referee two-stage check, geometry constants — would be invisible from the Elm side. I'd rank this as the single highest-leverage sidecar-gap cluster to close.
- **Elm has no sidecars for the seven individual tricks** (`DirectPlay`, `HandStacks`, `PairPeel`, `PeelForRun`, `RbSwap`, `SplitForSet`, `LooseCardPlay`). Go has a `.claude` per trick. The Go sidecars document quite specific invariants ("right-prefer so the play set is deterministic", "pure-run pair peels predecessor OR successor same-suit", "end peel on 4+ stack; set-peel of any middle card of a 4+ SET; middle-peel when both halves ≥ 3"). If the Elm tricks diverge from those — which they might, given each was ported independently — the sidecar layer can't catch it. **Seven unchecked drift surfaces.**
- **`tricks/direct_play.claude` says "right-prefer so the play set is deterministic."** If Elm's DirectPlay prefers left first, the play ORDER differs, which means `plays[0]` — the play the hint system surfaces as `rank=1` — could be a different play on each side for the same `(hand, board)`. The DSL conformance scenario I added today for direct_play would catch this if it exists, but the sidecar-only read can't confirm. **Working**-confidence drift candidate.
- **Old-style Go sidecars don't document consumer cardinality.** Go `tricks/pair_peel.claude` describes the three pair kinds (Set, Pure-run, Rb-run) and the algorithm ("sorts the trio by value before pushing"). Elm has no corresponding sidecar, so I can't confirm the sort happens client-side too, or whether the three pair kinds are enumerated in the same order (which would affect which Play comes out first).

## The one place where sidecars resolved drift cleanly

The hint-orchestration pair (Go `tricks/hint.claude` + Elm `Tricks/Hint.claude`) is the single place in this exercise where sidecar-only reading gave me complete diagnostic power. Both sides state the algorithm step-by-step, the priority order is identical (`direct_play`, `hand_stacks`, `pair_peel`, `split_for_set`, `peel_for_run`, `rb_swap`, `loose_card_play`), the `Suggestion` shape difference is explicitly named on both sides, and the design rationale points at the same essay (`hints_from_first_principles.md`). This is what the raised-bar sidecar reads like when it's working: a cross-language reader can flag "what about X?" and find it preemptively answered on both sides, or preemptively declared out of scope on both sides.

That the hint pair is the cleanest isn't an accident — it's the module I touched today under the raised bar. Which is a hypothesis worth naming: **the exercise currently grades my recent work rather than the codebase's health.** A week from now, if `Card`, `CardStack`, `Referee`, and `BoardGeometry` all have Elm sidecars at the new bar, a second run of this exercise should look very different.

## What this exercise actually demonstrated

Under the current sidecar state, a sidecar-only drift diagnosis produces:

- **Three firm-confidence drifts** — all of them sidecar-vs-reality, not cross-language. (Stale `hand.claude`, stale `wire_action.claude`, stale `events.claude`.) These are cheap to fix: re-read the companion code and update the sidecar.
- **Two asymmetric-claim drifts** — Elm sidecar warns about shuffle divergence, Go doesn't; Go sidecar notes the TS victor edge-case, Elm doesn't. One-line additions to the missing-side sidecars would make the cross-language read symmetric.
- **One known-asymmetric-by-design** — the hint `action` field split. Both sides document it; resolution is "not drift."
- **At least twelve unchecked surfaces** — Card, CardStack, StackType, Referee, BoardGeometry plus seven tricks on the Elm side lack sidecars. Any drift here is invisible to this method.

So: the method works where the sidecars exist at the new bar, is merely useful where they exist at the old bar, and is blind where they don't exist. Which is exactly what "stated shapes" theory predicts — the sidecars earn their keep in direct proportion to how explicitly they state the shape. The inverse quietly doesn't.

## One-paragraph takeaway

Sidecars can carry a drift-detection workload, but only up to the density threshold they're written at. The highest-leverage next move isn't another round of drift-hunting — it's writing the missing Elm sidecars (Card, CardStack, StackType, Referee, BoardGeometry, plus the seven tricks) at the new bar, and touching up the three stale Go sidecars so their accounts stop lying about the current code. Then repeat this exercise and see how much further it gets.

— C.
