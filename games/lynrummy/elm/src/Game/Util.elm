module Game.Util exposing (pluralize)

{-| Shared pure helpers for the `Game.*` subtree.

This module is a leaf — no domain types, no I/O, no rendering,
no `Msg`. Other `Game.*` modules import from here; nothing here
imports from them.

-}


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
