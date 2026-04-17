# The Port So Far

*Status report, 2026-04-17 evening. Covers the LynRummy
TS→Elm port from start of day to where we are now. Mildly
reflective where the work produced an observation worth
noting; not durability-optimized.*

**← Prev:** [Drag and Wings](drag_and_wings.md)
**→ Next:** [Hand to Board](hand_to_board.md)

---

This is not retrospective in the reflective sense — it's a
status report with light reflection when something in the
shape of the work deserves a note. No grand arcs.

## Where we started this morning

Entering today, the durable model layer was already ported:
`Card`, `CardStack`, `Referee`, and the Tricks hierarchy
(`Trick`, `Helpers`, `DirectPlay`, `HandStacks`, `SplitForSet`,
`PeelForRun`, `RbSwap`, `PairPeel`, `LooseCardPlay`). Tests at
207, all green. The gesture-study layer from earlier in the
week had been ripped out to clear the deck for a clean UI
port. No Main, no view, no interaction.

The outstanding work per my earlier inventory: pure physics
modules nobody had touched (`Score`, `BoardPhysics`,
`PlayerTurn`, `BoardActions`, `PlaceStack`), and then the big
one — `game.ts` at 3046 lines, which owns state, turn flow,
and all the UI plumbing.

## The model-layer ports

Five modules went in sequence this morning:

| Module | TS LOC | Elm LOC | Tests added | Sidecar timing |
|---|---|---|---|---|
| `Score` | 51 | ~70 | +20 | Retroactive |
| `BoardPhysics` | 70 | ~90 | +13 | Retroactive |
| `PlayerTurn` | 87 | ~90 | +13 | Pre-port |
| `BoardActions` | 119 | ~160 | +12 | Pre-port |
| `PlaceStack` | 138 | ~130 | +11 | Pre-port |

Cumulative: 207 → 276 tests, all green at each step.

The sidecar-first pattern held once we committed to it from
`PlayerTurn` onward — write the `.claude` companion *before*
touching code (label, invariants, speculated divergences),
then port, then revise if the speculations were wrong. After
the second iteration, zero post-port sidecar revisions needed.
Not a methodology discovery so much as a confirmation that
labeling commits you to a mental model, and committing to a
mental model catches the easy port mistakes before the
compiler has to.

One modest finding dropped out of the `BoardPhysics` work:
the TS source had no direct `*_test.ts` companion for that
module; its functions were exercised indirectly via the trick
tests. The Elm port added 13 direct tests. Per the porting
cheat sheet, "if the source has no tests, that itself is the
finding" — faithful porting occasionally means filling
coverage the source never had, not just mirroring what's
there.

Nothing in the model-layer sequence was surprising, but the
stack of five modules added up. By late morning we had
everything needed to construct a board directly in Elm from
shorthand labels, without threading a deck.

## The opening board

Proposed checkpoint: render the opening board, no
interaction, no turn logic. The goal wasn't functionality —
it was visible pixels. A surface to react to. Same pattern as
the VM simulator iterations last week: get something on the
screen, let Steve eyeball it, iterate.

Three new files:

- `Dealer.elm` — six hardcoded stacks at formula-derived
  positions, constructed via `CardStack.fromShorthand`
  (`"KS,AS,2S,3S"`, `"TD,JD,QD,KD"`, etc.) rather than
  dealt from a deck. The deck threading belonged in a later
  pass; MVP didn't need it.
- `View.elm` — card / stack / board / heading primitives.
  Faithful port of the pure-drawing render functions in
  `game.ts:945–1180`.
- `Main.elm` — `Browser.element` with empty `Msg`, static
  model.

It rendered. We had a small QA loop about card padding (I
tried a tweak; Steve couldn't see the difference and asked why
I couldn't just steal his rendering code). I got defensive
about TS-vs-Elm impedance mismatches. Steve's resolution was
one sentence: "There's no CSS in Angry Cat. Let's move on. Do
use the style.foo as a starting point."

That was the first clear signal of the day that the fidelity
knob wasn't set at the project level — it was per-component.
Drawing code that the TS version implements as a handful of
inline style mutations wants a port that echoes those style
mutations almost verbatim, rather than reasoning about
rendering from first principles. The signal got louder later
in the day; I'll come back to it.

## The state-flow audit (shelved, but not wasted)

Before touching `game.ts`, the porting cheat sheet called for
a state-flow audit — map where state lives, trace the event
flow, propose a decomposition. I wrote it.

It was useful as a standalone artifact separate from whether
we ever port `game.ts` in that shape. What it did for me:
forced a careful read of a 3046-line file I had been treating
as an opaque boulder. Fourteen module-level mutable singletons
surfaced — six domain (`CurrentBoard`, `TheDeck`,
`ActivePlayer`, `PlayerGroup`, `TheGame`, `GameEventTracker`),
six UI (`PhysicalBoard`, `PlayerArea`, `BoardArea`,
`EventManager`, `DragDropHelper`, `StatusBar`), two meta. The
event flow went user → `BoardEvent` → `PlayerAction` →
`EventManager` → `GameEventTracker` → `TheGame` →
`CurrentBoard`/`Player` mutation → re-render. Classic
idiomatic-TS shape — not FP-disciplined, not closure-hell,
just the house style.

The proposed decomposition was twelve Elm modules, maybe
1400–1700 LOC. I ended with three yes/no rulings for Steve.
He read two paragraphs, said "clean mental mapping" on the
Player-record shape, and then pivoted.

## The pivot

"Big pivot. I want to get drag & drop working on the board
first. That's our biggest risk factor. It's also the most
fundamental part of the game."

Retrospectively obvious. The state-flow audit was careful
work on the wrong axis — we didn't need an ordered
decomposition of game state first; we needed to validate that
drag-drop felt like LynRummy at all. The entire decomposition
would be predicated on "we're definitely going to finish this
port," and finish-ability itself was in question until drag
worked. Cheap to discover, expensive to discover after the
twelve-module build-out.

Steve loosened the fidelity knob here — not from "mostly
faithful" to "mostly rewrite," but from "default-faithful" to
"faithful where it helps, rewrite where Elm wants a different
shape." Model/Msg/update is genuinely a different shape than
class-with-mutable-fields; the architecture necessarily
rewrites. Drawing code and rule logic are the same shape and
port directly.

As part of the pivot, I added three throwaway singletons to
the opening board — 7H, 8C, 4S — parked on the right for
drag testing. The 7H is a set candidate (the board already
has 7S,7D,7C); 8C extends the mixed-suit 6-run to 8; 4S
extends the spade K-A-2-3 run. These three cards exercise the
main ways merges can succeed and will come out of the code
before we leave the MVP.

## Drag and wings

Wrote "Drag and Wings" as a plan essay: three parts (base
drag physics / merge oracle / wings decoration), a `Model +
Msg` snippet, a wings-oracle snippet.

One misstep in the essay: I proposed "start with wings that
look visibly ugly, iterate from there." Steve corrected me —
`render_wing()` in `game.ts:984` is a clean existing
implementation, faithful port applies. I had let the
project-level "more lenient" ruling bleed down into a
component that should not have been affected. Updated the
essay in place and noted the distinction.

Implementation came in three passes, each one surfacing a
bug the previous hadn't seen. Zoom in / zoom out, the same
pattern the "Two Directions" essay was about.

### Pass 1 — wings inline in the stack div

Wings rendered as inline children of the stack div, matching
the TS DOM structure. Compiled, looked right on first render,
but I had ported a TS anti-pattern without recognizing it:
growing a wing from `width: 0` to `CARD_WIDTH` would push the
stack's cards to the right; TS compensates by mutating
`div.style.left` to shift the stack left by `CARD_WIDTH`.
Steve flagged it directly — "the stacks don't move"
(visually). The compensating left-shift is bookkeeping because
the wings are inside the wrapping div. He named it an ugly
pattern in his own code. Don't replicate.

This was a case where TS has a wart that faithful-porting
would have replicated, and *Steve himself* is the one telling
us to skip it. Fidelity can't mean copying acknowledged
warts; it means copying intent. I had conflated those.

### Pass 2 — wings as board-level siblings

Wings rendered as top-level board-absolute siblings of the
stack. Stack is stable. Wing is positioned at
`(stack.loc.left - pitch, stack.loc.top)` for Left, and
`(stack.loc.left + stackWidth, stack.loc.top)` for Right. The
wing itself stays a faithful port of `render_wing` — transparent
background, two transparent `+` card-chars for height, `width:
0` at rest — with `style_as_mergeable` / `style_for_hover`
colors applied at the call site (`hsl(105, 72.7%, 87.1%)` and
`#E0B0FF`). Drag-drop worked. But three symptoms:

- Dragging 4S lit a wing on the wrong side of
  `KS,AS,2S,3S`.
- Dragging 8C lit a wing on the wrong side of the six-run.
- Merging 7H onto the 7-set produced a merged stack at 7H's
  former location, not at the 7-set's.

### Pass 3 — target-first calling convention

The three symptoms had a single root cause. I was calling
`tryStackMerge source target side` — source first. The
underlying merge functions anchor the result on the *first*
argument (the `self` parameter in Elm terms). So merged
stacks landed at the source's position. And `side` in the TS
API is computed from `self`'s perspective, so wing placement
was inverted relative to the target-anchored UX I actually
wanted.

Steve's guidance was load-bearing here: "strong concept of
LEFT and RIGHT. Don't try to generalize them too much. Treat
them as two separate similar things." I rewrote the wing
oracle to call `tryStackMerge target source side` — target as
anchor — and to enumerate Left and Right as two distinct
cases with a plain `leftWing ++ rightWing` concat, not a loop
over a list of sides. The wing-rendering branch in `Main.elm`
also handles Left and Right independently, with `case
wing.side of` and no shared helper that would obscure which
direction we're in. No clever abstraction over "which side
we're on." Two cases, two branches.

The temptation to fold Left and Right into one parametrized
case-analysis is real — it looks cleaner, DRY, symmetric —
and it's exactly where side-specific bugs hide. Steve's rule
is a good general instinct: when two things look similar but
are not *semantically* the same thing (they're inverses, or
mirror images, or symmetric in a sense that still needs the
case analysis to be correct), keep them as two things. DRY'd
symmetry is fine when the symmetry is total; when it's
approximate, it eats hours.

Committed as MILESTONE `b2893b8`.

## Where we actually are

- Opening board renders.
- Drag-to-merge works over the board, for any stack.
- Wings light up on legal targets, on the correct side of
  the target.
- Mauve hover feedback on the wing the cursor is over.
- Merged stack anchors at the target's location.
- Drop-elsewhere snaps back (drag state cleared, board
  untouched).
- All 276 tests still pass.

Known rough edges: grab offset is fixed to stack-center (Elm
can't read `getBoundingClientRect` without ports, so the
stack jumps on pickup rather than honoring the grab point);
no touch events yet; single-card singletons are the only
source shape exercised so far; split-by-click is the next
contention point because a click and a drag-start compete on
the same mousedown — that'll want care.

## Connections worth a brief note

Three memories written during the VM-simulator work applied
directly here without adaptation. "Protagonist must be
visible and reactive" — the dragged stack is the protagonist
during a drag; we render a floating copy at 100% opacity
following the cursor, not a faint outline or an opacity dip.
"Time's arrow" doesn't literally apply to a spatial board,
but the related insight (spatial metaphor must read as
causality, not magic) does — the mergeable wing appearing in
light pastel green reads as "here is a legal next state,"
which is the visual language we want. "Proxy vs real
constraint" is in the same family as Steve's "don't
generalize LEFT and RIGHT": the stated constraint (avoid DRY
on two-case symmetry) is serving a real constraint (make
side-specific bugs easy to spot), and keeping them as two
cases is the direct way to serve the real one.

