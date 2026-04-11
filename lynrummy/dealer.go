// The Dealer sets up a LynRummy game: builds a shuffled double deck,
// pulls the initial board stacks, deals hands, and produces a
// WireGameSetup "photo" that any client can consume.
//
// The Dealer is autonomous — Angry Gopher can set up a game without
// needing an Angry Cat client. Any client (TypeScript, Python, curl)
// can read the resulting GameSetup and start playing.

package lynrummy

import "math/rand"

// --- Double deck ---

// BuildDoubleDeck creates a shuffled 104-card double deck.
func BuildDoubleDeck() []Card {
	var cards []Card
	for deck := 0; deck <= 1; deck++ {
		for suit := 0; suit <= 3; suit++ {
			for value := 1; value <= 13; value++ {
				cards = append(cards, Card{
					Value:      value,
					Suit:       Suit(suit),
					OriginDeck: deck,
				})
			}
		}
	}
	rand.Shuffle(len(cards), func(i, j int) {
		cards[i], cards[j] = cards[j], cards[i]
	})
	return cards
}

// --- Initial board stacks ---
//
// These are pulled from the deck (always deck 1) before dealing.
// The stacks and their board positions are hard-coded — chosen by
// the game designer to give players a starting board to work with.

type boardStackDef struct {
	row    int
	labels []string // e.g., ["K","S"], ["A","S"], ["2","S"], ["3","S"]
}

var initialBoardDefs = []boardStackDef{
	{0, []string{"KS", "AS", "2S", "3S"}},
	{1, []string{"TD", "JD", "QD", "KD"}},
	{2, []string{"2H", "3H", "4H"}},
	{3, []string{"7S", "7D", "7C"}},
	{4, []string{"AC", "AD", "AH"}},
	{5, []string{"2C", "3D", "4C", "5H", "6S", "7H"}},
}

func boardLocation(row int) Location {
	col := (row*3 + 1) % 5
	return Location{
		Top:  20 + row*60,
		Left: 40 + col*30,
	}
}

// parseLabel converts "KS" → Card{Value:13, Suit:Spade, OriginDeck:0}.
func parseLabel(label string) Card {
	var value int
	switch label[0] {
	case 'A':
		value = 1
	case '2':
		value = 2
	case '3':
		value = 3
	case '4':
		value = 4
	case '5':
		value = 5
	case '6':
		value = 6
	case '7':
		value = 7
	case '8':
		value = 8
	case '9':
		value = 9
	case 'T':
		value = 10
	case 'J':
		value = 11
	case 'Q':
		value = 12
	case 'K':
		value = 13
	}

	var suit Suit
	switch label[1] {
	case 'C':
		suit = Club
	case 'D':
		suit = Diamond
	case 'S':
		suit = Spade
	case 'H':
		suit = Heart
	}

	return Card{Value: value, Suit: suit, OriginDeck: 0}
}

// pullCard searches for a card in the deck and removes it.
// Returns the remaining deck.
func pullCard(deck []Card, target Card) []Card {
	for i, c := range deck {
		if c.Equals(target) {
			return append(deck[:i], deck[i+1:]...)
		}
	}
	return deck // not found — shouldn't happen
}

// buildInitialBoard pulls the hard-coded stacks from the deck.
// Mutates the deck slice via pullCard.
func buildInitialBoard(deck *[]Card) []CardStack {
	var stacks []CardStack

	for _, def := range initialBoardDefs {
		var boardCards []BoardCard
		for _, label := range def.labels {
			target := parseLabel(label)
			*deck = pullCard(*deck, target)
			boardCards = append(boardCards, BoardCard{Card: target, State: 0})
		}
		stacks = append(stacks, NewCardStack(boardCards, boardLocation(def.row)))
	}

	return stacks
}

// --- Deal ---

// DealFullGame takes a shuffled deck, sets up the board, deals
// hands, and returns the GameSetup "photo" ready to send over
// the wire.
func DealFullGame(shuffledCards []Card) WireGameSetup {
	deck := make([]Card, len(shuffledCards))
	copy(deck, shuffledCards)

	board := buildInitialBoard(&deck)

	// Deal 15 cards from the front to each player.
	hand1 := deck[:15]
	deck = deck[15:]
	hand2 := deck[:15]
	deck = deck[15:]

	// Convert to wire types.
	wireBoard := make([]WireCardStack, len(board))
	for i, s := range board {
		wbcs := make([]WireBoardCard, len(s.BoardCards))
		for j, bc := range s.BoardCards {
			wbcs[j] = WireBoardCard{
				Card:  WireCard{Value: bc.Card.Value, Suit: int(bc.Card.Suit), OriginDeck: bc.Card.OriginDeck},
				State: bc.State,
			}
		}
		wireBoard[i] = WireCardStack{
			BoardCards: wbcs,
			Loc:        WireLocation{Top: s.Loc.Top, Left: s.Loc.Left},
		}
	}

	toWireCards := func(cards []Card) []WireCard {
		wc := make([]WireCard, len(cards))
		for i, c := range cards {
			wc[i] = WireCard{Value: c.Value, Suit: int(c.Suit), OriginDeck: c.OriginDeck}
		}
		return wc
	}

	return WireGameSetup{
		Board: wireBoard,
		Hands: [2][]WireCard{toWireCards(hand1), toWireCards(hand2)},
		Deck:  toWireCards(deck),
	}
}
