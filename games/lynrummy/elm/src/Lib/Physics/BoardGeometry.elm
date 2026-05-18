module Lib.Physics.BoardGeometry exposing
    ( BoardBounds
    , BoardGeometryStatus(..)
    , GeometryError
    , GeometryErrorKind(..)
    , boardViewportLeft
    , boardViewportTop
    , cardHeight
    , cardPitch
    , classifyBoardGeometry
    , refereeBounds
    , stackWidth
    , validateBoardGeometry
    )

{-| Board geometry validation — checks that all stacks fit
within bounds and none overlap. Protocol-level constraint,
checked before game logic.

Two related but distinct concepts:

  - `BoardGeometryStatus` is a whole-board classification
    (`CleanlySpaced | Crowded | Illegal`). "Crowded" here
    means the overall board has at least one too-close pair.
  - `GeometryErrorKind` names a per-pair failure
    (`OutOfBounds | Overlap | TooClose`). `TooClose` is the
    pair-level name that rolls up into the board-level
    `Crowded` status.

-}

import Lib.CardStack exposing (CardStack, cardWidth, size)


type alias BoardBounds =
    { maxWidth : Int
    , maxHeight : Int
    , margin : Int -- minimum gap between stacks
    }


type GeometryErrorKind
    = OutOfBounds
    | Overlap
    | TooClose -- pair-level; rolls up into BoardGeometryStatus.Crowded


type alias GeometryError =
    { kind : GeometryErrorKind
    , message : String
    , stackIndices : List Int
    }


type BoardGeometryStatus
    = CleanlySpaced
    | Crowded
    | Illegal


{-| Internal — board / stack rectangles for overlap math.
-}
type alias Rect =
    { left : Int
    , top : Int
    , right : Int
    , bottom : Int
    }



-- CONSTANTS


cardHeight : Int
cardHeight =
    40


cardPitch : Int
cardPitch =
    cardWidth + 6


{-| Where the 800×600 board div sits in the viewport. Pinned
so that Elm and the canonical TS engine agree on the viewport
coordinate of every board stack: viewport = loc +
(boardViewportLeft, boardViewportTop). The status bar above
the board takes ~27px (padding 4px × 2 + font line ≈18 + 1px
border); top = 30 leaves ~3px of breathing room.
-}
boardViewportLeft : Int
boardViewportLeft =
    300


boardViewportTop : Int
boardViewportTop =
    30


stackWidth : Int -> Int
stackWidth cardCount =
    if cardCount <= 0 then
        0

    else
        cardWidth + (cardCount - 1) * cardPitch


{-| Bounds the kitchen-table game's referee uses to validate
end-of-turn layouts. The server no longer validates (dumb
file storage as of LEAN\_PASS phase 2); this is purely
client-side.
-}
refereeBounds : BoardBounds
refereeBounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


stackRect : CardStack -> Rect
stackRect s =
    { left = s.loc.left
    , top = s.loc.top
    , right = s.loc.left + stackWidth (size s)
    , bottom = s.loc.top + cardHeight
    }


isRectsOverlap : Rect -> Rect -> Bool
isRectsOverlap a b =
    a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top


padRect : Int -> Rect -> Rect
padRect margin r =
    { left = r.left - margin
    , top = r.top - margin
    , right = r.right + margin
    , bottom = r.bottom + margin
    }



-- VALIDATION


{-| Validate board geometry. Returns an empty list if the board
is CleanlySpaced; otherwise returns all errors.
-}
validateBoardGeometry : List CardStack -> BoardBounds -> List GeometryError
validateBoardGeometry stacks bounds =
    let
        rects =
            List.indexedMap (\i s -> ( i, stackRect s )) stacks

        boundsErrors =
            List.filterMap (checkBounds bounds) rects

        pairErrors =
            collectPairErrors bounds.margin rects
    in
    boundsErrors ++ pairErrors


checkBounds : BoardBounds -> ( Int, Rect ) -> Maybe GeometryError
checkBounds bounds ( i, r ) =
    if
        r.left
            < 0
            || r.top
            < 0
            || r.right
            > bounds.maxWidth
            || r.bottom
            > bounds.maxHeight
    then
        Just
            { kind = OutOfBounds
            , message =
                "Stack "
                    ++ String.fromInt i
                    ++ " extends outside the board (rect: "
                    ++ String.fromInt r.left
                    ++ ","
                    ++ String.fromInt r.top
                    ++ " → "
                    ++ String.fromInt r.right
                    ++ ","
                    ++ String.fromInt r.bottom
                    ++ ", bounds: "
                    ++ String.fromInt bounds.maxWidth
                    ++ "x"
                    ++ String.fromInt bounds.maxHeight
                    ++ ")"
            , stackIndices = [ i ]
            }

    else
        Nothing


collectPairErrors : Int -> List ( Int, Rect ) -> List GeometryError
collectPairErrors margin rects =
    case rects of
        [] ->
            []

        head :: rest ->
            let
                fromHead =
                    List.filterMap (checkPair margin head) rest
            in
            fromHead ++ collectPairErrors margin rest


checkPair : Int -> ( Int, Rect ) -> ( Int, Rect ) -> Maybe GeometryError
checkPair margin ( i, a ) ( j, b ) =
    if isRectsOverlap a b then
        Just
            { kind = Overlap
            , message =
                "Stacks "
                    ++ String.fromInt i
                    ++ " and "
                    ++ String.fromInt j
                    ++ " overlap"
            , stackIndices = [ i, j ]
            }

    else if isRectsOverlap (padRect margin a) b then
        Just
            { kind = TooClose
            , message =
                "Stacks "
                    ++ String.fromInt i
                    ++ " and "
                    ++ String.fromInt j
                    ++ " are too close (within "
                    ++ String.fromInt margin
                    ++ "px margin)"
            , stackIndices = [ i, j ]
            }

    else
        Nothing



-- CLASSIFICATION


{-| Classify the board's geometric state. Any `OutOfBounds` or
`Overlap` error ⇒ `Illegal`. If only `TooClose` errors,
`Crowded`. Otherwise `CleanlySpaced`.
-}
classifyBoardGeometry : List CardStack -> BoardBounds -> BoardGeometryStatus
classifyBoardGeometry stacks bounds =
    let
        errors =
            validateBoardGeometry stacks bounds

        isIllegalKind kind =
            kind == OutOfBounds || kind == Overlap
    in
    if List.any (\e -> isIllegalKind e.kind) errors then
        Illegal

    else if List.any (\e -> e.kind == TooClose) errors then
        Crowded

    else
        CleanlySpaced



-- JSON: WIRE FORMAT
--
--   BoardBounds   = { max_width, max_height, margin }
--   GeometryError = { type: "out_of_bounds" | "overlap" | "too_close",
--                     message, stack_indices }
