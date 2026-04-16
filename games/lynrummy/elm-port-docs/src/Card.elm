module Card exposing
    ( Card
    , Stack(..)
    , Suit(..)
    , placeLanded
    , stackCards
    , stackWithCards
    , suitColor
    , suitText
    , valueText
    )

{-| Domain types for cards/stacks. Suit & value semantics; no
geometry, no rendering. Shared by all gesture plugins.
-}


type Suit
    = Spades
    | Hearts
    | Diamonds
    | Clubs


type alias Card =
    { value : Int, suit : Suit, deck : Int }


type Stack
    = PureRun (List Card)
    | RbRun (List Card)
    | Set (List Card)


stackCards : Stack -> List Card
stackCards s =
    case s of
        PureRun cs ->
            cs

        RbRun cs ->
            cs

        Set cs ->
            cs


stackWithCards : Stack -> List Card -> Stack
stackWithCards s cs =
    case s of
        PureRun _ ->
            PureRun cs

        RbRun _ ->
            RbRun cs

        Set _ ->
            Set cs


{-| Insert a card at the head or tail of an existing card list,
based on which side of the run is being extended. Used by gestures
that append a card to a stack.
-}
placeLanded : String -> Card -> List Card -> List Card
placeLanded side card existing =
    if side == "L" then
        card :: existing

    else
        existing ++ [ card ]


valueText : Int -> String
valueText v =
    case v of
        1 ->
            "A"

        10 ->
            "10"

        11 ->
            "J"

        12 ->
            "Q"

        13 ->
            "K"

        _ ->
            String.fromInt v


suitText : Suit -> String
suitText s =
    case s of
        Spades ->
            "\u{2660}"

        Hearts ->
            "\u{2665}"

        Diamonds ->
            "\u{2666}"

        Clubs ->
            "\u{2663}"


suitColor : Suit -> String
suitColor s =
    case s of
        Hearts ->
            "#c00"

        Diamonds ->
            "#c00"

        _ ->
            "#000"
