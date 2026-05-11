# BOUNDARIES — be mindful

> Code is mostly boundary decisions. Where does this type
> draw its line? Where does this function draw its
> signature? Where does this module draw its surface? Where
> do these two hosts draw their seam?
>
> The default failure mode at every boundary is **letting
> the wrong thing cross**. Either too much (fat parameters
> that couple consumers to fields they don't use, modules
> that share state they shouldn't), or too little (a return
> type so narrow it makes callers splice an invariant
> together themselves). Both look fine until they don't.
>
> This document is the one place that holds the questions to
> ask at every boundary, and the diagnostics that say which
> question is firing.

---

## How to use this document

Read it once, end to end, before substantive Elm / Go
refactor work. Then keep it open as a reference. The
sections aren't disjoint — most real boundary problems
trigger two or three of the diagnostics at once. The
worked examples at the bottom show the diagnostics
intersecting in real code.

This is **mandatory for top-level Claude** doing
refactor or new-code work. Sub-agents handed narrow
tasks (test writing, fixture generation, single-file
edits) can skip it; sub-agents handed structural moves
should read at least the diagnostic headings.

The document deliberately replaces the older patchwork of
cross-linked memory files. Where two old memories overlap,
the unified version states the right rule once, with the
calibration that holds them together.

---

## The fundamental question

At every boundary — type, function, module, host — ask:

> **What crosses, what stays, and is the post-crossing
> state consistent?**

That's the spine. Everything below is a diagnostic that
fires when the spine is violated.

---

## Diagnostic 1 — Does the shape match what's actually true?

The data shape of the system should match what's actually
true about reality at the point that data is used. Four
flavors of violation:

- **Wider than reality.** The type carries a possibility
  (`Nothing`, NULL, Maybe) that the local site has already
  ruled out. Symptom: defensive branches, "shouldn't happen
  by construction" comments, `WHERE col IS NOT NULL` filters
  scoped to "the rows of one kind."
- **Narrower than reality.** The producer-consumer boundary
  throws away information that actually existed. Symptom:
  inferred-back values where the producer already had them,
  lossy telemetry, compound forms consumers must decompose.
- **Inventing reality.** Vocabulary names a designed
  response as a recovery — and the words shape what code
  gets written. Symptom: "stuck-state recovery" for
  conditions the system already has primitives for.
- **Fragmented shape.** Reality permits two representations
  (positional vs content, integer vs float, ordered vs
  multiset) and we don't pick one. The two drift; bugs sit
  in the seam.

**Diagnostic phrases to treat as alarms:**

- "Shouldn't happen by construction."
- "This is fine because the catalog will have loaded by then."
- "Half these rows have it, half don't."
- "B can re-derive this from A's output."
- "Approximately equal" / "close enough."

**The fix is always the same fix:** change the shape. Not
the comment, not the inference layer, not the recovery
path. The shape.

