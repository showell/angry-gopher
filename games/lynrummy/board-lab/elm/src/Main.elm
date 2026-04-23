module Main exposing (main)

{-| BOARD_LAB — a single-page Elm app that hosts a vertical
list of curated LynRummy puzzles. Each puzzle has a "Play"
button that creates a fresh puzzle session in the main Gopher
backend and redirects into the familiar lynrummy-elm client,
where Steve plays the puzzle and every drag gets captured
by the existing gesture-telemetry pipeline. Python can then
read those solutions out of SQLite to study Steve's spatial
choices.

Always within-a-turn — each puzzle is a closed
`{ board, hand }` state with no deck, no dealer, no turn
cycling. The hand goes on the left of the board (per
2026-04-23 layout feedback) alongside the Play button.

Known ugly / unfinished (TODO_BOARD_LAB):

  - One hardcoded puzzle. A `List Demo` + scroll layout
    follows once the Play wiring is validated.
  - No replay-viewer for captured solutions yet.
  - No "agent tried this puzzle too" side-by-side.
  - No error-banner for HTTP failure beyond disabling
    the button.

-}

import Browser
import Browser.Navigation as Nav
import Game.Card as Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack as CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , CardStack
        , HandCard
        , HandCardState(..)
        )
import Game.Hand exposing (Hand)
import Game.View as View
import Html exposing (Html, button, div, h1, h2, p, text)
import Html.Attributes exposing (disabled, style)
import Html.Events exposing (onClick)
import Http
import Json.Decode as Decode
import Json.Encode as Encode



-- LAB STATE


type alias LabState =
    { board : List CardStack
    , hand : Hand
    }


type alias Demo =
    { title : String
    , description : String
    , initial : LabState
    }



-- MODEL


type PlayState
    = Idle
    | Creating
    | Failed String


type alias Model =
    { demo : Demo
    , play : PlayState
    }



-- MSG


type Msg
    = ClickPlay
    | PuzzleSessionCreated (Result Http.Error Int)



-- CARD CONSTRUCTORS (to keep the demo literals readable)


d1 : CardValue -> Suit -> Card
d1 v s =
    { value = v, suit = s, originDeck = DeckOne }


onBoard : Card -> BoardCard
onBoard c =
    { card = c, state = FirmlyOnBoard }


inHand : Card -> HandCard
inHand c =
    { card = c, state = HandNormal }



-- ONE DEMO (skeleton)


skeletonDemo : Demo
skeletonDemo =
    { title = "Direct play"
    , description =
        "Hand has 9H. Board has 6H-7H-8H. Merge 9H onto the "
            ++ "right side to extend the run."
    , initial =
        { board =
            [ { boardCards =
                    [ onBoard (d1 Six Heart)
                    , onBoard (d1 Seven Heart)
                    , onBoard (d1 Eight Heart)
                    ]
              , loc = { top = 80, left = 120 }
              }
            ]
        , hand =
            { handCards =
                [ inHand (d1 Nine Heart) ]
            }
        }
    }



-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }


init : () -> ( Model, Cmd Msg )
init () =
    ( { demo = skeletonDemo, play = Idle }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClickPlay ->
            ( { model | play = Creating }
            , createPuzzleSession model.demo
            )

        PuzzleSessionCreated (Ok sessionId) ->
            ( model
            , Nav.load
                ("/gopher/lynrummy-elm/play/" ++ String.fromInt sessionId)
            )

        PuzzleSessionCreated (Err err) ->
            ( { model | play = Failed (httpErrorToString err) }
            , Cmd.none
            )


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        Http.BadUrl s ->
            "bad URL: " ++ s

        Http.Timeout ->
            "timeout"

        Http.NetworkError ->
            "network error"

        Http.BadStatus code ->
            "bad status: " ++ String.fromInt code

        Http.BadBody s ->
            "bad body: " ++ s



-- HTTP


createPuzzleSession : Demo -> Cmd Msg
createPuzzleSession demo =
    Http.post
        { url = "/gopher/lynrummy-elm/new-puzzle-session"
        , body = Http.jsonBody (encodePuzzleRequest demo)
        , expect = Http.expectJson PuzzleSessionCreated sessionIdDecoder
        }


encodePuzzleRequest : Demo -> Encode.Value
encodePuzzleRequest demo =
    Encode.object
        [ ( "label", Encode.string ("board-lab: " ++ demo.title) )
        , ( "initial_state", encodeInitialState demo.initial )
        ]


encodeInitialState : LabState -> Encode.Value
encodeInitialState s =
    Encode.object
        [ ( "board", Encode.list CardStack.encodeCardStack s.board )
        , ( "hands"
          , Encode.list encodeHand [ s.hand, { handCards = [] } ]
          )
        , ( "deck", Encode.list Card.encodeCard [] )
        , ( "discard", Encode.list Card.encodeCard [] )
        , ( "active_player_index", Encode.int 0 )
        , ( "scores", Encode.list Encode.int [ 0, 0 ] )
        , ( "victor_awarded", Encode.bool False )
        , ( "turn_start_board_score", Encode.int 0 )
        , ( "turn_index", Encode.int 0 )
        , ( "cards_played_this_turn", Encode.int 0 )
        ]


encodeHand : Hand -> Encode.Value
encodeHand h =
    Encode.object
        [ ( "hand_cards"
          , Encode.list CardStack.encodeHandCard h.handCards
          )
        ]


sessionIdDecoder : Decode.Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "max-width" "1000px"
        , style "margin" "0 auto"
        , style "padding" "24px"
        , style "font-family" "sans-serif"
        ]
        [ h1 [] [ text "BOARD_LAB" ]
        , p []
            [ text
                ("A gallery of hand-crafted LynRummy puzzles. "
                    ++ "Click Play on one to open it in the main client "
                    ++ "— your drags get captured as a solution. Python "
                    ++ "can read those solutions out of SQLite to study "
                    ++ "your spatial choices."
                )
            ]
        , viewDemo model
        ]


viewDemo : Model -> Html Msg
viewDemo model =
    let
        demo =
            model.demo

        ( buttonLabel, buttonDisabled ) =
            case model.play of
                Idle ->
                    ( "Play this puzzle", False )

                Creating ->
                    ( "Opening…", True )

                Failed _ ->
                    ( "Retry", False )

        maybeError =
            case model.play of
                Failed reason ->
                    [ div
                        [ style "margin-top" "8px"
                        , style "color" "#a00"
                        , style "font-size" "13px"
                        ]
                        [ text ("Error: " ++ reason) ]
                    ]

                _ ->
                    []
    in
    div
        [ style "border" "1px solid #ccc"
        , style "border-radius" "6px"
        , style "padding" "16px"
        , style "margin-top" "20px"
        , style "background" "#fafafa"
        ]
        ([ h2 [ style "margin-top" "0" ] [ text demo.title ]
         , p [] [ text demo.description ]
         , div
            [ style "display" "flex"
            , style "align-items" "flex-start"
            , style "gap" "24px"
            , style "margin-top" "12px"
            ]
            [ div
                [ style "flex" "0 0 auto" ]
                [ View.viewHand { attrsForCard = \_ -> [] } demo.initial.hand
                , div
                    [ style "margin-top" "12px" ]
                    [ button
                        [ disabled buttonDisabled
                        , onClick ClickPlay
                        , style "padding" "6px 12px"
                        , style "font-size" "14px"
                        ]
                        [ text buttonLabel ]
                    ]
                ]
            , div
                [ style "flex" "1 1 auto" ]
                [ View.boardShell
                    (List.map View.viewStack demo.initial.board)
                ]
            ]
         ]
            ++ maybeError
        )
