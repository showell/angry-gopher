module Game.PointerInput exposing
    ( cardMouseDown
    , mouseMoveDecoder
    , mouseUpDecoder
    , pointAndTimeDecoder
    )

{-| Pointer-event decoders + the board-card mousedown attr
builder. Shared between the full-game host (`Main.Gesture`)
and the puzzle host. Msg-polymorphic where relevant — callers
pass their own constructors.

-}

import Game.CardStack exposing (CardStack)
import Game.Point exposing (Point)
import Html
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)


{-| Decoder for mousedown events: pulls the cursor point AND
the `MouseEvent.timeStamp` (used for gesture-path capture).
-}
pointAndTimeDecoder : Decoder ( Point, Float )
pointAndTimeDecoder =
    Decode.map2 Tuple.pair
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


{-| Document-level mousemove decoder. Wired into
`Browser.Events.onMouseMove` while a drag is live. Caller
supplies its own `Point -> Float -> msg` constructor.
-}
mouseMoveDecoder : (Point -> Float -> msg) -> Decoder msg
mouseMoveDecoder toMsg =
    Decode.map2 toMsg
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


{-| Document-level mouseup decoder. Wired into
`Browser.Events.onMouseUp` while a drag is live.
-}
mouseUpDecoder : (Point -> Float -> msg) -> Decoder msg
mouseUpDecoder toMsg =
    Decode.map2 toMsg
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


{-| Mousedown attr-builder for a board card. Caller passes a
record-shaped constructor (`MouseDownOnBoardCard` or its
puzzle-host equivalent).
-}
cardMouseDown :
    ({ stack : CardStack, cardIndex : Int, point : Point, time : Float } -> msg)
    -> CardStack
    -> Int
    -> List (Html.Attribute msg)
cardMouseDown toMsg stack cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (\( p, t ) ->
                toMsg { stack = stack, cardIndex = cardIdx, point = p, time = t }
            )
            pointAndTimeDecoder
        )
    ]
