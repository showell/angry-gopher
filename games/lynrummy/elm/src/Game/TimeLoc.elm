module Game.TimeLoc exposing (TimeLoc, encodeTimeLoc)

import Json.Encode as Encode exposing (Value)


type alias TimeLoc =
    { tMs : Float, left : Int, top : Int }


encodeTimeLoc : TimeLoc -> Value
encodeTimeLoc t =
    Encode.object
        [ ( "t_ms", Encode.float t.tMs )
        , ( "left", Encode.int t.left )
        , ( "top", Encode.int t.top )
        ]
