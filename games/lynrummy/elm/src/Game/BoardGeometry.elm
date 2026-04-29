module Game.BoardGeometry exposing
    ( BoardBounds
    , BoardGeometryStatus(..)
    , GeometryError
    , GeometryErrorKind(..)
    , boardBoundsDecoder
    , boardViewportLeft
    , boardViewportTop
    , cardHeight
    , cardPitch
    , classifyBoardGeometry
    , encodeBoardBounds
    , encodeGeometryError
    , geometryErrorDecoder
    , stackHeight
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

import Game.CardStack exposing (CardStack, cardWidth, size)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)



-- CONSTANTS


cardHeight : Int
cardHeight =
    40


cardPitch : Int
cardPitch =
    cardWidth + 6


{-| Where the 800×600 board div sits in the viewport. Pinned
so that Python (which has no DOM) and Elm agree on the
viewport coordinate of every board stack: viewport = loc +
(boardViewportLeft, boardViewportTop).

If you change these, update `geometry.py` to match.

-}
boardViewportLeft : Int
boardViewportLeft =
    300


boardViewportTop : Int
boardViewportTop =
    38


stackHeight : Int
stackHeight =
    cardHeight


stackWidth : Int -> Int
stackWidth cardCount =
    if cardCount <= 0 then
        0

    else
        cardWidth + (cardCount - 1) * cardPitch



-- TYPES


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



-- INTERNAL: Rect


type alias Rect =
    { left : Int
    , top : Int
    , right : Int
    , bottom : Int
    }


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


geometryErrorKindToString : GeometryErrorKind -> String
geometryErrorKindToString kind =
    case kind of
        OutOfBounds ->
            "out_of_bounds"

        Overlap ->
            "overlap"

        TooClose ->
            "too_close"


stringToGeometryErrorKind : String -> Maybe GeometryErrorKind
stringToGeometryErrorKind s =
    case s of
        "out_of_bounds" ->
            Just OutOfBounds

        "overlap" ->
            Just Overlap

        "too_close" ->
            Just TooClose

        _ ->
            Nothing


encodeBoardBounds : BoardBounds -> Value
encodeBoardBounds b =
    Encode.object
        [ ( "max_width", Encode.int b.maxWidth )
        , ( "max_height", Encode.int b.maxHeight )
        , ( "margin", Encode.int b.margin )
        ]


boardBoundsDecoder : Decoder BoardBounds
boardBoundsDecoder =
    Decode.map3
        (\w h m -> { maxWidth = w, maxHeight = h, margin = m })
        (Decode.field "max_width" Decode.int)
        (Decode.field "max_height" Decode.int)
        (Decode.field "margin" Decode.int)


encodeGeometryError : GeometryError -> Value
encodeGeometryError err =
    Encode.object
        [ ( "type", Encode.string (geometryErrorKindToString err.kind) )
        , ( "message", Encode.string err.message )
        , ( "stack_indices", Encode.list Encode.int err.stackIndices )
        ]


geometryErrorDecoder : Decoder GeometryError
geometryErrorDecoder =
    Decode.map3
        (\kind msg indices ->
            { kind = kind, message = msg, stackIndices = indices }
        )
        (Decode.field "type" stringEnumDecoder)
        (Decode.field "message" Decode.string)
        (Decode.field "stack_indices" (Decode.list Decode.int))


stringEnumDecoder : Decoder GeometryErrorKind
stringEnumDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case stringToGeometryErrorKind s of
                    Just k ->
                        Decode.succeed k

                    Nothing ->
                        Decode.fail
                            ("invalid geometry error kind: " ++ s)
            )
