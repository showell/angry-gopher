module Main exposing (main)

{-| TEA bootstrap for the standalone LynRummy game.

First milestone: render only the opening board. No
interaction, no Msgs dispatched, no turn logic. The Model
holds a static board loaded from `LynRummy.Dealer`.

-}

import Browser
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import LynRummy.CardStack exposing (CardStack)
import LynRummy.Dealer
import LynRummy.View as View



-- MODEL


type alias Model =
    { board : List CardStack }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { board = LynRummy.Dealer.initialBoard }, Cmd.none )



-- MSG


type Msg
    = NoOp



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model =
    ( model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "padding" "20px"
        , style "font-family" "system-ui, sans-serif"
        ]
        [ View.viewBoardHeading
        , View.viewBoard model.board
        ]



-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }
