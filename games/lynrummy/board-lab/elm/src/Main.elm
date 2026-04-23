port module Main exposing (main)

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
import Dict exposing (Dict)
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
    { demos : List Demo
    , playStates : Dict String PlayState
    }



-- MSG


type Msg
    = ClickPlay Demo
    | PuzzleSessionCreated String (Result Http.Error Int)



-- PORTS


{-| Open a URL in a new browser tab. Fired after the puzzle
session is created, so the student lands in the main client
without leaving the lab page.
-}
port openInNewTab : String -> Cmd msg



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



-- DEMO CONSTRUCTORS


st : Int -> Int -> List Card -> CardStack
st top left cards =
    { boardCards = List.map onBoard cards
    , loc = { top = top, left = left }
    }


hd : List Card -> Hand
hd cards =
    { handCards = List.map inHand cards }



-- PUZZLES


demos : List Demo
demos =
    [ pairPeelDemo
    , moveStackCrowdedDemo
    , splitForSetDemo
    , peelForRunDemo
    , followUpMergeDemo
    ]


pairPeelDemo : Demo
pairPeelDemo =
    { title = "Pair peel"
    , description =
        "Hand has two 3s. The board has a 4-card pure club run "
            ++ "with 3C at one end. Peel the 3C off the run and "
            ++ "merge it with your pair to form a 3-set of 3s."
    , initial =
        { board =
            [ st 100
                200
                [ d1 Three Club
                , d1 Four Club
                , d1 Five Club
                , d1 Six Club
                ]
            ]
        , hand = hd [ d1 Three Spade, d1 Three Diamond ]
        }
    }


moveStackCrowdedDemo : Demo
moveStackCrowdedDemo =
    { title = "MoveStack in crowded place"
    , description =
        "Hand has 9H. The board has your target run (6H-7H-8H) "
            ++ "packed near the right edge, with two other stacks "
            ++ "eating up the obvious relocation spots. Find a "
            ++ "clean way to reposition before merging."
    , initial =
        { board =
            [ st 80 640 [ d1 Six Heart, d1 Seven Heart, d1 Eight Heart ]
            , st 80 400 [ d1 Five Club, d1 Five Diamond, d1 Five Spade ]
            , st 260 100 [ d1 Two Spade, d1 Three Spade, d1 Four Spade ]
            ]
        , hand = hd [ d1 Nine Heart ]
        }
    }


splitForSetDemo : Demo
splitForSetDemo =
    { title = "Split for set"
    , description =
        "Hand has 5H and 5D. The board has a 7-card pure club "
            ++ "run with 5C in the middle. Extract 5C via a mid-run "
            ++ "split and merge the three 5s into a set."
    , initial =
        { board =
            [ st 100
                100
                [ d1 Two Club
                , d1 Three Club
                , d1 Four Club
                , d1 Five Club
                , d1 Six Club
                , d1 Seven Club
                , d1 Eight Club
                ]
            ]
        , hand = hd [ d1 Five Heart, d1 Five Diamond ]
        }
    }


peelForRunDemo : Demo
peelForRunDemo =
    { title = "Peel for run"
    , description =
        "Hand has 8S and 9S. The board has a 4-set of 7s. Peel "
            ++ "7S off the set (leaving a valid 3-set behind) and "
            ++ "merge with 8S-9S to form a pure run."
    , initial =
        { board =
            [ st 100
                180
                [ d1 Seven Spade
                , d1 Seven Heart
                , d1 Seven Diamond
                , d1 Seven Club
                ]
            ]
        , hand = hd [ d1 Eight Spade, d1 Nine Spade ]
        }
    }


followUpMergeDemo : Demo
followUpMergeDemo =
    { title = "Follow-up merge (chained runs)"
    , description =
        "Hand has 6H. Two heart runs sit on the board: 3H-4H-5H "
            ++ "and 7H-8H-9H. Merging 6H onto the low run makes "
            ++ "it 3-4-5-6 — which now chains with 7-8-9. Two "
            ++ "merges, one turn."
    , initial =
        { board =
            [ st 80 120 [ d1 Three Heart, d1 Four Heart, d1 Five Heart ]
            , st 260 480 [ d1 Seven Heart, d1 Eight Heart, d1 Nine Heart ]
            ]
        , hand = hd [ d1 Six Heart ]
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
    ( { demos = demos, playStates = Dict.empty }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClickPlay demo ->
            ( { model | playStates = Dict.insert demo.title Creating model.playStates }
            , createPuzzleSession demo
            )

        PuzzleSessionCreated _ (Ok sessionId) ->
            ( model
            , openInNewTab
                ("/gopher/lynrummy-elm/play/" ++ String.fromInt sessionId)
            )

        PuzzleSessionCreated title (Err err) ->
            ( { model
                | playStates =
                    Dict.insert title (Failed (httpErrorToString err)) model.playStates
              }
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
        , expect =
            Http.expectJson (PuzzleSessionCreated demo.title) sessionIdDecoder
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
        ([ h1 [] [ text "BOARD_LAB" ]
         , p []
            [ text
                ("A gallery of hand-crafted LynRummy puzzles. "
                    ++ "Click Play on one to open it in the main client "
                    ++ "— your drags get captured as a solution. Python "
                    ++ "can read those solutions out of SQLite to study "
                    ++ "your spatial choices."
                )
            ]
         ]
            ++ List.map (viewDemo model) model.demos
        )


viewDemo : Model -> Demo -> Html Msg
viewDemo model demo =
    let
        state =
            Dict.get demo.title model.playStates
                |> Maybe.withDefault Idle

        ( buttonLabel, buttonDisabled ) =
            case state of
                Idle ->
                    ( "Play this puzzle", False )

                Creating ->
                    ( "Opening…", True )

                Failed _ ->
                    ( "Retry", False )

        maybeError =
            case state of
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
        , style "margin-top" "28px"
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
                        , onClick (ClickPlay demo)
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
