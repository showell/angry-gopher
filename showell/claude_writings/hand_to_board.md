# Hand to Board

*Forward plan, 2026-04-17 evening. Ported partially while
writing — the shapes in the code snippets are what we're
aiming for, not what's committed yet.*

**← Prev:** [The Port So Far](the_port_so_far.md)
**→ Next:** [The Fast Day](the_fast_day.md)

---

Next checkpoint: render player hands and allow a card to be
dragged from a hand onto the board — either to merge with an
existing stack, or to land as a new singleton. No turn logic,
no draw/discard, no scoring, no opponent animation. Just "pick
a card up, put it on the board."

The choice between this and split-by-click was whether to
broaden the surface or tackle the trickiest input problem.
Hand-drag won because it reuses the drag infrastructure we
just shipped. Split-by-click waits.

## What actually changes

Almost nothing in the existing drag pipeline. The state
machine (mousedown → move → up, with subscriptions gated on
`Dragging`) is identical. What changes is the *source* of the
drag: a board stack becomes one of two cases, and the
mousedown handler on hand cards is a second entry point that
produces the same kind of `DragInfo`.

The model extension is small:

```elm
type DragSource
    = FromBoardStack Int
    | FromHandCard { playerIndex : Int, cardIndex : Int }


type alias DragInfo =
    { source : DragSource
    , cursor : Point
    , grabOffset : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    }
```

That's the whole structural change. `sourceIndex : Int`
becomes `source : DragSource`, and everything downstream
pattern-matches on that.

`HandCard` already exists in `CardStack.elm` as a ported type
— hand cards carry a `Card`, a `HandCardState` (recency), and
an origin-deck tag, just like board cards. Nothing new to
port there.

## The wing oracle extends cleanly

`BoardActions.findAllHandMerges` is already implemented and
unused. It takes a `HandCard` and a list of board stacks,
returns a list of `HandMergeResult` with each legal merge's
target stack and side — same shape as `findAllStackMerges`
but for the hand-card-onto-stack case.

So the oracle branches on source:

```elm
wingsFor : DragSource -> Model -> List WingId
wingsFor source model =
    case source of
        FromBoardStack idx ->
            WingOracle.wingsForStack idx model.board

        FromHandCard { playerIndex, cardIndex } ->
            case lookupHandCard playerIndex cardIndex model of
                Just handCard ->
                    WingOracle.wingsForHandCard handCard model.board

                Nothing ->
                    []
```

Two entry points, one data shape out. The wing-rendering code
in `Main.elm` doesn't care which oracle produced the list —
it just renders each `WingId` with a side at a target's
position, with mouseenter/mouseleave for hover feedback.

I'll split `LynRummy.WingOracle` into `wingsForStack` and
`wingsForHandCard` rather than one polymorphic function —
same LEFT/RIGHT discipline as before, two similar things kept
as two things.

## The new drop case: landing as a singleton

Stack-drag has one commit path: "dropped on a wing → merge;
dropped elsewhere → snap back." Hand-drag has two:

- Dropped on a wing → `tryHandMerge`, applying the resulting
  `BoardChange`.
- Dropped on empty board → `placeHandCard` at the cursor's
  board-relative position, which creates a new single-card
  stack there.
- Dropped outside the board → snap back (card returns to
  hand, untouched).

So `MouseUp` grows one branch:

```elm
MouseUp ->
    case model.drag of
        Dragging info ->
            case info.hoveredWing of
                Just wing ->
                    -- Same as before; commit the merge.
                    commitMerge wing info model

                Nothing ->
                    case info.source of
                        FromHandCard handRef ->
                            if cursorOverBoard info.cursor model then
                                placeHandCardAt handRef info.cursor model

                            else
                                clearDrag model

                        FromBoardStack _ ->
                            -- Stacks snap back; we don't move
                            -- board stacks to new free positions
                            -- in this MVP (that's a future move).
                            clearDrag model

        NotDragging ->
            ( model, Cmd.none )
```

Two things to note. First, stack-drag's "drop elsewhere"
still just clears the drag — we're not implementing "move a
board stack to a new free position" yet, because that's a
separate decision about whether the board tolerates free
rearrangement (it should, but not today). Second,
`cursorOverBoard` needs a cheap way to know whether the
cursor is inside the board rectangle.

For that I'll add mouseenter / mouseleave listeners to the
`boardShell` element and track an `overBoard : Bool` in
`DragInfo`. Elm can't read `getBoundingClientRect` without a
port, so we let the DOM tell us via native hover events. This
is the same trick we used for wings.

`placeHandCardAt` translates the viewport cursor to
board-relative coordinates. The board's viewport origin we
*can* capture once at drag-start (the `onMouseDown` event has
`clientX/Y` and we know the cursor was over a hand-card whose
page position we chose, so we can derive the board origin
from that). But that's fragile. A cleaner approach: the
mouseenter on `boardShell` gives us `clientX/clientY` and the
element's `currentTarget` position implicitly (the element
IS the board). I'll figure out the exact decoder detail when
I wire it up — worst case, one-time `requestAnimationFrame`
port to read `getBoundingClientRect`, which is a small and
well-contained use of interop.

## Rendering the hand

