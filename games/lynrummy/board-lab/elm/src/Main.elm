module Main exposing (main)

{-| BOARD_LAB — a single-page Elm app that will host a long
vertical list of curated LynRummy boards, each paired with
a "Show me" button that plays back the Python strategy's
solution for that board.

BOARD_LAB is always within-a-turn — no dealer, no deck, no
seat cycling, no turn-end ceremony. The demo state collapses
to `{ board, hand }` and each demo is a hand-crafted static
literal. This skeleton defines one such demo and renders it.

Known ugly / unfinished (TODO_BOARD_LAB):

  - Hand rendering wired, but the student-vs-opponent layout
    of the main app is gone — we just show the one hand below
    the board.
  - No "Show me" button wiring; button renders but no-ops.
  - No Python-replay fetch.
  - One hardcoded demo. Multiple demos + the `List Demo`
    shape come in a follow-up commit.

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



-- LAB STATE


{-| BOARD_LAB's whole-game state. Two fields, both owned by
the demo author. No deck, no opponent, no turn index.
-}
type alias LabState =
    { board : List CardStack
    , hand : Hand
    }


{-| A demo: metadata + starting state. Each one is a
hand-crafted static literal — the lab doesn't inherit
"opening board" from the main game's Dealer.
-}
type alias Demo =
    { title : String
    , description : String
    , initial : LabState
    }



-- CARD CONSTRUCTORS (TO KEEP THE DEMO LITERALS READABLE)


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
        "Student has a 9H in hand and a 6H-7H-8H run on the "
            ++ "board. The obvious move: extend the run by "
            ++ "merging 9H onto its right side."
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


main : Program () () ()
main =
    Browser.sandbox
        { init = ()
        , update = \_ model -> model
        , view = view
        }


view : () -> Html ()
view () =
    div
        [ style "max-width" "1000px"
        , style "margin" "0 auto"
        , style "padding" "24px"
        , style "font-family" "sans-serif"
        ]
        [ h1 [] [ text "BOARD_LAB — skeleton" ]
        , p []
            [ text
                ("A long page of curated LynRummy boards will live here. "
                    ++ "V1 renders one demo below using the main app's "
                    ++ "Game.View primitives — proof that the shared-source "
                    ++ "wiring works."
                )
            ]
        , viewDemo skeletonDemo
        ]


viewDemo : Demo -> Html ()
viewDemo demo =
    div
        [ style "border" "1px solid #ccc"
        , style "border-radius" "6px"
        , style "padding" "16px"
        , style "margin-top" "20px"
        , style "background" "#fafafa"
        ]
        [ h2 [ style "margin-top" "0" ] [ text demo.title ]
        , p [] [ text demo.description ]
        , View.boardShell
            (List.map View.viewStack demo.initial.board)
        , div
            [ style "margin-top" "16px" ]
            [ View.viewHand { attrsForCard = \_ -> [] } demo.initial.hand ]
        , div
            [ style "margin-top" "16px" ]
            [ button
                [ disabled True
                , style "padding" "6px 12px"
                , style "font-size" "14px"
                ]
                [ text "Show me (stub)" ]
            ]
        ]
