module Game.BoardGesture exposing
    ( BoardMouseUp(..)
    , handleMouseUp
    , mouseMove
    , resolveBoardCardGesture
    )

{-| Per-side resolution for board-card mouseup gestures.

`handleMouseUp` returns a `BoardMouseUp` value — a parallel-to-
`GameEvent` outcome shape that flows up to `Main.Play.update`,
which dispatches on the variant. Action variants carry the
gesture envelope inline so `Play` can fire `Wire.sendAction`
without re-deriving the path.

Lifted out of `Main.Gesture` so the board ladder lives in one
file alongside its sibling `Game.HandGesture`. The shared
small helper `isDropFootprintInBounds` is duplicated per-side
rather than shared via Maybe-flagged helpers.

-}

import Game.BoardActions exposing (Side)
import Game.BoardDrag exposing (BoardCardDragInfo)
import Game.CardStack as CardStack exposing (BoardLocation, CardStack)
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.Status as Status
import Game.WingView as WingView
import Main.State as State
import Main.Types exposing (PathFrame(..), Point)


{-| Result of resolving a board-card mouseup. `MergeStack` and
`MoveStack` carry the GameEvent payload AND the gesture
envelope so `Main.Play.update` can both `applyAction` and
`Wire.sendAction` without re-deriving anything. `Split` is the
click case (cursor stayed within `clickThreshold` of mousedown),
so it has no meaningful gesture and ships pathless.
`BoardCardOffBoard` is the scold case — the user dropped the
cards off the board. There's intentionally no "nothing happened"
variant: every mouseup on a board-card drag resolves into one
of these four cases.
-}
type BoardMouseUp
    = Split { stack : CardStack, cardIndex : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side, envelope : State.EnvelopeForGesture }
    | MoveStack { stack : CardStack, newLoc : BoardLocation, envelope : State.EnvelopeForGesture }
    | BoardCardOffBoard


{-| Mouseup handler for a board-card drag. Caller has
pattern-matched out the `BoardCardDragInfo` and passes it in
along with the live board rect. Builds the final info (release
point + closing gesture sample), then resolves into a
`BoardMouseUp` that the caller dispatches on.
-}
handleMouseUp : Point -> Float -> BoardCardDragInfo -> Maybe GA.Rect -> BoardMouseUp
handleMouseUp releasePoint tMs d boardRect =
    let
        delta =
            { x = releasePoint.x - d.cursor.x
            , y = releasePoint.y - d.cursor.y
            }

        releaseFloater =
            { left = d.floaterTopLeft.left + delta.x
            , top = d.floaterTopLeft.top + delta.y
            }

        dFull =
            { d
                | cursor = releasePoint
                , floaterTopLeft = releaseFloater
                , gesturePath =
                    d.gesturePath
                        ++ [ { tMs = tMs, x = releaseFloater.left, y = releaseFloater.top } ]
            }
    in
    case resolveBoardCardGesture dFull boardRect of
        Just outcome ->
            outcome

        Nothing ->
            BoardCardOffBoard


{-| Resolve a completed board-card drag into the action variant
(if any) it should produce. Click-vs-drag check: if the cursor
is still within `clickThreshold` of `originalCursor`, emit a
`Split` at the captured `cardIndex`. Returns Nothing only for
the off-board case — caller maps that to `BoardCardOffBoard`.

Action variants carry the gesture envelope (path + frame)
constructed from `d.gesturePath`; the frame is always
`BoardFrame` for board-origin drags.

-}
resolveBoardCardGesture : BoardCardDragInfo -> Maybe GA.Rect -> Maybe BoardMouseUp
resolveBoardCardGesture d boardRect =
    if GA.distSquared d.cursor d.originalCursor <= GA.clickThreshold then
        Just (Split { stack = d.stack, cardIndex = d.cardIndex })

    else
        let
            envelope =
                { path = d.gesturePath, frame = BoardFrame }

            hovered =
                WingView.hoveredWing d.floaterTopLeft (CardStack.stackDisplayWidth d.stack) d.wings
        in
        case hovered of
            Just wing ->
                Just
                    (MergeStack
                        { source = d.stack
                        , target = wing.target
                        , side = wing.side
                        , envelope = envelope
                        }
                    )

            Nothing ->
                if isCursorOverBoard d.cursor boardRect then
                    if isDropFootprintInBounds (CardStack.size d.stack) d.floaterTopLeft then
                        Just (MoveStack { stack = d.stack, newLoc = d.floaterTopLeft, envelope = envelope })

                    else
                        Nothing

                else
                    Nothing


{-| Mousemove handler for a board-card drag. Pure state
transformation — advances cursor + floater + gesture path,
recomputes hover status. Caller (the dispatcher in `Main.Play`)
wraps the returned `Info` into `DraggingBoardCard` and patches
the model.

Returns just the bits that change — there's no `Cmd Msg` slot
because mousemove never emits commands.

-}
mouseMove :
    Point
    -> Float
    -> BoardCardDragInfo
    -> Status.StatusMessage
    -> ( BoardCardDragInfo, Status.StatusMessage )
mouseMove pos tMs d currentStatus =
    let
        delta =
            { x = pos.x - d.cursor.x
            , y = pos.y - d.cursor.y
            }

        nextFloater =
            { left = d.floaterTopLeft.left + delta.x
            , top = d.floaterTopLeft.top + delta.y
            }

        nextPath =
            d.gesturePath
                ++ [ { tMs = tMs, x = nextFloater.left, y = nextFloater.top } ]

        nextD =
            { d
                | cursor = pos
                , floaterTopLeft = nextFloater
                , gesturePath = nextPath
            }

        hover floaterTopLeft =
            WingView.hoveredWing
                floaterTopLeft
                (CardStack.stackDisplayWidth d.stack)
                d.wings

        nextStatus =
            hoverStatus
                (hover d.floaterTopLeft)
                (hover nextD.floaterTopLeft)
                currentStatus
    in
    ( nextD, nextStatus )



-- PRIVATE HELPERS (small enough to duplicate in HandGesture)


hoverStatus :
    Maybe a
    -> Maybe a
    -> Status.StatusMessage
    -> Status.StatusMessage
hoverStatus currentHover nextHover currentStatus =
    if nextHover /= currentHover then
        case nextHover of
            Just _ ->
                wingHoverStatus

            Nothing ->
                currentStatus

    else
        currentStatus


wingHoverStatus : Status.StatusMessage
wingHoverStatus =
    { text = "Drop stack to complete merge.", kind = Status.Inform }


isCursorOverBoard : Point -> Maybe GA.Rect -> Bool
isCursorOverBoard cursor maybeRect =
    case maybeRect of
        Just rect ->
            GA.isCursorInRect cursor rect

        Nothing ->
            False


isDropFootprintInBounds : Int -> BoardLocation -> Bool
isDropFootprintInBounds cardCount loc =
    let
        bounds =
            BG.refereeBounds
    in
    (loc.left >= 0)
        && (loc.top >= 0)
        && (loc.left + BG.stackWidth cardCount <= bounds.maxWidth)
        && (loc.top + BG.cardHeight <= bounds.maxHeight)