The hand is a horizontal row of cards. Each card is the same
shape as a board card — same `viewCard` primitive, same
width/height — plus a mousedown handler that dispatches
`MouseDownOnHandCard`.

Two hands on screen. For MVP I'll do:

- **South hand** (the local player, the one whose cards are
  shown and draggable): rendered below the board, left-anchored
  near `x: 20` following the durable "hand upper-left"
  convention (runs grow rightward from a left anchor).
- **North hand** (opponent): rendered above the board, with
  cards face-down — `lavender` background per the direct port
  of `opponent_card_color()` in `game.ts:1176`. Not
  draggable.

For a single-player smoke test, one hand would do. I'm
rendering two so the layout negotiates real estate against
the board from the start — cheaper to discover "oh the
opponent's hand crowds the board" now than after three more
features land.

The opponent's cards render at a constant count (no logic
wires up a draw/discard flow), so we'll hardcode something
like 8 face-down lavender blanks for visual presence. I'll
add an opening-hand dealer to the `Dealer` module that
produces a short south hand — maybe 4 cards chosen to
exercise both the merge-to-wing and place-as-singleton paths.
Candidates I'm considering: two cards that will produce wings
on existing stacks (e.g. `5D` to extend `2H,3H,4H` — actually
5 of a different suit since that's a mixed-suit run;
something like `5C`), one card that's a pure singleton with
no legal merges, and one card that creates a potential
two-card pair or run start if placed nearby. The exact cards
we'll tune together once pixels exist — per the opening-board
pattern.

## What doesn't change

- The stack-drag code path. Same mousedown handler on the
  stack div, same `FromBoardStack` source, same commit
  logic. Both source types route through the same merge /
  snap-back branches of `MouseUp`.
- The wing view. `WingId` shape is unchanged; the renderer
  doesn't know or care whether the oracle that produced the
  list was stack-against-board or hand-against-board.
- The LEFT / RIGHT discipline. Two distinct cases, no
  generalization.
- `BoardActions`. All the functions we need —
  `tryHandMerge`, `findAllHandMerges`, `placeHandCard` —
  are already ported and have been sitting unused. This
  checkpoint is mostly plumbing, not new algorithms.

## Risk flags

- **Board-relative coordinates.** `placeHandCardAt` needs
  to translate viewport cursor coords to board-local coords.
  The board origin isn't known to Elm for free. My plan is
  mouseenter on `boardShell` + relative math; worst case,
  one small port for `getBoundingClientRect`. The port
  interop isn't scary, but it's a new dependency I'd rather
  avoid if the hover-based approach suffices.
- **Hand-card mousedown vs future split-by-click.** Hand
  cards aren't subject to the mousedown-contention problem
  that stack splits will be (you don't "split" a hand card
  into two), so hand-drag can use a simple mousedown
  handler. Split will need something more elaborate on
  stacks, but the hand path won't be affected.
- **Opponent hand layout.** Eight lavender blanks above the
  board is my placeholder. If the board is near the top of
  the viewport, the opponent hand either pushes the board
  down or goes somewhere else (below? left?). I'll ship a
  first cut and we iterate, same as the opening-board
  pattern.
- **Hand-card drag origin position.** A hand-card's "home"
  position (for snap-back) is its position in the hand row.
  Hand-card drag will render the card at cursor; on MouseUp,
  if we snap back, the hand re-renders normally (the view
  derives from hand state, which we haven't mutated). Clean.

## Shape of the implementation

Concretely, the changes break down as:

1. `Hand.elm` new module — `Hand` type (`{ handCards : List HandCard }`), helpers for `addCard` / `removeCard`. Probably 30-50 LOC + tests. Direct port of the `Hand` class (line 322 in `game.ts`) but deck-independent for now.
2. `LynRummy.WingOracle` — split into `wingsForStack` and `wingsForHandCard`. Tiny addition.
3. `View.elm` — add `viewHand : Hand -> HandPose -> Html msg` with `HandPose = { origin : Point, faceUp : Bool }`. Lavender back-card style for opponent. New exported helpers as needed.
4. `Main.elm` — extend `DragSource`, extend `MouseUp` branch, add `MouseDownOnHandCard` message + handler, add board mouseenter/leave to track `overBoard`, add `placeHandCardAt` commit path. Two small hands in the model; `Model = { board, southHand, northHand, drag }`.
5. `Dealer.elm` — add opening hands (small, hardcoded, tuned for the drag tests we want to exercise).
6. `check.sh` — new modules added to the standalone type-check list.

Tests: every new function in `Hand.elm` and the extended `WingOracle` gets direct coverage. The drag-path integration is still only reachable through the UI, same as the existing stack-drag.

## Momentum note

This checkpoint is a deliberate zoom-out: we validated drag
works on one surface, now we validate it generalizes to a
second surface before polishing the hardest part. If hand-drag
reuses the infrastructure the way I expect, it should land
fast and give us a broader visible game surface to stare at
while planning the split-by-click work.

If the board-relative-coordinates problem turns into real
research, that's the moment to pause and reconsider order. I
don't expect it to — DOM hover events solve most of it — but
flagging it as the one place this could turn into more work
than the plan suggests.

— C.
