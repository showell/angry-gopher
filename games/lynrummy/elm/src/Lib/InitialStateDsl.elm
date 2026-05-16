module Lib.InitialStateDsl exposing
    ( formatGameState
    , parseGameState
    )

{-| DSL encoder + parser for a full `GameState`. One canonical
text shape, parsed on the resume path and emitted on every
new-session POST.

Document shape:

    board:
      at ( 26,  26): 2♥ 3♥ 4♥
      at (107,  52): 7♠ 7♦ 7♣

    Player One Hand:
      2♥ 5♥ J♥
      A♠ 3♠ K♠

    Player Two Hand:
      3♥ 4♥

    deck: K♣ Q♣' J♣ 5♥ 2♠ A♣

    active_player: 0
    turn_index: 0
    cards_played_this_turn: 0
    victor_awarded: false

Sections are separated by blank lines. Hand bodies and the
board body are owned by their respective DSL modules
(`Lib.HandDsl`, `Lib.BoardDsl`); this module dispatches on
section headers and assembles the resulting `GameState`.

-}

import Lib.BoardDsl as BoardDsl
import Lib.CardStack exposing (CardStack)
import Lib.GameState exposing (GameState)
import Lib.Hand as Hand exposing (Hand)
import Lib.HandDsl as HandDsl
import Lib.Player exposing (Player(..))
import Lib.Rules.Card as Card exposing (Card)



-- FORMAT


formatGameState : GameState -> String
formatGameState gs =
    String.join "\n\n"
        [ formatBoardBlock gs.board
        , formatHandBlock "Player One Hand:" gs.humanHand
        , formatHandBlock "Player Two Hand:" gs.agentHand
        , formatDeckLine gs.deck
        , formatScalarBlock gs
        ]


formatBoardBlock : List CardStack -> String
formatBoardBlock board =
    "board:\n" ++ indentLines (BoardDsl.formatBoard board)


formatHandBlock : String -> Hand -> String
formatHandBlock header hand =
    let
        body =
            HandDsl.formatHandBody hand
    in
    if body == "" then
        header

    else
        header ++ "\n" ++ body


formatDeckLine : List Card -> String
formatDeckLine deck =
    "deck: " ++ String.join " " (List.map Card.cardStr deck)


formatScalarBlock : GameState -> String
formatScalarBlock gs =
    String.join "\n"
        [ "active_player: " ++ playerToWireInt gs.activePlayer
        , "turn_index: " ++ String.fromInt gs.turnIndex
        , "cards_played_this_turn: " ++ String.fromInt gs.cardsPlayedThisTurn
        , "victor_awarded: " ++ boolStr gs.victorAwarded
        ]


{-| DSL convention: the human is "Player One" (0), the agent
is "Player Two" (1). Kept as Int on the wire so existing
session files and conformance fixtures parse unchanged.
-}
playerToWireInt : Player -> String
playerToWireInt p =
    case p of
        Human ->
            "0"

        Agent ->
            "1"


playerFromWireInt : Int -> Result String Player
playerFromWireInt n =
    case n of
        0 ->
            Ok Human

        1 ->
            Ok Agent

        _ ->
            Err ("active_player must be 0 or 1, got " ++ String.fromInt n)


boolStr : Bool -> String
boolStr b =
    if b then
        "true"

    else
        "false"


indentLines : String -> String
indentLines src =
    src
        |> String.lines
        |> List.map (\l -> "  " ++ l)
        |> String.join "\n"



-- PARSE


parseGameState : String -> Result String GameState
parseGameState src =
    src
        |> String.lines
        |> List.map dropComment
        |> List.filter (\l -> String.trim l /= "")
        |> walkLines emptyState


emptyState : GameState
emptyState =
    { board = []
    , humanHand = Hand.empty
    , agentHand = Hand.empty
    , activePlayer = Human
    , turnIndex = 0
    , deck = []
    , cardsPlayedThisTurn = 0
    , victorAwarded = False
    }