The ebb-and-flow pattern from "Two Directions" also showed
up: state-flow audit was zoom-out, drag pivot was zoom-in,
and within the drag work we went zoom-in / zoom-out several
more times (wings inline → wings as siblings; source-first →
target-first). Each zoom level surfaced a bug the previous
hadn't noticed. Nothing especially deep here — just that the
pattern keeps appearing, and we should assume it'll keep
appearing.

The sidecar-parity mechanism from the `virtual-machine-go`
repo isn't yet applied here. `elm-port-docs` doesn't have a
sidecar-parity checker. Sidecars exist for every ported
module, but nothing enforces they stay current as source
changes. That's an obvious cheap bridge waiting to be wired —
probably the first maintenance task after split-by-click
lands.

One tangential thing: the article-comments UI got two small
fixes today (duplicate Prev/Next at bottom; reply buttons on
`<li>` items). Unrelated to the port, but worth a note because
it represents the essay pipeline maturing under actual use.
Steve reads these essays in the Gopher web UI, leaves inline
comments, and the system gradually accumulates the ergonomic
touches a working documentation pipeline needs. The
article-comments layer is itself a bridge (repo markdown ↔
per-paragraph dialogue) and it's been quietly earning its
keep.

## Fidelity notes, folded in

Per-component fidelity is the right knob. The pattern today
crystallized into four categories, all of which got exercised
in close succession (which is probably why it crystallized
when it did):

- **Rule logic** (tricks, physics, scoring, merge
  validation): faithful port. Mirror shape exactly. Tests
  cross-check against TS-equivalent cases.
- **Drawing code** (`render_card`, `render_stack`,
  `render_wing`, style mutations): faithful port of the
  style properties and constants. Echo the numbers. Don't
  re-reason about rendering.
- **Stateful orchestration** (Model, Msg, update,
  subscriptions): rewrite for Elm's declarative shape.
  There's no one-to-one TS analog to mirror because the
  underlying architecture is different.
- **Ugly TS patterns Steve flags** (left-shift
  compensation, presumably others): skip. Replicate the
  semantics without the anti-pattern. Cross-reference the
  sidecar so future-us knows why we diverged.

This isn't a new framework — it's the "faithful port vs
rewrite vs in-between" question applied per component rather
than per project, which is already a memoried rule. Today
just happened to exercise all four categories in close
succession.

## Tally

- Essays shipped today: four (Inventory, Opening Board,
  State-Flow Audit, Drag and Wings). Chain bidirectional,
  footer-duplicated Prev/Next, checked.
- Modules ported today: five model-layer (Score,
  BoardPhysics, PlayerTurn, BoardActions, PlaceStack) + one
  UI (View) + one factory (Dealer) + one oracle
  (WingOracle) + Main.
- Tests: 207 → 276. No regressions.
- Bugs introduced → caught in-session: one wings-inside-stack
  (Pass 1); one source-first call convention (Pass 2→3).
- Decisions shelved: the twelve-module `game.ts`
  decomposition, the three yes/no rulings from the
  state-flow audit.
- MILESTONE commit: `b2893b8` — drag-to-merge works.

Drag works. That was the risk Steve flagged after lunch. By
evening the biggest unknown of the project has a working
floor.

— C.
