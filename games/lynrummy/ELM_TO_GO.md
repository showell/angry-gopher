# ELM ↔ GO structural parity

**As-of:** 2026-04-15
**Confidence:** Firm — audit complete and primary actions landed; remaining items deferred with clear rationale.
**Durability:** Revisit when adding a new domain module on either side.

**Purpose:** Elm (`~/showell_repos/elm-lynrummy/src/LynRummy/`) and Go (`./lynrummy/`) share domain responsibilities. Steve's constraint: keep structure parallel so cross-language work stays cheap over time.

## Parity achieved (2026-04-14)

`lynrummy.go` was monolithic (581 lines); now split to mirror Elm modules:

| Elm | Go |
|---|---|
| `Card.elm` | `card.go` |
| `StackType.elm` | `stack_type.go` |
| `CardStack.elm` | `card_stack.go` (now includes HandCard, state enums, LeftMerge/RightMerge/FromHandCard) |
| `BoardGeometry.elm` | `board_geometry.go` |
| `Referee.elm` | `referee.go` |
| `Random.elm` | *(deferred — see below)* |
| *(no counterpart)* | `dealer.go` |

`wire.go` was deleted; JSON encoders/decoders now live on the domain types via struct tags + custom `MarshalJSON` on `CardStack`. Matches Elm's "encoders live with the type" convention.

## Drift monitor

`tools/parity_check.py` reports exported-name drift between Go and Elm twin modules. `tools/parity_ignore.py` holds known-deliberate divergences (populate as you go).

Known drift today (not rolled into `parity_ignore.py` yet):
- Go `Str` method vs Elm `cardStr` / `stackStr` free functions
- `buildFullDoubleDeck` lives in `Card.elm` but in Go's `dealer.go`

## Deferred (not blocking)

- **`Dealer.elm`** — Go has `dealer.go`, Elm has no counterpart. Port direction is Go → Elm (opposite of the rest). Only needed when Elm wants to deal its own games server-free.
- **Mulberry32 in Go (`random.go`)** — Elm has deterministic Mulberry32 for byte-equivalent seeded deals across languages; Go uses `math/rand.Shuffle`. Needed only if we want conformance fixtures with shared PRNG. Add when a real fixture demands it.

## StackType idiom divergence (kept on purpose)

Elm uses a custom sum type (`Set`, `PureRun`, etc.). Go uses `type StackType string` with string constants. Kept intentionally — the Go form is cheap to debug. Not drift, just idiom.