{-| Walk lines top-to-bottom. A line that ends with bare `:`
opens a section whose body is the following indented lines
(`board:`, `Player One Hand:`). A `key: value` line is a
scalar applied directly (`deck: cards`, `active_player: 0`).
Blank lines are already stripped — section ends are inferred
from indentation, not blanks, so the parser tolerates either
spacing.
-}
walkLines : GameState -> List String -> Result String GameState
walkLines gs lines =
    case lines of
        [] ->
            Ok gs

        line :: rest ->
            let
                trimmed =
                    String.trim line
            in
            if isSectionHeader trimmed then
                let
                    ( body, after ) =
                        takeIndented rest
                in
                dispatchSection trimmed body gs
                    |> Result.andThen (\next -> walkLines next after)

            else
                applyScalarLine trimmed gs
                    |> Result.andThen (\next -> walkLines next rest)


isSectionHeader : String -> Bool
isSectionHeader line =
    line
        == "board:"
        || String.startsWith "Player One Hand:" line
        || String.startsWith "Player Two Hand:" line


dropComment : String -> String
dropComment line =
    case String.indexes "#" line of
        i :: _ ->
            String.left i line

        [] ->
            line


takeIndented : List String -> ( List String, List String )
takeIndented lines =
    case lines of
        [] ->
            ( [], [] )

        line :: rest ->
            if String.startsWith " " line then
                let
                    ( more, after ) =
                        takeIndented rest
                in
                ( line :: more, after )

            else
                ( [], lines )


dispatchSection : String -> List String -> GameState -> Result String GameState
dispatchSection header body gs =
    if header == "board:" then
        BoardDsl.parseBoard (String.join "\n" body)
            |> Result.map (\b -> { gs | board = b })

    else if String.startsWith "Player One Hand" header then
        HandDsl.parseHandBody (String.join "\n" body)
            |> Result.map (\h -> { gs | humanHand = h })

    else if String.startsWith "Player Two Hand" header then
        HandDsl.parseHandBody (String.join "\n" body)
            |> Result.map (\h -> { gs | agentHand = h })

    else
        Err ("unknown section header: " ++ header)


applyScalarLine : String -> GameState -> Result String GameState
applyScalarLine line gs =
    case String.indexes ":" line of
        i :: _ ->
            let
                key =
                    String.trim (String.left i line)

                val =
                    String.trim (String.dropLeft (i + 1) line)
            in
            setScalar key val gs

        [] ->
            Err ("unrecognized line: " ++ line)


setScalar : String -> String -> GameState -> Result String GameState
setScalar key val gs =
    case key of
        -- Server-owned meta scalars. Present in the on-disk meta
        -- DSL and the resume payload; not part of GameState. Parsed
        -- as scalars (so they pass the "unknown key" check) and
        -- discarded. Elm doesn't surface them today.
        "created_at" ->
            Ok gs

        "label" ->
            Ok gs

        "deck_seed" ->
            Ok gs

        "deck" ->
            BoardDsl.parseCardTokens val
                |> Result.map (\d -> { gs | deck = d })

        "active_player" ->
            String.toInt val
                |> Result.fromMaybe ("active_player not an integer: " ++ val)
                |> Result.andThen playerFromWireInt
                |> Result.map (\p -> { gs | activePlayer = p })

        "turn_index" ->
            String.toInt val
                |> Result.fromMaybe ("turn_index not an integer: " ++ val)
                |> Result.map (\n -> { gs | turnIndex = n })

        "cards_played_this_turn" ->
            String.toInt val
                |> Result.fromMaybe ("cards_played_this_turn not an integer: " ++ val)
                |> Result.map (\n -> { gs | cardsPlayedThisTurn = n })

        "victor_awarded" ->
            parseBool val
                |> Result.map (\b -> { gs | victorAwarded = b })

        _ ->
            Err ("unknown scalar key: " ++ key)


parseBool : String -> Result String Bool
parseBool s =
    case s of
        "true" ->
            Ok True

        "false" ->
            Ok False

        _ ->
            Err ("not a bool: " ++ s)
