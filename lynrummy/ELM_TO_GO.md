# ELM ↔ GO structural audit

**As-of:** 2026-04-15
**Confidence:** Working — snapshot audit plus action plan; findings accurate at capture, plan items in flight.
**Durability:** Revisit as audit items are resolved; re-audit when either side refactors.

**Purpose:** Elm (`~/showell_repos/elm-lynrummy/src/LynRummy/`) and Go
(`./lynrummy/`) share responsibilities. Steve's constraint: keep
structure as parallel as possible so cross-language work stays cheap
over time. This document is the audit + action plan.

**Scope:** domain model only. Language-idiomatic divergence (e.g.
Go error returns vs Elm `Result`) is accepted. Structural divergence
(module boundaries, naming, responsibility allocation) is what this
document tracks.

---

## Current state

### Elm modules (what they own)

| Module | Lines | Owns |
|---|---|---|
| `Card.elm` | 602 | Card type, Suit, CardColor, value/suit conversions, JSON encoder/decoder |
| `CardStack.elm` | 602 | Location, BoardCard, HandCard, CardStack, merge operations, shorthand parser, encoders/decoders |
| `StackType.elm` | 258 | StackType enum, classification from a card list |
| `BoardGeometry.elm` | 362 | BoardBounds, GeometryError, overlap + bounds checks, encoders |
| `Referee.elm` | 592 | Move, RefereeError, stage checks (protocol/geometry/semantics/inventory), encoders |
| `Random.elm` | 243 | Mulberry32 PRNG for byte-equivalent cross-language seeded shuffles |

### Go files (current)

| File | Lines | Owns |
|---|---|---|
| `lynrummy.go` | 581 | **Everything** — Card, Suit, CardColor, StackType, Location, BoardCard, CardStack, BoardBounds, geometry checks, protocol/semantics/inventory checks, Move, RefereeError, Validate* |
| `dealer.go` | 185 | Initial deal (shuffle, build starting board, hand split) — uses `math/rand.Shuffle` |
| `wire.go` | 282 | All wire types + encoders/decoders in one place |

---

## Structural mismatches

### 1. `lynrummy.go` is monolithic

Elm has 5 domain modules; Go collapses them into one file. This is
the biggest divergence. A reader who knows Elm looking at Go has to
scroll through one file to find Card vs CardStack vs Referee code.

**Action:** split `lynrummy.go` by Elm module boundaries:
- `card.go` — Card, Suit, CardColor, conversions (mirrors `Card.elm`)
- `stack_type.go` — StackType + classification (mirrors `StackType.elm`)
- `card_stack.go` — Location, BoardCard, CardStack, merge (mirrors `CardStack.elm`). **Adds HandCard, state enums, LeftMerge/RightMerge, FromHandCard** — foundational work already identified for tricks port.
- `board_geometry.go` — BoardBounds, geometry checks (mirrors `BoardGeometry.elm`)
- `referee.go` — Move, RefereeError, stage checks, Validate* (mirrors `Referee.elm`)

No line should stay in `lynrummy.go`. Delete the file after the split.

### 2. Wire format organization

Elm puts encoders/decoders **inside each domain module**
(`Card.encode`, `Card.decoder` live in `Card.elm`). Go keeps them
in a separate `wire.go` with `Wire*` type prefixes and conversion
functions like `wireCardToCard`.

Two valid shapes — but they differ. **Recommendation: match Elm.**
Move wire encoders/decoders into the per-domain Go files as
`MarshalJSON` / `UnmarshalJSON` methods (or dedicated `cardFromJSON`
helpers) on the domain types. Delete `wire.go` after migration.

**Counterpoint (worth surfacing):** Go's `encoding/json` is
mechanical enough that a separate `wire.go` feels natural — JSON in
Go is less entangled with domain code than Elm's encoders/decoders
are. Steve should decide whether this structural match is worth the
idiom-break. Flag this for discussion before acting.

### 3. `dealer.go` has no Elm counterpart (yet)

Go `dealer.go` handles: shuffle, build initial 6-stack board, split
remaining into two 15-card hands, emit `WireGameSetup`. Elm has
`Random.elm` (PRNG only), nothing equivalent to `Dealer.elm`.

**Action:** flag as a **future Elm module** — `Dealer.elm` needs to
exist to mirror. Port direction: Go → Elm (opposite of the rest).
Not blocking the current audit; add to Elm to-do list.

### 4. Go has no `Random.go` (Mulberry32)

Elm has deterministic Mulberry32 for byte-equivalent cross-language
tests; Go uses non-deterministic `math/rand.Shuffle`. This means Go
cannot participate in byte-equivalent PRNG fixtures with Elm (or TS).

**Action:** add `random.go` with Mulberry32 matching the Elm API.
Conformance fixtures that depend on specific deal outputs will need
this. Can be scoped in when shared-fixture work hits a PRNG case.

### 5. Naming conventions

Mostly aligned. Small items:
- Elm `HandCard` has no Go counterpart yet → add as `HandCard`
  (same name, same shape).
- Elm `BoardCardState` / `HandCardState` → Go currently uses raw
  `int` with a comment. Introduce named constants (`type
  BoardCardState int` + `iota`) to match Elm's explicit enum.
- Elm's `StackType` is a custom type (`Set`, `PureRun`, etc.). Go's
  is `type StackType string` with string constants. This is a
  deliberate Go idiom choice; keep as-is (cheap debuggability),
  but note in the code that Elm uses a sum type.

### 6. Constructors

- Elm uses type constructors directly (no factory functions).
- Go uses `NewCardStack` pattern consistently. Matches Go idiom.
- Tricks port will add `FromHandCard` method on `CardStack` — keep
  the name consistent with Elm's `fromHandCard`.

---

## Proposed work order

1. **Split `lynrummy.go`** into per-module files following Elm
   boundaries. No behavior change; pure reorg. Tests must stay
   green at every step.
2. **Add `HandCard` + state enums** to `card_stack.go` (closes the
   foundational gap for the tricks port).
3. **Add `LeftMerge` / `RightMerge` / `FromHandCard`** methods to
   `CardStack`.
4. **Discuss `wire.go` migration** (item #2 above) before acting.
5. **Defer:** `Dealer.elm` (item #3), `random.go` Mulberry32 (item
   #4) — not blocking tricks port.

Steps 1–3 clear the foundational blocker for the tricks port and
bring Go structure into parity with Elm. Wire format (step 4) and
the deferred items get separate sign-off.

---

## Open questions

- **Wire format:** inline into domain files (match Elm), or keep
  `wire.go` (match Go idiom)? [Blocking step 4]
- **Dealer in Elm:** who ports `Dealer.go` → `Dealer.elm`, and when?
  [Not blocking today]
- **Mulberry32 in Go:** needed only if we want byte-equivalent seeded
  deals across all three languages. Do we? [Not blocking today]
