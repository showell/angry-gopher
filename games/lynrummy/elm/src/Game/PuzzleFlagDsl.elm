module Game.PuzzleFlagDsl exposing
    ( PuzzleFlag
    , parsePuzzleFlag
    )

{-| Parse the puzzle page's boot flag — a single DSL string the
Go server bakes into the `Elm.Puzzle.init` call. Shape:

    session_id: 17

    board:
      at ( 26,  26): K♠ A♠ 2♠ 3♠
      at (107,  52): T♦ J♦ Q♦ K♦
      ...

`session_id` is server-allocated and shipped as a scalar at
the top; the `board:` block is exactly what `BoardDsl.parseBoard`
already consumes, so that's where the real parsing happens. This
module is the thin glue.

-}

import Game.BoardDsl as BoardDsl
import Game.CardStack exposing (CardStack)


type alias PuzzleFlag =
    { sessionId : Int
    , board : List CardStack
    }


parsePuzzleFlag : String -> Result String PuzzleFlag
parsePuzzleFlag src =
    let
        ( scalarLines, boardBody ) =
            splitOnBoardHeader (String.lines src)
    in
    Result.map2 PuzzleFlag
        (findInt "session_id" scalarLines)
        (BoardDsl.parseBoard (String.join "\n" boardBody))


{-| Split the document into pre-`board:` lines and the indented
body that follows. Anything between is comment / whitespace and
is included in scalarLines (where it's ignored by `findInt`).
The `board:` header line itself is consumed.
-}
splitOnBoardHeader : List String -> ( List String, List String )
splitOnBoardHeader lines =
    case lines of
        [] ->
            ( [], [] )

        line :: rest ->
            if String.trim line == "board:" then
                ( [], List.map dropLeadingIndent rest )

            else
                let
                    ( pre, body ) =
                        splitOnBoardHeader rest
                in
                ( line :: pre, body )


dropLeadingIndent : String -> String
dropLeadingIndent s =
    if String.startsWith "  " s then
        String.dropLeft 2 s

    else
        s


findInt : String -> List String -> Result String Int
findInt key lines =
    case lines of
        [] ->
            Err ("puzzle flag missing scalar: " ++ key)

        line :: rest ->
            case parseScalar (String.trim line) of
                Just ( k, v ) ->
                    if k == key then
                        String.toInt v
                            |> Result.fromMaybe ("puzzle flag: " ++ key ++ " not an integer: " ++ v)

                    else
                        findInt key rest

                Nothing ->
                    findInt key rest


parseScalar : String -> Maybe ( String, String )
parseScalar line =
    case String.indexes ":" line of
        i :: _ ->
            Just
                ( String.trim (String.left i line)
                , String.trim (String.dropLeft (i + 1) line)
                )

        [] ->
            Nothing
