module Lib.Status exposing
    ( StatusKind(..)
    , StatusMessage
    , TextSegment(..)
    , actionLogFetchFailedStatus
    , actionRejectedStatus
    , cardDisplay
    , cardSegments
    , geometryFeedback
    , handNothingStatus
    , isCleanBoard
    , isolatedStatus
    , mergeStatus
    , offBoardScold
    , sessionAllocFailedStatus
    , viewStatusBar
    )

{-| Status messages, the helpers that build them, and the
status-bar renderer. Outcome-specific status builders live in
the modules whose outcomes they narrate (e.g.
`Lib.CompleteTurn.statusForCompleteTurn`); the chrome here
just renders a `StatusMessage`.
-}

import Lib.CardStack as CardStack exposing (CardStack)
import Lib.Physics.BoardGeometry as BoardGeometry exposing (BoardGeometryStatus(..))
import Lib.Rules.Card as Card
import Lib.Rules.StackType as StackType
import Html exposing (Html, div)
import Html.Attributes exposing (style)


type StatusKind
    = Inform
    | Celebrate
    | Scold


type alias StatusMessage =
    { text : String, kind : StatusKind }


viewStatusBar : StatusMessage -> Html msg
viewStatusBar status =
    let
        color =
            case status.kind of
                Inform ->
                    "#31708f"

                Celebrate ->
                    "green"

                Scold ->
                    "red"
    in
    div
        [ style "padding" "4px 20px"
        , style "font-size" "15px"
        , style "color" color
        , style "border-bottom" "1px solid #eee"
        , style "white-space" "pre-wrap"
        ]
        (List.map viewSegment (cardSegments status.text))


{-| A run of status text, split so card tokens can be colored
in their suit's color while everything else keeps the kind's
color.
-}
type TextSegment
    = Plain String
    | CardText Card.Card


{-| Split status text into plain runs and card tokens: a rank
char (A23456789TJQK) immediately followed by one of the four
suit glyphs. The glyphs never appear in any other context, so
the general parse is safe; a glyph whose preceding char isn't
a rank stays plain text. The origin deck is unknowable from
text and irrelevant to display — every token gets DeckOne.
-}
cardSegments : String -> List TextSegment
cardSegments text =
    let
        flush : List Char -> List TextSegment -> List TextSegment
        flush buf segs =
            case buf of
                [] ->
                    segs

                _ ->
                    Plain (String.fromList (List.reverse buf)) :: segs

        step : Char -> ( List Char, List TextSegment ) -> ( List Char, List TextSegment )
        step c ( buf, segs ) =
            if isSuitGlyph c then
                case buf of
                    rank :: rest ->
                        case Card.cardFromLabel (String.fromList [ rank, c ]) Card.DeckOne of
                            Just card ->
                                ( [], CardText card :: flush rest segs )

                            Nothing ->
                                ( c :: buf, segs )

                    [] ->
                        ( [ c ], segs )

            else
                ( c :: buf, segs )

        ( leftover, reversedSegs ) =
            String.foldl step ( [], [] ) text
    in
    List.reverse (flush leftover reversedSegs)


isSuitGlyph : Char -> Bool
isSuitGlyph c =
    c == '♥' || c == '♦' || c == '♠' || c == '♣'


{-| Player-facing card token: tens render as "10", as on the
actual card faces (the "T" spelling is for parsing and
monospace alignment, neither of which applies here).
-}
cardDisplay : Card.Card -> String
cardDisplay card =
    Card.valueDisplayStr card.value ++ Card.suitEmojiStr card.suit


viewSegment : TextSegment -> Html msg
viewSegment seg =
    case seg of
        Plain s ->
            Html.text s

        CardText card ->
            Html.span
                [ style "color" (cardColorStr card) ]
                [ Html.text (cardDisplay card) ]


{-| Same red/black the card faces use (`Lib.StackView`). -}
cardColorStr : Card.Card -> String
cardColorStr card =
    case Card.cardColor card of
        Card.Red ->
            "red"

        Card.Black ->
            "black"


{-| Surface a board-geometry tidiness change as a status
message, or `Nothing` if there's nothing geometry-relevant to
say. Returns `Just (Celebrate)` when a Crowded board became
CleanlySpaced, `Just (Scold)` when the action left the board
Crowded (regardless of where it came from), `Nothing` otherwise
— callers fall back to their action-specific status.

Mirrors the post-hook in angry-cat's
`process_and_push_player_action`. When a feedback fires it
overrides the primary message, matching the TS order-of-
operations.

-}
geometryFeedback : List CardStack -> List CardStack -> Maybe StatusMessage
geometryFeedback oldBoard newBoard =
    case
        ( BoardGeometry.classifyBoardGeometry oldBoard BoardGeometry.refereeBounds
        , BoardGeometry.classifyBoardGeometry newBoard BoardGeometry.refereeBounds
        )
    of
        ( Crowded, CleanlySpaced ) ->
            Just { text = "Nice and tidy!", kind = Celebrate }

        ( _, Crowded ) ->
            Just
                { text = "Board is getting tight — try spacing stacks out!"
                , kind = Scold
                }

        _ ->
            Nothing


{-| The merge outcome depends on the size of the newly-merged
stack (always the last entry of the post board, by reducer
convention) and whether the whole post board is clean.
-}
mergeStatus : List CardStack -> StatusMessage
mergeStatus board =
    case List.reverse board of
        [] ->
            { text = "Merged.", kind = Inform }

        mergedStack :: _ ->
            if CardStack.size mergedStack < 3 then
                { text = "Nice, but where's the third card?", kind = Scold }

            else if isCleanBoard board then
                { text = "Combined! Clean board!", kind = Celebrate }

            else
                { text = "Combined!", kind = Celebrate }


{-| Every stack classifies as a valid group (Set / PureRun /
RedBlackRun). Mirrors the TS `CurrentBoard.is_clean()`.
-}
isCleanBoard : List CardStack -> Bool
isCleanBoard board =
    List.all (stackCards >> StackType.getStackType >> isCompleteType) board


stackCards : CardStack -> List Card.Card
stackCards stack =
    List.map .card stack.boardCards


isCompleteType : StackType.CardStackType -> Bool
isCompleteType t =
    case t of
        StackType.Set ->
            True

        StackType.PureRun ->
            True

        StackType.RedBlackRun ->
            True

        StackType.Incomplete ->
            False

        StackType.Bogus ->
            False

        StackType.Dup ->
            False


offBoardScold : StatusMessage
offBoardScold =
    { text = "Don't knock cards off the board, please. You're not a cat!"
    , kind = Scold
    }


handNothingStatus : StatusMessage
handNothingStatus =
    { text = "Drop on a stack to merge, or on open space to place."
    , kind = Inform
    }


isolatedStatus : StatusMessage
isolatedStatus =
    { text = "Isolated — drag to move.", kind = Inform }


actionRejectedStatus : StatusMessage
actionRejectedStatus =
    { text = "Server rejected action — check console; state may be out of sync."
    , kind = Scold
    }


sessionAllocFailedStatus : StatusMessage
sessionAllocFailedStatus =
    { text = "Could not allocate a session — check console."
    , kind = Scold
    }


actionLogFetchFailedStatus : StatusMessage
actionLogFetchFailedStatus =
    { text = "Could not load action log — check console."
    , kind = Scold
    }
