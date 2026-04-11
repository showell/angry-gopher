package lynrummy

import "testing"

func TestBuildDoubleDeck(t *testing.T) {
	deck := BuildDoubleDeck()
	if len(deck) != 104 {
		t.Fatalf("expected 104 cards, got %d", len(deck))
	}

	// Every card should appear exactly twice (once per origin_deck).
	type cardKey struct {
		value int
		suit  Suit
		deck  int
	}
	counts := map[cardKey]int{}
	for _, c := range deck {
		counts[cardKey{c.Value, c.Suit, c.OriginDeck}]++
	}
	if len(counts) != 104 {
		t.Fatalf("expected 104 unique cards, got %d", len(counts))
	}
	for k, v := range counts {
		if v != 1 {
			t.Fatalf("card %v appears %d times", k, v)
		}
	}
}

func TestDealFullGameCardCount(t *testing.T) {
	deck := BuildDoubleDeck()
	setup := DealFullGame(deck)

	// Board cards + hand1 + hand2 + remaining deck = 104.
	boardCards := 0
	for _, s := range setup.Board {
		boardCards += len(s.BoardCards)
	}

	total := boardCards + len(setup.Hands[0]) + len(setup.Hands[1]) + len(setup.Deck)
	if total != 104 {
		t.Fatalf("expected 104 total cards, got %d (board=%d h1=%d h2=%d deck=%d)",
			total, boardCards, len(setup.Hands[0]), len(setup.Hands[1]), len(setup.Deck))
	}
}

func TestDealFullGameBoardStacks(t *testing.T) {
	deck := BuildDoubleDeck()
	setup := DealFullGame(deck)

	if len(setup.Board) != 6 {
		t.Fatalf("expected 6 board stacks, got %d", len(setup.Board))
	}

	// Check board stack sizes match the initial definitions.
	expectedSizes := []int{4, 4, 3, 3, 3, 6}
	for i, s := range setup.Board {
		if len(s.BoardCards) != expectedSizes[i] {
			t.Errorf("stack %d: expected %d cards, got %d", i, expectedSizes[i], len(s.BoardCards))
		}
	}
}

func TestDealFullGameHandSizes(t *testing.T) {
	deck := BuildDoubleDeck()
	setup := DealFullGame(deck)

	if len(setup.Hands[0]) != 15 {
		t.Errorf("hand 1: expected 15 cards, got %d", len(setup.Hands[0]))
	}
	if len(setup.Hands[1]) != 15 {
		t.Errorf("hand 2: expected 15 cards, got %d", len(setup.Hands[1]))
	}
}

func TestDealFullGameBoardLocations(t *testing.T) {
	deck := BuildDoubleDeck()
	setup := DealFullGame(deck)

	// Verify locations match the formula: col = (row*3+1)%5, top = 20+row*60, left = 40+col*30
	for i, s := range setup.Board {
		col := (i*3 + 1) % 5
		expectedTop := 20 + i*60
		expectedLeft := 40 + col*30
		if s.Loc.Top != expectedTop || s.Loc.Left != expectedLeft {
			t.Errorf("stack %d: expected loc (%d,%d), got (%d,%d)",
				i, expectedLeft, expectedTop, s.Loc.Left, s.Loc.Top)
		}
	}
}

func TestDealFullGameBoardCardsAreDeckOne(t *testing.T) {
	deck := BuildDoubleDeck()
	setup := DealFullGame(deck)

	for i, s := range setup.Board {
		for j, bc := range s.BoardCards {
			if bc.Card.OriginDeck != 0 {
				t.Errorf("stack %d card %d: expected origin_deck 0, got %d", i, j, bc.Card.OriginDeck)
			}
		}
	}
}

func TestDealFullGameNoDuplicates(t *testing.T) {
	deck := BuildDoubleDeck()
	setup := DealFullGame(deck)

	// Collect all cards and verify no duplicates.
	type cardKey struct {
		value int
		suit  int
		deck  int
	}
	seen := map[cardKey]bool{}

	check := func(label string, v, s, d int) {
		k := cardKey{v, s, d}
		if seen[k] {
			t.Errorf("duplicate card in %s: value=%d suit=%d deck=%d", label, v, s, d)
		}
		seen[k] = true
	}

	for _, s := range setup.Board {
		for _, bc := range s.BoardCards {
			check("board", bc.Card.Value, bc.Card.Suit, bc.Card.OriginDeck)
		}
	}
	for _, c := range setup.Hands[0] {
		check("hand1", c.Value, c.Suit, c.OriginDeck)
	}
	for _, c := range setup.Hands[1] {
		check("hand2", c.Value, c.Suit, c.OriginDeck)
	}
	for _, c := range setup.Deck {
		check("deck", c.Value, c.Suit, c.OriginDeck)
	}

	if len(seen) != 104 {
		t.Errorf("expected 104 unique cards, got %d", len(seen))
	}
}
