module LynRummy.PlaceStack exposing
    ( BoardBounds
    , findOpenLoc
    , stackWidth
    )

{-| Collision-free placement math for new stacks on the
LynRummy board. Pure geometry. Faithful port of
`angry-cat/src/lyn_rummy/game/place_stack.ts`.

When a move produces a NEW stack (e.g. peel a card off, split
a run), this module computes a top/left position that does
not overlap any existing stack on the board.

Intentional Elm divergences:

  - Takes `List CardStack` (native Elm type) rather than the
    TS `JsonCardStack[]`. The placer only uses `.loc` and
    `.boardCards` length — both are already on `CardStack`.
  - Nested `for` loops with early `break` → recursive walk of
    a generated candidate list.

-}

import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack)



-- CONSTANTS


cardHeight : Int
cardHeight =
    40


cardPitch : Int
cardPitch =
    CardStack.cardWidth + 6



-- PUBLIC TYPES


{-| Visible region the placer is allowed to use. All four
fields required (no defaults) so the caller makes explicit
decisions about size, padding, and sweep granularity.

  - `maxWidth` / `maxHeight` — usable area in pixels.
  - `margin` — extra padding around each stack.
  - `step` — candidate-sweep granularity; smaller = tighter
    packing, more iterations. 10 is a sensible default.

-}
type alias BoardBounds =
    { maxWidth : Int
    , maxHeight : Int
    , margin : Int
    , step : Int
    }



-- WIDTH


{-| Pixel width of a stack with `n` cards. 0 for n ≤ 0.
-}
stackWidth : Int -> Int
stackWidth cardCount =
    if cardCount <= 0 then
        0

    else
        CardStack.cardWidth + (cardCount - 1) * cardPitch



-- INTERNAL: RECTANGLES


type alias Rect =
    { left : Int
    , top : Int
    , right : Int
    , bottom : Int
    }


stackRect : CardStack -> Rect
stackRect stack =
    let
        left =
            stack.loc.left

        top =
            stack.loc.top
    in
    { left = left
    , top = top
    , right = left + stackWidth (List.length stack.boardCards)
    , bottom = top + cardHeight
    }


rectsOverlap : Rect -> Rect -> Bool
rectsOverlap a b =
    a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top



-- PUBLIC: FIND AN OPEN LOC


{-| Find a top/left position for a new stack of `cardCount`
cards such that its bounding box (padded by `bounds.margin`)
does not overlap any existing stack.

Sweeps a uniform grid from the top-left corner downward,
`bounds.step` at a time, and returns the first hit.

If no position fits within the bounds, returns the bottom-left
corner of the bounds as a fallback so the caller always has
a usable `BoardLocation`. Callers that care about detecting
the failure can re-check the result against the existing
stacks.

-}
findOpenLoc : List CardStack -> Int -> BoardBounds -> BoardLocation
findOpenLoc existing cardCount bounds =
    let
        newW =
            stackWidth cardCount

        newH =
            cardHeight

        existingRects =
            List.map stackRect existing
    in
    case firstFit 0 0 newW newH bounds existingRects of
        Just loc ->
            loc

        Nothing ->
            { top = max 0 (bounds.maxHeight - newH)
            , left = 0
            }


{-| Recursively walk candidate positions row-major from (0,0)
until one clears or we exhaust the bounds.
-}
firstFit : Int -> Int -> Int -> Int -> BoardBounds -> List Rect -> Maybe BoardLocation
firstFit top left newW newH bounds existingRects =
    if top + newH > bounds.maxHeight then
        Nothing

    else if left + newW > bounds.maxWidth then
        firstFit (top + bounds.step) 0 newW newH bounds existingRects

    else
        let
            candidate =
                { left = left - bounds.margin
                , top = top - bounds.margin
                , right = left + newW + bounds.margin
                , bottom = top + newH + bounds.margin
                }

            collides =
                List.any (rectsOverlap candidate) existingRects
        in
        if collides then
            firstFit top (left + bounds.step) newW newH bounds existingRects

        else
            Just { top = top, left = left }
