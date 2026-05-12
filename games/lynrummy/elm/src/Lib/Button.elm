module Lib.Button exposing
    ( button
    , disabledButton
    , link
    )

{-| Shared button styling. The seam is "how do I draw a
button in our current theme" — labels and Msgs vary
per-host (full game, puzzles), styling stays consistent.

Msg-polymorphic: caller passes their own Msg type. This
module never imports `Main.Msg` so it stays usable from
the puzzle host (which has its own Msg type) without
back-channeling into full-game concerns.

-}

import Lib.Colors exposing (navy)
import Html exposing (Html)
import Html.Attributes as Attr exposing (href, style)
import Html.Events as Events


{-| Active button. Caller passes the label + the Msg to fire
on click.
-}
button : String -> msg -> Html msg
button label msg =
    Html.button
        (Events.onClick msg :: themedAttrs)
        [ Html.text label ]


{-| Disabled button. Greyed out, `cursor: not-allowed`, no
click handler.
-}
disabledButton : String -> Html msg
disabledButton label =
    Html.button
        (Attr.disabled True :: disabledAttrs)
        [ Html.text label ]


{-| Anchor styled to match. Used for navigation that's a
real URL hop (e.g. "← Lobby"), not an in-app Msg.
-}
link : String -> String -> Html msg
link label url =
    Html.a
        (href url :: style "text-decoration" "none" :: themedAttrs)
        [ Html.text label ]



-- INTERNAL


themedAttrs : List (Html.Attribute msg)
themedAttrs =
    [ style "padding" "6px 12px"
    , style "font-size" "14px"
    , style "border" ("1px solid " ++ navy)
    , style "background" "white"
    , style "color" navy
    , style "border-radius" "3px"
    , style "cursor" "pointer"
    ]


disabledAttrs : List (Html.Attribute msg)
disabledAttrs =
    [ style "padding" "6px 12px"
    , style "font-size" "14px"
    , style "border" "1px solid #bbb"
    , style "background" "#f5f5f5"
    , style "color" "#bbb"
    , style "border-radius" "3px"
    , style "cursor" "not-allowed"
    ]
