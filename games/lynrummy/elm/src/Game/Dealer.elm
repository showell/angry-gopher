module Game.Dealer exposing
    ( GameSetup
    , dealFullGame
    , initialBoard
    )

{-| Dealer: produces the curated opening board and a full
autonomous `GameSetup` from a PRNG seed. Elm is the
authoritative dealer for live play (LEAN_PASS phase 2,
2026-04-28); the server is dumb file storage.

The opening board (six hardcoded stacks: KSAS2S3S,
TDJDQDKD, 2H3H4H, 7s, As, and the 234567 red-black run) is
the deliberate "get the game rolling" feature of the screen
game — without it players land on an empty board with no
moves. `dealFullGame seed` produces this curated board plus
two random 15-card hands by shuffling a 104-card double deck.

Conformance tests are the only consumers of seed
reproducibility now; they pin explicit fixtures rather than
re-deriving from a seed.

-}

import Game.Rules.Card as Card exposing (Card, OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardCardState(..), BoardLocation, CardStack)
import Game.Hand as Hand exposing (Hand)
import Game.Random as Random



-- BOARD


{-| The six-stack hardcoded opening board.
-}
initialBoard : List CardStack
initialBoard =
    List.indexedMap stackFromRow openingShorthands
        |> List.filterMap identity


openingShorthands : List String
openingShorthands =
    [ "KS,AS,2S,3S"
    , "TD,JD,QD,KD"
    , "2H,3H,4H"
    , "7S,7D,7C"
    , "AC,AD,AH"
    , "2C,3D,4C,5H,6S,7H"
    ]


stackFromRow : Int -> String -> Maybe CardStack
stackFromRow row sig =
    CardStack.fromShorthand sig DeckOne (rowLoc row)


rowLoc : Int -> BoardLocation
rowLoc row =
    let
        col =
            modBy 5 (row * 3 + 1)
    in
    { top = 20 + row * 60
    , left = 40 + col * 30
    }



-- FULL DEAL (seed-driven)


{-| Bundle returned by `dealFullGame`: initial board, both
players' 15-card hands, and the remaining draw deck.
-}
type alias GameSetup =
    { board : List CardStack
    , hands : List Hand
    , deck : List Card
    }


{-| Build a complete, playable initial game state from a seed.
Ported from `games/lynrummy/dealer.go:DealFullGame`.

Steps (matches the Go counterpart's shape):

1.  Shuffle a 104-card double deck via `Card.buildFullDoubleDeck`
    (Mulberry32 under the seed).
2.  Pull each card named in the six `openingShorthands` stacks
    from the shuffled deck, building the initial board at
    `rowLoc`-derived locations. Cards are pulled with
    `originDeck = DeckOne` so they match the hardcoded labels;
    the shuffled deck carries both deck identities, so the
    pull is a by-value/suit/deck equality match.
3.  Deal 15 cards from the front of the remaining deck to
    player 0, then 15 more to player 1.
4.  Return { board, hands = [P0, P1], deck = leftover }.

-}
dealFullGame : Random.Seed -> GameSetup
dealFullGame seed =
    let
        ( shuffled, _ ) =
            Card.buildFullDoubleDeck seed

        ( board, afterBoard ) =
            buildBoardFromDeck shuffled

        ( hand0Cards, afterHand0 ) =
            takeN 15 afterBoard

        ( hand1Cards, afterHand1 ) =
            takeN 15 afterHand0

        hand0 =
            Hand.addCards hand0Cards CardStack.HandNormal Hand.empty

        hand1 =
            Hand.addCards hand1Cards CardStack.HandNormal Hand.empty
    in
    { board = board
    , hands = [ hand0, hand1 ]
    , deck = afterHand1
    }


{-| Pull each named opening-board card from the deck (all
DeckOne), assemble the six initial stacks at their row
locations, and return (board, remainingDeck).

If the deck is missing a card that the openingShorthands
reference (shouldn't happen with a correct 104-card double
deck), that stack is skipped — caller ends up with fewer
stacks but the game can still start.
-}
buildBoardFromDeck : List Card -> ( List CardStack, List Card )
buildBoardFromDeck initialDeck =
    let
        indexedShorthands =
            List.indexedMap Tuple.pair openingShorthands
    in
    List.foldl pullOneStack ( [], initialDeck ) indexedShorthands


pullOneStack : ( Int, String ) -> ( List CardStack, List Card ) -> ( List CardStack, List Card )
pullOneStack ( row, shorthand ) ( stacksSoFar, deck ) =
    let
        labels =
            String.split "," shorthand
                |> List.map String.trim

        ( boardCards, afterPull ) =
            pullAllLabels labels deck
    in
    if List.length boardCards == List.length labels then
        let
            stack =
                { boardCards = boardCards, loc = rowLoc row }
        in
        ( stacksSoFar ++ [ stack ], afterPull )

    else
        ( stacksSoFar, deck )


pullAllLabels : List String -> List Card -> ( List { card : Card, state : BoardCardState }, List Card )
pullAllLabels labels deck =
    List.foldl pullOneLabel ( [], deck ) labels


pullOneLabel : String -> ( List { card : Card, state : BoardCardState }, List Card ) -> ( List { card : Card, state : BoardCardState }, List Card )
pullOneLabel label ( accBCs, deck ) =
    case Card.cardFromLabel label DeckOne of
        Just target ->
            case pullCard target deck of
                Just newDeck ->
                    ( accBCs ++ [ { card = target, state = FirmlyOnBoard } ], newDeck )

                Nothing ->
                    ( accBCs, deck )

        Nothing ->
            ( accBCs, deck )


pullCard : Card -> List Card -> Maybe (List Card)
pullCard target deck =
    case findIndex (cardEq target) deck of
        Just i ->
            Just (List.take i deck ++ List.drop (i + 1) deck)

        Nothing ->
            Nothing


cardEq : Card -> Card -> Bool
cardEq a b =
    a.value == b.value && a.suit == b.suit && a.originDeck == b.originDeck


findIndex : (a -> Bool) -> List a -> Maybe Int
findIndex pred xs =
    findIndexHelp pred xs 0


findIndexHelp : (a -> Bool) -> List a -> Int -> Maybe Int
findIndexHelp pred xs i =
    case xs of
        [] ->
            Nothing

        x :: rest ->
            if pred x then
                Just i

            else
                findIndexHelp pred rest (i + 1)


takeN : Int -> List a -> ( List a, List a )
takeN n xs =
    ( List.take n xs, List.drop n xs )
