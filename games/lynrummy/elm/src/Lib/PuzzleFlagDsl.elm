module Lib.PuzzleFlagDsl exposing
    ( CatalogEntry
    , PuzzleFlag
    , parsePuzzleFlag
    )

{-| Parse the puzzle page's boot flag — a single DSL string the
Go server bakes into the `Elm.Puzzle.init` call. Shape:

    session_id: 17

    catalog:
      puzzle 4line_peel_push_push_steal_s1t1p0
        at (100,140): 2♥ 3♥ 4♥
        at (40,200): 7♠ 7♦ 7♣
        ...
      puzzle 4line_peel_steal_steal_steal_s2t3p1
        at (...): ...
        ...

`session_id` is server-allocated and shipped as a scalar at the
top; the `catalog:` block is a sequence of `puzzle <name>`
chunks. Each chunk's body is the same `at (left, top): cards`
grammar `BoardDsl.parseBoard` already consumes — this module
just slices the catalog into chunks and delegates the per-puzzle
parse.

-}

import Lib.BoardDsl as BoardDsl
import Lib.CardStack exposing (CardStack)


type alias CatalogEntry =
    { name : String
    , board : List CardStack
    }


type alias PuzzleFlag =
    { sessionId : Int
    , puzzles : List CatalogEntry
    }


parsePuzzleFlag : String -> Result String PuzzleFlag
parsePuzzleFlag src =
    let
        ( scalarLines, catalogBody ) =
            splitOnCatalogHeader (String.lines src)
    in
    Result.map2 PuzzleFlag
        (findInt "session_id" scalarLines)
        (parseCatalog catalogBody)


{-| Split the document into pre-`catalog:` lines and the
indented body that follows. Anything between is comment /
whitespace and is included in scalarLines (where it's ignored
by `findInt`). The `catalog:` header line itself is consumed.
-}
splitOnCatalogHeader : List String -> ( List String, List String )
splitOnCatalogHeader lines =
    case lines of
        [] ->
            ( [], [] )

        line :: rest ->
            if String.trim line == "catalog:" then
                ( [], List.map dropLeadingIndent rest )

            else
                let
                    ( pre, body ) =
                        splitOnCatalogHeader rest
                in
                ( line :: pre, body )


dropLeadingIndent : String -> String
dropLeadingIndent s =
    if String.startsWith "  " s then
        String.dropLeft 2 s

    else
        s


{-| Walk the catalog body (already de-indented one level), open
a new puzzle chunk on each `puzzle <name>` header line, collect
subsequent lines into that chunk, and parse each chunk's body
via `BoardDsl.parseBoard`. Puzzle order in the input is
preserved.
-}
parseCatalog : List String -> Result String (List CatalogEntry)
parseCatalog lines =
    sliceChunks lines []
        |> List.reverse
        |> traverse parseChunk


sliceChunks : List String -> List ( String, List String ) -> List ( String, List String )
sliceChunks lines acc =
    case lines of
        [] ->
            acc

        line :: rest ->
            case parsePuzzleHeader (String.trim line) of
                Just name ->
                    sliceChunks rest (( name, [] ) :: acc)

                Nothing ->
                    case acc of
                        ( name, body ) :: tail ->
                            sliceChunks rest (( name, line :: body ) :: tail)

                        [] ->
                            -- Bare content before the first puzzle
                            -- header — silently skip (comments, blank
                            -- lines, etc).
                            sliceChunks rest acc


parsePuzzleHeader : String -> Maybe String
parsePuzzleHeader line =
    if String.startsWith "puzzle " line then
        Just (String.trim (String.dropLeft 7 line))

    else
        Nothing


parseChunk : ( String, List String ) -> Result String CatalogEntry
parseChunk ( name, reversedBody ) =
    BoardDsl.parseBoard (String.join "\n" (List.reverse reversedBody))
        |> Result.map (\board -> { name = name, board = board })
        |> Result.mapError (\msg -> "puzzle " ++ name ++ ": " ++ msg)


traverse : (a -> Result e b) -> List a -> Result e (List b)
traverse f xs =
    case xs of
        [] ->
            Ok []

        x :: rest ->
            Result.map2 (::) (f x) (traverse f rest)


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
