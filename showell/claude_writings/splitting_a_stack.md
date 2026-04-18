# Splitting a Stack

*Written 2026-04-18. Forward plan, not retrospective. Proposes
the first piece of Elm code for the click-vs-drag arbitration
work — small enough to be a single committed slice, opinionated
enough to test the hunch that the elementsFromPoint capability
gap dissolves on its own.*

**← Prev:** [Reading DragDropHelper](reading_dragdrophelper.md)
**→ Next:** [The Bar for Done](the_bar_for_done.md)

---

The hunch from the console: TS uses `elementsFromPoint` at
pointerdown to discover *which inner card* a user touched while
the listener lives on the *outer stack*. Elm doesn't need to
make that discovery at runtime — we can put the listener on the
inner card directly, and the parent stack doesn't need a
listener at all. If that's right, the "capability gap" was a
TS-architecture artifact, and we don't have to replicate it.

The way to find out is to write the smallest possible vertical
slice of the new architecture and see if it holds. This essay
proposes that slice.

## What the slice does

One thing: enables splitting a board stack by clicking on a
specific card within it. Drag still works as it does today.
The slice is the first piece of code, not the whole engine —
the 1-pixel-distance threshold gets a stub value, the
one-card-stack scolding is deferred, ordinary-move-of-stack
stays as-is. We're testing the shape, not finishing the
feature.

## Why the architecture flip lets us dodge the capability gap

In TS, the stack div carries the pointerdown listener (because
the stack is the draggable thing), and the inner card div
carries a `data-click_key` data attribute. At pointerdown, the
parent listener walks `elementsFromPoint` to find which inner
card was under the cursor and grabs its `data-click_key`. The
inner card has no listener of its own.

Elm's natural shape is the inverse. The card is rendered as a
real DOM element; we can attach a `mousedown` handler directly
to it, and the event tells us which card it fired on. No
`elementsFromPoint` walk needed — the *event itself* carries
the identity of its target. Stack-level intent (start a drag)
and card-level intent (record a possible split target) come
from the *same* mousedown on the card; the parent stack is
never told about it.

Concretely: rather than a `mousedown` on the stack div that
starts a generic drag, we attach `mousedown` to each card div.
Each card knows its own `(stackIndex, cardIndex)`. The handler
fires a single `Msg` carrying both, plus the cursor point.
The `update` function decides what kind of gesture has begun.

## The Msg + decoder

A new `Msg` constructor that carries everything needed to
disambiguate:

```elm
type Msg
    = MouseDownOnBoardCard { stackIndex : Int, cardIndex : Int } Point
    | MouseDownOnHandCard Int Point
    | MouseMove Point
    | MouseUp
    | WingEntered WingId
    | WingLeft WingId
    | BoardEntered
    | BoardLeft
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
```

`MouseDownOnStack` goes away in this slice — board stacks are
no longer mousedown-targets. Each card div is. The decoder is
the existing `pointDecoder` we already use for hand cards;
nothing new there.

## The view wiring

`viewStackForBoard` currently attaches one mousedown to the
stack div. We move it to each card. Because `View.viewStackWithAttrs`
takes per-stack attributes, we instead need per-card
attributes — a small extension to the view.

The inline form of the new wiring (room for refactor later):

```elm
viewStackForBoard : DragState -> Int -> CardStack -> Html Msg
viewStackForBoard drag stackIdx stack =
    case drag of
        Dragging info ->
            -- (existing logic for hiding the source / showing
            -- non-source stacks unchanged)
            ...

        NotDragging ->
            View.viewStackWithCards
                stack
                (\cardIdx _ ->
                    [ Events.on "mousedown"
                        (Decode.map
                            (MouseDownOnBoardCard
                                { stackIndex = stackIdx, cardIndex = cardIdx }
                            )
                            pointDecoder
                        )
                    ]
                )
```

`View.viewStackWithCards` is the small new export — same as
`viewStackWithAttrs` but the per-card extra attributes are
supplied by a function `Int -> BoardCard -> List Attribute`.
About 15 lines in `View.elm`. The card div already exists in
the render path; we just give callers a hook to decorate each
one.

## DragInfo additions

Two new fields:

```elm
type alias DragInfo =
    { source : DragSource
    , cursor : Point
    , originalCursor : Point          -- NEW: for distance check
    , grabOffset : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , overBoard : Bool
    , boardRect : Maybe Rect
    , clickIntent : Maybe Int         -- NEW: cardIndex if the gesture
                                      --      may still resolve to a click
    }
```

`originalCursor` is just `cursor` at pointerdown time, retained
so we can compute distance later. `clickIntent` is `Just cardIdx`
when the gesture started on a board card (which is now the only
way it can start, for board sources), and gets cleared on
sufficient movement.

When the source is `FromHandCard`, `clickIntent` stays `Nothing`
— hand cards have no click-to-split semantic.

## The MouseDownOnBoardCard handler

Mirror of `startStackDrag`, but with the card-level info
threaded through:

```elm
startBoardCardDrag : { stackIndex : Int, cardIndex : Int } -> Point -> Model -> ( Model, Cmd Msg )
startBoardCardDrag { stackIndex, cardIndex } clientPoint model =
    case ( model.drag, listAt stackIndex model.board ) of
        ( NotDragging, Just stack ) ->
            let
                wings =
                    WingOracle.wingsForStack stackIndex model.board

                halfWidth =
                    CardStack.stackDisplayWidth stack // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromBoardStack stackIndex
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , overBoard = False
                        , boardRect = Nothing
                        , clickIntent = Just cardIndex
                        }
              }
            , Cmd.none
            )

        _ ->
            ( model, Cmd.none )
```

The only meaningful new line is `clickIntent = Just cardIndex`.
Otherwise this is the existing stack-drag startup.

## MouseMove kills click intent past the threshold

In the `MouseMove` branch:

```elm
MouseMove pos ->
    case model.drag of
        Dragging info ->
            let
                stillClick =
                    case info.clickIntent of
                        Nothing ->
                            Nothing

                        Just _ ->
                            if distSquared info.originalCursor pos > clickThreshold then
                                Nothing

                            else
                                info.clickIntent
            in
            ( { model | drag = Dragging { info | cursor = pos, clickIntent = stillClick } }
            , Cmd.none
            )

        NotDragging ->
            ( model, Cmd.none )


distSquared : Point -> Point -> Int
distSquared a b =
    let
        dx = a.x - b.x
        dy = a.y - b.y
    in
    dx * dx + dy * dy


clickThreshold : Int
clickThreshold =
    1
```

`clickThreshold = 1` mirrors the TS literal directly. Almost
certainly too tight for actual use (a steady hand on a
trackpad still jitters more than that), but the *shape* is
right and the value is a one-line tweak later.

## MouseUp resolves click vs drag

The release branch grows one new case at the top:

```elm
MouseUp ->
    case model.drag of
        Dragging info ->
            case ( info.clickIntent, info.source ) of
                ( Just cardIdx, FromBoardStack stackIdx ) ->
                    ( commitSplit stackIdx cardIdx model, Cmd.none )

                _ ->
                    -- existing wing/place/snap logic unchanged
                    ...

        NotDragging ->
            ( model, Cmd.none )


commitSplit : Int -> Int -> Model -> Model
commitSplit stackIdx cardIdx model =
    case listAt stackIdx model.board of
        Just stack ->
            let
                newStacks =
                    CardStack.split cardIdx stack
            in
            { model
                | board =
                    List.filter (\s -> not (CardStack.stacksEqual s stack)) model.board
                        ++ newStacks
                , drag = NotDragging
            }

        Nothing ->
            { model | drag = NotDragging }
```

`CardStack.split` is already ported and tested — it returns
the two stacks resulting from the split. We replace the
original stack on the board with both halves and clear the
drag.

Click takes precedence over drag here for the same reason it
does in TS: the case-arm pattern matches `Just clickIntent`
first; the wing-drop / place-as-singleton / snap-back branches
sit in the catch-all `_ ->` arm.

## What's deliberately not in this slice

- **One-card-stack scold.** TS scolds when you click a card
  in a 1-card stack ("Maybe you want to drag it instead?").
  This slice silently calls `CardStack.split` on a 1-card
  stack, which returns one or two stacks depending on its
  semantics — won't crash, may behave unexpectedly. Easy
  follow-up.
- **Threshold tuning.** `clickThreshold = 1` is the literal
  TS value; needs empirical tuning once the slice runs.
- **Hand-card behavior.** Unchanged. Hand cards still drag-
  only, no click-to-anything semantic.
- **Pointer events.** Slice uses mouseevents like the rest of
  the file. Pointer-event migration is its own change.
- **`setPointerCapture`-style guarantees.** Elm's
  `Browser.Events.onMouseMove` is already a global subscription
  during drag, so we get all motion events without needing
  capture. (One of those quiet wins from the architecture
  shift.)

## Why this slice is the right first piece

It's testable without touching the rest of the engine. After
the slice, the existing drag-to-merge and hand-to-board paths
work exactly as before, plus you can click a card in a multi-
card stack to split it. Steve can poke at it in the browser:
load the URL, click cards in the K-A-2-3 row, see splits
happen. If splits work and merges still work, the architecture
flip held; the elementsFromPoint gap really did dissolve.

If the slice surfaces something the hunch missed — say, the
mousedown on the card *also* needs to suppress some default
browser behavior, or the click handler races with the wing's
mouseenter logic — that surfaces as a concrete bug we can
look at, not as a category of unknown-unknown.

Either outcome is a real signal.

## Durability note

This code isn't aiming to be the final shape. Names, field
layout, the 1-pixel threshold, the lack of one-card-stack
scolding — all of those will get reshaped after a session of
hands-on play. The point is to land enough code that we have
something to react to.

— C.
