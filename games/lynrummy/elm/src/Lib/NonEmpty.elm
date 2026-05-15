module Lib.NonEmpty exposing
    ( NonEmpty
    , append
    , fromList
    , singleton
    , toList
    )

{-| Compile-time non-empty list. Records `first` separately from
`rest : List a` so the empty case is unrepresentable. Used for
`boardPath` on merge_stack / move_stack events — the animator
requires at least one sample point, and the type now enforces it.
-}


type alias NonEmpty a =
    { first : a, rest : List a }


singleton : a -> NonEmpty a
singleton a =
    { first = a, rest = [] }


toList : NonEmpty a -> List a
toList { first, rest } =
    first :: rest


fromList : List a -> Maybe (NonEmpty a)
fromList xs =
    case xs of
        [] ->
            Nothing

        x :: rs ->
            Just { first = x, rest = rs }


append : a -> NonEmpty a -> NonEmpty a
append x ne =
    { ne | rest = ne.rest ++ [ x ] }
