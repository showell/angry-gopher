module Game.PlaceStack exposing
    ( findOpenLoc
    , stackWidth
    )

{-| Collision-free placement math for new stacks on the
LynRummy board. Pure geometry. **Faithful port of
`games/lynrummy/python/geometry.py::find_open_loc`** —
column-major scan from `HUMAN_PREFERRED_ORIGIN`, anti-align,
PACK_GAP, then crowded-board legal-margin fallback. See the
Python module's docstring for the human-feel rationale.

The constants below mirror Python's module-level constants.
Both languages must agree exactly: any landed loc is
text-asserted by `tools/export_primitives_fixtures.py` /
`Game.PrimitivesConformanceTest.elm`.

-}

import Game.CardStack as CardStack exposing (BoardLocation, CardStack)



-- CONSTANTS (mirror python/geometry.py)


cardHeight : Int
cardHeight =
    40


cardPitch : Int
cardPitch =
    CardStack.cardWidth + 6


boardMaxWidth : Int
boardMaxWidth =
    800


boardMaxHeight : Int
boardMaxHeight =
    600


boardMargin : Int
boardMargin =
    7


packGapX : Int
packGapX =
    30


packGapY : Int
packGapY =
    30


antiAlignPx : Int
antiAlignPx =
    2


boardStartLeft : Int
boardStartLeft =
    24


boardStartTop : Int
boardStartTop =
    24


humanPreferredOriginLeft : Int
humanPreferredOriginLeft =
    50


humanPreferredOriginTop : Int
humanPreferredOriginTop =
    90


packStep : Int
packStep =
    15


placeStep : Int
placeStep =
    10



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
    { left = stack.loc.left
    , top = stack.loc.top
    , right = stack.loc.left + stackWidth (List.length stack.boardCards)
    , bottom = stack.loc.top + cardHeight
    }


isRectsOverlap : Rect -> Rect -> Bool
isRectsOverlap a b =
    a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top



-- PUBLIC: FIND AN OPEN LOC


{-| Faithful port of python/geometry.py::find_open_loc.

Empty board → BOARD_START + anti-align. Otherwise:

1. Phase 1 — column-major scan from HUMAN_PREFERRED_ORIGIN
   at packStep granularity, with PACK_GAP padding.
2. Phase 2 — same scan widened to the entire board.
3. Phase 3 — row-major fallback at placeStep with the
   referee's legal BOARD_MARGIN padding (used when the board
   is too crowded for human-feel spacing).
4. Final fallback — bottom-left corner.

Same inputs → same output, always.
-}
findOpenLoc : List CardStack -> Int -> BoardLocation
findOpenLoc existing cardCount =
    let
        newW =
            stackWidth cardCount

        newH =
            cardHeight

        existingRects =
            List.map stackRect existing
    in
    if List.isEmpty existingRects then
        antiAlign boardStartLeft boardStartTop newW newH

    else
        let
            minLeft =
                boardMargin

            minTop =
                boardMargin

            maxLeft =
                boardMaxWidth - newW - boardMargin

            maxTop =
                boardMaxHeight - newH - boardMargin

            startLeft =
                clamp minLeft maxLeft humanPreferredOriginLeft

            startTop =
                clamp minTop maxTop humanPreferredOriginTop
        in
        case
            packedScan
                { existingRects = existingRects
                , newW = newW
                , newH = newH
                , minLeft = startLeft
                , minTop = startTop
                , maxLeft = maxLeft
                , maxTop = maxTop
                }
        of
            Just loc ->
                antiAlign loc.left loc.top newW newH

            Nothing ->
                case
                    packedScan
                        { existingRects = existingRects
                        , newW = newW
                        , newH = newH
                        , minLeft = minLeft
                        , minTop = minTop
                        , maxLeft = maxLeft
                        , maxTop = maxTop
                        }
                of
                    Just loc ->
                        antiAlign loc.left loc.top newW newH

                    Nothing ->
                        gridSweep existingRects newW newH


type alias ScanArgs =
    { existingRects : List Rect
    , newW : Int
    , newH : Int
    , minLeft : Int
    , minTop : Int
    , maxLeft : Int
    , maxTop : Int
    }


{-| Column-major scan with PACK_GAP padding (Python's Phase 1 / 2
inner sweep). Outer loop = left, inner loop = top. Returns the
first hit's raw {top, left} (no anti-align — caller applies it).
-}
packedScan : ScanArgs -> Maybe { top : Int, left : Int }
packedScan args =
    packedScanLeft args args.minLeft


packedScanLeft : ScanArgs -> Int -> Maybe { top : Int, left : Int }
packedScanLeft args left =
    if left > args.maxLeft then
        Nothing

    else
        case packedScanTop args left args.minTop of
            Just hit ->
                Just hit

            Nothing ->
                packedScanLeft args (left + packStep)


packedScanTop : ScanArgs -> Int -> Int -> Maybe { top : Int, left : Int }
packedScanTop args left top =
    if top > args.maxTop then
        Nothing

    else if isPackGapClear args.existingRects left top args.newW args.newH then
        Just { left = left, top = top }

    else
        packedScanTop args left (top + packStep)


isPackGapClear : List Rect -> Int -> Int -> Int -> Int -> Bool
isPackGapClear rects left top newW newH =
    let
        padded =
            { left = left - packGapX
            , top = top - packGapY
            , right = left + newW + packGapX
            , bottom = top + newH + packGapY
            }
    in
    not (List.any (isRectsOverlap padded) rects)


{-| Crowded-board fallback: row-major sweep at placeStep with
the legal BOARD_MARGIN padding. Mirrors Python's
`_grid_sweep_open_loc`.
-}
gridSweep : List Rect -> Int -> Int -> BoardLocation
gridSweep existingRects newW newH =
    case gridSweepLoop existingRects newW newH 0 of
        Just loc ->
            loc

        Nothing ->
            { top = max 0 (boardMaxHeight - newH), left = 0 }


gridSweepLoop : List Rect -> Int -> Int -> Int -> Maybe BoardLocation
gridSweepLoop rects newW newH top =
    if top + newH > boardMaxHeight then
        Nothing

    else
        case gridSweepRow rects newW newH top 0 of
            Just loc ->
                Just loc

            Nothing ->
                gridSweepLoop rects newW newH (top + placeStep)


gridSweepRow : List Rect -> Int -> Int -> Int -> Int -> Maybe BoardLocation
gridSweepRow rects newW newH top left =
    if left + newW > boardMaxWidth then
        Nothing

    else
        let
            padded =
                { left = left - boardMargin
                , top = top - boardMargin
                , right = left + newW + boardMargin
                , bottom = top + newH + boardMargin
                }

            collides =
                List.any (isRectsOverlap padded) rects
        in
        if collides then
            gridSweepRow rects newW newH top (left + placeStep)

        else
            Just { top = top, left = left }


antiAlign : Int -> Int -> Int -> Int -> BoardLocation
antiAlign left top newW newH =
    { left = min (left + antiAlignPx) (boardMaxWidth - newW)
    , top = min (top + antiAlignPx) (boardMaxHeight - newH)
    }
