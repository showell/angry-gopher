module Lab exposing (main)

{-| BOARD_LAB — a single-page gallery of curated LynRummy
puzzles. Each panel auto-creates a puzzle session on page
load and embeds a `Main.Play` instance in place. You play
within the gallery — drag a card, the gesture goes through
the normal telemetry pipeline into SQLite, scroll down to
the next puzzle.

Per-panel gameId (the puzzle session's id stringified)
disambiguates DOM ids so multiple Play instances coexist on
one page. Board DOM ids are per-gameId via
`State.boardDomIdFor`; hand-card DOM ids are shared across
instances (collision is harmless for live play since hand
cards are identified by mouse position, not DOM lookup —
only replay inside a single panel measures hand-card DOM
rects).

Always within-a-turn: each puzzle's lab-level state is just
`{ board, hand }` — no deck, no dealer, no turn cycling.
Puzzle catalog lives here as Elm literals; a follow-up will
pull from a Python-canonical catalog so agent and human
solutions to the same named puzzle can be correlated via
SQLite.

-}

import Browser
import Dict exposing (Dict)
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
import Html exposing (Html, div, h1, h2, p, text)
import Html.Attributes exposing (style)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Main.Msg as MainMsg
import Main.Play as Play
import Main.State as MainState



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


type alias Model =
    { demos : List Demo
    , panels : Dict String Panel
    }


{-| Per-puzzle panel state. Each puzzle's session is created on
page load (Creating) and swaps to Playing as soon as the
server returns the session id. Failed is the http-error case.
-}
type Panel
    = Creating
    | Playing MainState.Model
    | Failed String



-- MSG


type Msg
    = PuzzleSessionCreated String (Result Http.Error Int)
    | PlayMsg String MainMsg.Msg



-- CARD CONSTRUCTORS (to keep demo literals readable)


d1 : CardValue -> Suit -> Card
d1 v s =
    { value = v, suit = s, originDeck = DeckOne }


onBoard : Card -> BoardCard
onBoard c =
    { card = c, state = FirmlyOnBoard }


inHand : Card -> HandCard
inHand c =
    { card = c, state = HandNormal }


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
    { title = "Tight right edge"
    , description =
        "Hand has 9H. The 6H-7H-8H run sits hard against the "
            ++ "right edge — dropping 9H onto it in place would "
            ++ "push the merged stack off the board. You need to "
            ++ "MoveStack the run to a clearer spot first, then "
            ++ "merge. Two other stacks sit on the board too, so "
            ++ "the choice of where to move is a spatial call."
    , initial =
        { board =
            [ st 80 695 [ d1 Six Heart, d1 Seven Heart, d1 Eight Heart ]
            , st 80 400 [ d1 Five Club, d1 Five Diamond, d1 Five Spade ]
            , st 280 100 [ d1 Two Spade, d1 Three Spade, d1 Four Spade ]
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
        , subscriptions = subscriptions
        }


init : () -> ( Model, Cmd Msg )
init () =
    let
        initialPanels =
            demos
                |> List.map (\d -> ( d.title, Creating ))
                |> Dict.fromList
    in
    ( { demos = demos, panels = initialPanels }
    , Cmd.batch (List.map createPuzzleSession demos)
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        PuzzleSessionCreated title (Ok sessionId) ->
            let
                ( playModel, playCmd ) =
                    Play.init (Play.PuzzleSession sessionId)
            in
            ( { model
                | panels = Dict.insert title (Playing playModel) model.panels
              }
            , Cmd.map (PlayMsg title) playCmd
            )

        PuzzleSessionCreated title (Err err) ->
            ( { model
                | panels = Dict.insert title (Failed (httpErrorToString err)) model.panels
              }
            , Cmd.none
            )

        PlayMsg title pmsg ->
            case Dict.get title model.panels of
                Just (Playing p) ->
                    let
                        ( p2, c, _ ) =
                            Play.update pmsg p
                    in
                    ( { model
                        | panels = Dict.insert title (Playing p2) model.panels
                      }
                    , Cmd.map (PlayMsg title) c
                    )

                _ ->
                    ( model, Cmd.none )


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



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Dict.toList model.panels
        |> List.filterMap
            (\( title, panel ) ->
                case panel of
                    Playing p ->
                        Just (Sub.map (PlayMsg title) (Play.subscriptions p))

                    _ ->
                        Nothing
            )
        |> Sub.batch



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
        [ style "max-width" "1200px"
        , style "margin" "0 auto"
        , style "padding" "24px"
        , style "font-family" "sans-serif"
        ]
        ([ h1 [] [ text "BOARD_LAB" ]
         , p []
            [ text
                ("A gallery of hand-crafted LynRummy puzzles. Each "
                    ++ "loads ready to play. Scroll down after solving "
                    ++ "one to reach the next. Drags get captured into "
                    ++ "SQLite so the Python agent can study your "
                    ++ "spatial choices."
                )
            ]
         ]
            ++ List.map (viewDemo model) model.demos
        )


viewDemo : Model -> Demo -> Html Msg
viewDemo model demo =
    let
        panel =
            Dict.get demo.title model.panels
                |> Maybe.withDefault Creating
    in
    div
        [ style "border" "1px solid #ccc"
        , style "border-radius" "6px"
        , style "padding" "16px"
        , style "margin-top" "28px"
        , style "background" "#fafafa"
        ]
        [ h2 [ style "margin-top" "0" ] [ text demo.title ]
        , p [] [ text demo.description ]
        , viewPanelBody demo panel
        ]


viewPanelBody : Demo -> Panel -> Html Msg
viewPanelBody demo panel =
    case panel of
        Playing p ->
            div
                [ style "margin-top" "12px" ]
                [ Html.map (PlayMsg demo.title) (Play.view p) ]

        Creating ->
            div
                [ style "margin-top" "12px"
                , style "color" "#666"
                , style "font-style" "italic"
                ]
                [ text "Loading puzzle…" ]

        Failed reason ->
            div
                [ style "margin-top" "12px"
                , style "color" "#a00"
                ]
                [ text ("Could not load puzzle: " ++ reason) ]