**Calibration — honest exceptions:** Cross-language
boundaries are genuinely partial (JSON parsers return
`Maybe` — that's honesty, not breadth). Display-layer
compounds can compress for human ergonomics (a "your turn
ended" notification doesn't enumerate the seven primitives
behind it). Same-kind-rows-with-no-value are fine to NULL
when the discriminator is the row kind, not the NULL.

---

## Diagnostic 2 — Does this function take more than it uses, or less than it needs?

Two failure modes, opposite directions, same root cause.

### Too wide

When reaching for a fat parameter (`Model`, big info
record), stop and check what the body actually uses. If
it's ≤3 fields, narrow the signature. Don't take a fat
object "because it's available."

Why this matters: every consumer becomes a compile-time
consumer of every field on the fat object. Adding a field
anywhere on `Model` leaves every signature legal but
morally outdated. The cost is hidden until the next type
change, when signatures churn at every layer.

### Too narrow

When a function's return type forces callers to splice
the post-call state back together to restore an
invariant, the signature is too narrow. The smoking gun:
**every call site does the same post-call ritual**.

Today's prior art: `Execute.placeHand` returned
`{ board, hand }`. Every caller had to splice the new
hand into the active player's slot AND bump
`cardsPlayedThisTurn` AND splice the board. In the gap
between Execute returning and the splice completing,
**a card was in both the board and the hand**. The most
basic invariant — "a card is in exactly one place" —
broken.

The fix: take and return the structure that holds the
invariant whole. `Execute.placeHand : Card -> Loc ->
GameState -> GameState`. Now there's no intermediate
state to leak.

### The unifying rule

The signature should encode the **unit of consistency**.
Reads can fragment freely. Writes that span an invariant
cannot: the function must take and return the smallest
shape that holds the invariant.

### Decision sequence

1. **Invariant test.** Does the post-call state hold the
   domain invariant, or does it have a known-broken
   intermediate that the caller must fix? If broken,
   widen until the obligation disappears.
2. **Splice test.** Do all call sites do the same
   post-call splice? If yes, move the splice inside.
3. **Smallest-type test.** Now, with consistency held,
   what's the smallest input slice the body actually
   uses? Narrow to that.

The earlier rule "pass the smallest type" only applies
once the prior two tests are clean. Read-only helpers and
writes-to-a-single-coherent-slice are its natural domain.

### Calibration — leaf functions advertise narrower contracts

A function's invariant obligations are scoped to **the
contract it advertises**. Not every helper has to respect
every invariant of the system above it.

`Execute.mergeHand` advertises a `GameState -> GameState`
contract, so it MUST be atomic with respect to the
GameState invariant ("a card is in exactly one place").
But it delegates to `BoardActions.tryHandMerge` and
`Hand.setActiveHand`, which advertise board-only and
hand-only contracts. Each one of those, on its own, does
NOT respect the full GameState invariant — calling
`Hand.setActiveHand` without also patching `board` would
leave a card in two places. That's fine: those functions
provide board-specific or hand-specific services without
advertising a GameState-level contract.

The rule: respect the invariants of the level you're
advertising at, and pick the level honestly. The bug shape
is when a function advertises a wide contract but only
delivers half of it — that's the placeHand error.

### Tell — asymmetric dispatcher arms

If a dispatcher's `case-of` has one fat arm and several
thin ones, suspect (1) or (2) is failing on the fat arm.
`applyEvent`'s three thin board arms next to two fat hand
arms was the surface signal of the placeHand boundary
problem.

---

## Diagnostic 3 — Is this helper a real computation, or just shape?

A leaf function is worth extracting when it **computes
something** — runs an algorithm, hits a real
transformation, encodes domain logic.

A leaf function is NOT worth extracting when its entire
body is shape work:

- **Record-update helpers** (`{ big | field = ... }`). The
  wrapper adds nothing — the real work is the narrow
  computation that produced `field`.
- **Record-deconstruction helpers** (`case x of ... ->
  Just { ... }`). Just rearranging shapes the caller could
  have inspected directly.

Steve's framing: "Functions that glue things into bigger
objects are not worth extracting, nor are functions that
just pull stuff out of records. We want helper functions
that actually compute something."

**Test the body:** does it compute, or does it just shape?

| Computation | Shape |
|---|---|
| `Execute.applyEvent` | `{ rs ‌\| foo = bar }` |
| `nowMs + beatMs` | `case action of MergeStack p -> Just { sourceStack = p.source }` |
| `BoardDragAnimate.start { ... }` | `applyEntry`, `armBeat` (wrappers around `stepOne`) |

When the would-be helper is shape-only, **inline**. Use
`let` bindings inside the caller to name the narrow values
that DO get computed; build the final record literal once,
with all updates visible.

---

## Diagnostic 4 — Does the workhorse earn its length?

A **workhorse** is the canonical dispatcher for a `Msg`
(or input variant, or phase). It maps every variant to its
body in one long `case-of`. The workhorse is one-stop
shopping: a reader who wants to know what happens when
`ClickUndo` fires goes to `update`, finds `ClickUndo ->`,
and reads what happens. No hops.

**Long is honest** when the `Msg`-variant name IS the
section header. An extracted `clickUndo : Model -> ( Model,
Cmd Msg, Output )` is just a renamed branch — same shape
as `update` itself, same job, no scope reduction.

**Extraction earns its keep** when the callee:

- operates on a strictly narrower type (`Board`, not
  `Model`; `HandCardDragInfo`, not `Drag`),
- crosses a module boundary to a different domain (rules,
  geometry, gesture resolution),
- contains a real computation worth a name.

Same-shape helpers ("the body's still `Model -> ( Model,
Cmd Msg, Output )`") fail all three tests. **Inline them.**

### When a helper IS the right call

- Called from more than one place (real reuse).
- The dispatcher gets unscannable (~600+ lines, far higher
  than people fear — a 300-line `update` is fine).
- The branch contains a hairy computation whose name reads
  better than its body.

### Phase-driven workhorses

When the state machine has a tick of latency to spend,
name every phase as a variant in the `Phase` type. Each
tick reads phase, does phase-appropriate work, transitions.
The only function worth extracting alongside is the one
that **decides what phase to enter next** — because that
IS a real computation.

`Game.Replay` ended at 4 phases (`Starting | InBeat |
ExecutingAction | AnimatingAction`). Earlier 2-phase
attempts forced the variant dispatch into a 7-arm nested
case ladder. Naming the phases collapsed it.

---

## Diagnostic 5 — Are we manufacturing symmetry that isn't there?

Two related smells.

### Multiple Maybes → split along the noun

When a function takes **two or more `Maybe` parameters**:

1. The valid combinations don't span the cartesian product
   — the parameters aren't independent. The data is a
   flattened tagged union pretending to be N flags.
2. The function is unifying two distinct algorithms
   behind a single signature.

The cure is **not** "fewer Maybes" or "smaller helpers that
each take a Maybe." It's identifying the natural domain
axis — usually a noun like board vs hand, server vs client,
hot vs cold path — and splitting along it.

The hill: **anything past one `Maybe` in a signature is a
smell.** Two Maybes that aren't independent says "tagged
union pretending." Three Maybes is a near-certain flattened
union AND a missing axis.

### `side` parameters

When two operations look symmetric on the surface but have
different inputs, different checks, and different code
paths, they ARE NOT the same operation. Don't unify them
under a `side` / `direction` / `mode` parameter — write
each as its own named function.

The branching doesn't go away when you parameterize: it
moves INTO the helper. Now the helper is full of
`if side == "right": ... else: ...` and the caller has
lost the context that would have made the inline version
cleaner. The caller knew the side at the call site (cheap);
the helper now has to figure it out (expensive in clarity).

`left_merge` and `right_merge` as separate functions
trivially read. `merge(side="right")` makes you trace which
branch fires.

### Real-symmetric exception

Set-style operations (truly commutative — unordered sets,
intersection, union) get their own pathway. Name them for
what they are: `set_absorb`, not `absorb_either_side`.

---

## Diagnostic 6 — Where should the seam between consumers live?

When two consumers (full game + puzzle, two test drivers,
live + replay) need similar machinery:

- **Small duplication that decouples = load-bearing win.**
  If 5–10 lines of duplication means the two consumers
  genuinely don't need to know about each other, pay it.
- **Big duplication = smell that masks a missing seam.**
  If the same 50+ line block lives in two places, we
  failed to notice the shared concept. Don't paper over
  with copy-paste; find the seam and extract.

### Sibling module beats parameterization

When two hosts need similar but **different-scoped**
machinery, prefer cloning the engine into a sibling
module over parameterizing it.

Parameterization adds type parameters that propagate
everywhere. `ReplayState s` means every function and
every consumer has to thread `s`. Injected callbacks
(apply functions, decoders) become magical params at every
entry point. The two hosts may diverge over time. The
duplication tax is local; the parameterization tax
propagates.

`Puzzle.Replay` (~180 lines) lives as a sibling of
`Game.Replay.Animate` (~210 lines). Sub-machine
`BoardDragAnimate` is shared as-is — it operates on
`List CardStack`, which both hosts have. Total LOC
savings: zero. Readability gain: substantial.

### When to actually parameterize

- Three or more hosts converge on the same machinery —
  duplication-management cost outpaces parameterization
  tax.
- The "narrower" host actually needs every variant the
  wider host has, just with different Msg routing
  (msg-polymorphism is the right tool).
- Genuinely small leaf functions (a 5-line interp helper)
  shared across hosts. Type parameter doesn't propagate
  far.

---

## Diagnostic 7 — When in doubt, extract a leaf module

When Elm reports an import cycle, the right move is to
find the leaf concept being pulled across the cycle and
**extract it into its own small module**. Cycle
participants import the new leaf instead of each other.

The key property: **extraction is a one-way ratchet.** A
new module imports things that already existed; nothing
new imports it yet. So an extraction can never create a
cycle.

Steve's framing: "As long as you just break out stuff to
new modules, you'll never introduce circular dependencies
and get yourself into whack-a-mole mode."

**Anti-patterns that LOOK like cycle fixes:**

- **Reorganize one of the cycle participants.** Move a
  function out of A into B. Loop shape changed; loop
  remains.
- **Inline the leaf.** Duplicate the type/function across
  both modules. Works once, drifts.
- **Add a Maybe parameter to thread the value the other
  way.** Now you have a Maybe smell on top of the cycle.
- **Tighten or relax an export.** Next change re-creates
  the cycle.

**The reflex:** cycle = stop and surface to Steve.
Surface the cycle path, propose the leaf extraction, wait
for direction. One exchange dwarfs the cost of cascading
wrong fixes. This applies equally to **planned moves** —
if a refactor is about to force a helper relocation to
avoid a cycle, surface the relocation BEFORE making it.
The relocation itself is the structural decision worth
asking about, not the function wire-up that motivated it.

---

## Diagnostic 8 — Construct narrow types at the dispatch boundary

When a function in an outer layer dispatches on a wide sum
type and a deeper layer only cares about a narrower
subset, **construct the deeper layer's narrow type at the
dispatch site** where you've earned knowledge of the
variant. Don't pass the wide type down and re-dispatch
deeper.

`Game.Replay.Animate.startNextAction` matches on
`GameEvent.MergeStack p` and constructs
`BoardDragAnimate.Merge { sourceStack = p.source, ... }`
inline. The sub-machine never sees `GameEvent`, never has
to defend against variants it can't handle.

The conversion is a real computation, not shape work:
- Each layer owns its own action vocabulary.
- Field-name asymmetry can be normalized at the boundary
  (`GameEvent.MergeStack`'s `source` and `MoveStack`'s
  `stack` both become `sourceStack` in
  `BoardDragAnimateAction`).
- Less import drag, less coupling.

### When to pass the wide type

- The wide type IS the lower layer's natural input (e.g.,
  a generic event bus).
- The conversion would lose information the lower layer
  legitimately needs.

---

## The meta-principle — eliminate, don't paper over

Discomfort in the code is **information about the shape**,
not noise to wrap an adapter around.

When you find yourself adding a layer — a step counter, a
translation helper, a defer-this-until-later, a defensive
comment, a `_ -> X` fallback — stop. The discomfort is
telling you something the comment can't reach.

**This is particularly true in Lyn Rummy specifically.** We
own every layer (Elm, Go, TS agent, wire format, on-disk
session files, conformance fixtures) AND we are not yet
in production. We have the LUXURY of reshaping across
network and language boundaries when reality calls for it.
That luxury is rare; don't squander it by reaching for a
translation layer when the shape is wrong on both sides.

### Symptoms

- "Shouldn't happen" branches.
- Adapter functions whose body is *transform A's shape
  into what B expects* — translation layers are alarms.
- `fromWire_X` helpers that do more than direct
  field-rename. (Wire format is a projection of core
  types, not a separate model.)
- Code that obviously belongs to A but lives in B because
  of an import quirk.
- "Defer this round trip" patterns (lazy loaders for data
  that could ship in the initial payload).

### The license

I own the whole system. Elm, Go, TS, wire format, DB
schema, on-disk session files — all mine to reshape. When
two sides disagree, the constraints are mine to redraw.
Don't treat the contract as immutable when I'm the one
drawing the contract.

The diagnostic question at every decision point:

> Do I have enough data here to give the user the best
> experience? If yes, proceed. If no — is this
> **intrinsic** (unknowable at this point) or a **wire
> problem** (data exists, I never asked for it)? Intrinsic
> → fallback / "I don't know" mode. Wire problem → fix
> the wire.

Don't paper over a deficit I caused.

---

## Calibration — when NOT to apply these rules

Each diagnostic has a calibration section above; the
pattern across all of them is the same:

- **Cross-language / cross-process boundaries can be
  genuinely partial along specific axes.** The right
  axes are **reliability** (the host might be down, the
  network unreachable) and **synchronization** (we sent
  a request and haven't gotten the answer yet, the DOM
  hasn't been measured). Maybes for those axes are
  honest. We have COMPLETE control over the *shape* of
  what crosses the boundary, so a Maybe is NEVER "because
  the wire format is partial" — it's because reality is
  partial along reliability or synchronization, specifically.
- **Outermost orchestrators stay fat.** A dispatcher that
  legitimately uses 80% of `Model`'s fields shouldn't be
  artificially narrowed; the discipline applies to its
  helpers.
- **Real Maybes at boundaries stay.** `model.boardRect :
  Maybe Rect` is honest — the DOM measurement is
  asynchronous and the rect genuinely doesn't exist
  until the browser answers. The smell is internal-flag
  Maybes pretending to be data when the underlying fact
  IS known.

The risk pattern is **applying these rules as dogma**.
"Always narrow signatures" gives you a broken-invariant
mess like the old `placeHand`. "Always make state honest"
applied to a partial wire format breaks decode resilience.
The rules are diagnostics, not commandments.

---

## Prior art

Each diagnostic is grounded in a specific Lyn Rummy
episode. The list below is for forensic reference; you
don't need to read each one to apply the rules.

| Diagnostic | Episode | Date |
|---|---|---|
| State honest | FLOATER_TOPLEFT, ELM_AUTONOMY, ELM_AGENT_CATCHUP | 2026-04-20 to 2026-04-26 |
| Pass smallest type | floaterOverWing collapse (8 twins → 4), viewBoard narrowing | 2026-05-06 |
| Unit of consistency (too narrow) | Execute.placeHand widening to GameState→GameState | 2026-05-11 |
| Don't extract record-shape | applyEntry / armBeat / boardDragInputs inlining | 2026-05-09 |
| Workhorse pattern | Main.Play.update structure; MouseUp three-workhorse chain | 2026-05-06 |
| Explicit phases | Game.Replay 2-phase → 4-phase | 2026-05-09 |
| Split along the noun | finalizeMouseUp → per-side ladder | 2026-05-07 |
| `side` parameter | left_merge / right_merge split in Lyn Rummy absorbs | 2026-05-02 |
| Duplication vs decoupling | Game.Button vs Game.Sidebar; full-game vs puzzle replay | 2026-05-09 |
| Sibling module | Puzzle.Replay alongside Game.Replay.Animate | 2026-05-10 |
| Leaf module for cycles | Per-side ladder second attempt | 2026-05-07 |
| Construct at dispatch boundary | startNextAction building BoardDragAnimateAction inline | 2026-05-10 |
| Eliminate don't paper over | REPLAY_TURNS, LAB_AGENT_PLAY, simplify-before-patching | 2026-04-13 to 2026-04-26 |
