module Lib.Popup exposing
    ( PopupContent
    , viewPopup
    )

{-| Popup view-chrome. The popup is the modal that appears at
turn-end (and other ack moments) with one of the admins
narrating. Single OK button, no focus trap or ESC handler.

`viewPopup` is msg-polymorphic — caller passes the dismiss
Msg, so this module stays Msg-agnostic. Outcome-specific
content builders (e.g. `popupForCompleteTurn`) live in the
modules whose outcomes they narrate; the chrome here just
renders a `PopupContent`.

-}

import Lib.Colors as Colors
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Html.Events as Events


type alias PopupContent =
    { admin : String
    , body : String
    }


viewPopup : msg -> Maybe PopupContent -> Html msg
viewPopup dismissMsg maybePopup =
    case maybePopup of
        Nothing ->
            Html.text ""

        Just { admin, body } ->
            div
                [ style "position" "fixed"
                , style "inset" "0"
                , style "background-color" "rgba(0, 0, 0, 0.45)"
                , style "display" "flex"
                , style "align-items" "center"
                , style "justify-content" "center"
                , style "z-index" "2000"
                ]
                [ div
                    [ style "background" "white"
                    , style "border" ("1px solid " ++ Colors.navy)
                    , style "border-radius" "12px"
                    , style "padding" "24px 28px"
                    , style "max-width" "420px"
                    , style "box-shadow" "0 10px 30px rgba(0, 0, 0, 0.25)"
                    ]
                    [ div
                        [ style "font-weight" "bold"
                        , style "color" Colors.navy
                        , style "font-size" "15px"
                        , style "margin-bottom" "10px"
                        ]
                        [ Html.text admin ]
                    , Html.pre
                        [ style "font-family" "inherit"
                        , style "white-space" "pre-wrap"
                        , style "margin" "0 0 18px 0"
                        , style "font-size" "14px"
                        , style "line-height" "1.45"
                        ]
                        [ Html.text body ]
                    , Html.button
                        [ Events.onClick dismissMsg
                        , style "background" Colors.navy
                        , style "color" "white"
                        , style "border" "none"
                        , style "padding" "8px 20px"
                        , style "border-radius" "4px"
                        , style "cursor" "pointer"
                        , style "font-size" "14px"
                        ]
                        [ Html.text "OK" ]
                    ]
                ]
