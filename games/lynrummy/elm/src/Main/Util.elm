module Main.Util exposing (listAt, pluralize)

{-| Shared pure helpers for the `Main.*` subtree.

Two functions share this module today:

  - `listAt` — index a list, returning `Maybe`. Used by
    `Main.State` (active-hand lookup) and `Main.View` (per-player
    score row).
  - `pluralize` — render an `Int` with a singular/plural noun.
    Used by `Main.View` in the turn-end popup copy.

Promoted here 2026-04-27. Both helpers had been buried as
private definitions inside `Main.State` (listAt) and `Main.View`
(listAt and pluralize); the listAt copies were textually
identical, and pluralize was a generic helper that did not
belong in the view module.

This module is a leaf — no domain types, no I/O, no rendering,
no `Msg`. Other `Main.*` modules import from here; nothing here
imports from them.

Note: two more identical copies of `listAt` live in
`Game/Game.elm` and `Game/GestureArbitration.elm`. Folding those
into a shared util is a separate `Game/`-scope concern.

-}


{-| Index into a list, returning `Nothing` when out of range.

Mirrors `List.Extra.getAt` from `elm-community/list-extra`,
which the project does NOT depend on. Implemented in core Elm.

-}
listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)


{-| Render `n` followed by `word`, appending `"s"` unless `n == 1`.

    pluralize 1 "card" --> "1 card"
    pluralize 0 "card" --> "0 cards"
    pluralize 3 "card" --> "3 cards"

Trivially-English: doesn't try to handle "fish" / "child" /
"goose"-style irregulars. Used today only on words whose plural
is `word ++ "s"` ("more card" → "more cards").

-}
pluralize : Int -> String -> String
pluralize n word =
    String.fromInt n
        ++ " "
        ++ word
        ++ (if n == 1 then
                ""

            else
                "s"
           )
