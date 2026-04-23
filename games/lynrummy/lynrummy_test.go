package lynrummy

import "testing"

// --- Helpers ---

var bounds = BoardBounds{MaxWidth: 800, MaxHeight: 600, Margin: 7}

func bc(value int, suit Suit, deck int) BoardCard {
	return BoardCard{Card: Card{Value: value, Suit: suit, OriginDeck: deck}, State: 0}
}

func fresh(value int, suit Suit, deck int) BoardCard {
	return BoardCard{Card: Card{Value: value, Suit: suit, OriginDeck: deck}, State: 1}
}

func stack(loc Location, cards ...BoardCard) CardStack {
	return NewCardStack(cards, loc)
}

func at(top, left int) Location {
	return Location{Top: top, Left: left}
}

// --- GetStackType tests ---

func TestPureRun(t *testing.T) {
	cards := []Card{
		{5, Heart, 0}, {6, Heart, 0}, {7, Heart, 0},
	}
	if st := GetStackType(cards); st != PureRun {
		t.Errorf("expected pure run, got %s", st)
	}
}

func TestRedBlackRun(t *testing.T) {
	cards := []Card{
		{5, Heart, 0}, {6, Spade, 0}, {7, Diamond, 0},
	}
	if st := GetStackType(cards); st != RedBlackRun {
		t.Errorf("expected red/black run, got %s", st)
	}
}

func TestSet(t *testing.T) {
	cards := []Card{
		{7, Club, 0}, {7, Diamond, 0}, {7, Spade, 0},
	}
	if st := GetStackType(cards); st != Set {
		t.Errorf("expected set, got %s", st)
	}
}

func TestWrappingRun(t *testing.T) {
	cards := []Card{
		{12, Heart, 0}, {13, Heart, 0}, {1, Heart, 0},
	}
	if st := GetStackType(cards); st != PureRun {
		t.Errorf("expected pure run for Q-K-A wrap, got %s", st)
	}
}

func TestIncomplete(t *testing.T) {
	cards := []Card{
		{5, Heart, 0}, {6, Heart, 0},
	}
	if st := GetStackType(cards); st != Incomplete {
		t.Errorf("expected incomplete, got %s", st)
	}
}

func TestBogus(t *testing.T) {
	cards := []Card{
		{1, Heart, 0}, {5, Club, 0}, {13, Diamond, 0},
	}
	if st := GetStackType(cards); st != Bogus {
		t.Errorf("expected bogus, got %s", st)
	}
}

func TestDupSet(t *testing.T) {
	cards := []Card{
		{7, Heart, 0}, {7, Heart, 1}, {7, Club, 0},
	}
	if st := GetStackType(cards); st != Dup {
		t.Errorf("expected dup, got %s", st)
	}
}

func TestSingleCard(t *testing.T) {
	cards := []Card{{5, Heart, 0}}
	if st := GetStackType(cards); st != Incomplete {
		t.Errorf("expected incomplete, got %s", st)
	}
}

// --- ValidateGameMove tests ---

func TestValidGameSequence(t *testing.T) {
	run := stack(at(10, 10),
		bc(5, Heart, 0), bc(6, Heart, 0), bc(7, Heart, 0))
	set := stack(at(10, 200),
		bc(13, Club, 0), bc(13, Diamond, 0), bc(13, Spade, 0))

	board := []CardStack{run, set}

	// Move 1: extend run with 8H from hand.
	extendedRun := stack(at(10, 10),
		bc(5, Heart, 0), bc(6, Heart, 0), bc(7, Heart, 0), fresh(8, Heart, 0))

	err := ValidateGameMove(Move{
		BoardBefore:     board,
		StacksToRemove:  []CardStack{run},
		StacksToAdd:     []CardStack{extendedRun},
		HandCardsPlayed: []Card{{8, Heart, 0}},
	}, bounds)
	if err != nil {
		t.Fatalf("move 1: %v", err)
	}
	board = []CardStack{extendedRun, set}

	// Move 2: place new 3-card run from hand.
	newRun := stack(at(60, 10),
		fresh(1, Spade, 0), fresh(2, Spade, 0), fresh(3, Spade, 0))

	err = ValidateGameMove(Move{
		BoardBefore:    board,
		StacksToRemove: nil,
		StacksToAdd:    []CardStack{newRun},
		HandCardsPlayed: []Card{
			{1, Spade, 0}, {2, Spade, 0}, {3, Spade, 0},
		},
	}, bounds)
	if err != nil {
		t.Fatalf("move 2: %v", err)
	}
	board = append(board, newRun)

	// Move 3: pure rearrangement — move the set.
	movedSet := stack(at(60, 200), set.BoardCards...)

	err = ValidateGameMove(Move{
		BoardBefore:    board,
		StacksToRemove: []CardStack{set},
		StacksToAdd:    []CardStack{movedSet},
	}, bounds)
	if err != nil {
		t.Fatalf("move 3: %v", err)
	}
}

func TestProtocolRejectsBadCard(t *testing.T) {
	bad := stack(at(10, 10),
		BoardCard{Card: Card{Value: 99, Suit: Heart, OriginDeck: 0}, State: 0},
		BoardCard{Card: Card{Value: 1, Suit: Heart, OriginDeck: 0}, State: 0},
		BoardCard{Card: Card{Value: 2, Suit: Heart, OriginDeck: 0}, State: 0},
	)
	err := ValidateGameMove(Move{
		BoardBefore: nil,
		StacksToAdd: []CardStack{bad},
		HandCardsPlayed: []Card{
			{99, Heart, 0}, {1, Heart, 0}, {2, Heart, 0},
		},
	}, bounds)
	if err == nil || err.Stage != "protocol" {
		t.Fatalf("expected protocol error, got %v", err)
	}
}

func TestGeometryRejectsOverlap(t *testing.T) {
	existing := stack(at(10, 10),
		bc(1, Heart, 0), bc(2, Heart, 0), bc(3, Heart, 0))
	overlapping := stack(at(10, 10),
		fresh(7, Club, 0), fresh(7, Diamond, 0), fresh(7, Spade, 0))

	err := ValidateGameMove(Move{
		BoardBefore: []CardStack{existing},
		StacksToAdd: []CardStack{overlapping},
		HandCardsPlayed: []Card{
			{7, Club, 0}, {7, Diamond, 0}, {7, Spade, 0},
		},
	}, bounds)
	if err == nil || err.Stage != "geometry" {
		t.Fatalf("expected geometry error, got %v", err)
	}
}

func TestGeometryRejectsOutOfBounds(t *testing.T) {
	offBoard := stack(at(10, 900),
		fresh(1, Heart, 0), fresh(2, Heart, 0), fresh(3, Heart, 0))

	err := ValidateGameMove(Move{
		BoardBefore: nil,
		StacksToAdd: []CardStack{offBoard},
		HandCardsPlayed: []Card{
			{1, Heart, 0}, {2, Heart, 0}, {3, Heart, 0},
		},
	}, bounds)
	if err == nil || err.Stage != "geometry" {
		t.Fatalf("expected geometry error, got %v", err)
	}
}

// Mid-turn moves skip semantics — bogus/incomplete stacks are
// allowed. Semantics are enforced at turn boundaries.

func TestMidturnAllowsBogus(t *testing.T) {
	bogus := stack(at(10, 10),
		fresh(1, Heart, 0), fresh(5, Club, 0), fresh(13, Diamond, 0))

	err := ValidateGameMove(Move{
		BoardBefore: nil,
		StacksToAdd: []CardStack{bogus},
		HandCardsPlayed: []Card{
			{1, Heart, 0}, {5, Club, 0}, {13, Diamond, 0},
		},
	}, bounds)
	if err != nil {
		t.Fatalf("mid-turn bogus should be accepted, got %v", err)
	}

	turnErr := ValidateTurnComplete([]CardStack{bogus}, bounds)
	if turnErr == nil || turnErr.Stage != "semantics" {
		t.Fatalf("turn complete should reject bogus, got %v", turnErr)
	}
}

func TestMidturnAllowsIncomplete(t *testing.T) {
	incomplete := stack(at(10, 10),
		fresh(1, Heart, 0), fresh(2, Heart, 0))

	err := ValidateGameMove(Move{
		BoardBefore:     nil,
		StacksToAdd:     []CardStack{incomplete},
		HandCardsPlayed: []Card{{1, Heart, 0}, {2, Heart, 0}},
	}, bounds)
	if err != nil {
		t.Fatalf("mid-turn incomplete should be accepted, got %v", err)
	}

	turnErr := ValidateTurnComplete([]CardStack{incomplete}, bounds)
	if turnErr == nil || turnErr.Stage != "semantics" {
		t.Fatalf("turn complete should reject incomplete, got %v", turnErr)
	}
}

func TestInventoryRejectsCardFromNowhere(t *testing.T) {
	run := stack(at(10, 10),
		fresh(1, Heart, 0), fresh(2, Heart, 0), fresh(3, Heart, 0))

	// Declare only 2 hand cards for a 3-card stack.
	err := ValidateGameMove(Move{
		BoardBefore:     nil,
		StacksToAdd:     []CardStack{run},
		HandCardsPlayed: []Card{{1, Heart, 0}, {2, Heart, 0}},
	}, bounds)
	if err == nil || err.Stage != "inventory" {
		t.Fatalf("expected inventory error, got %v", err)
	}
}

func TestInventoryRejectsUnplacedHandCard(t *testing.T) {
	run := stack(at(10, 10),
		fresh(1, Heart, 0), fresh(2, Heart, 0), fresh(3, Heart, 0))

	// Declare 4 hand cards for a 3-card stack.
	err := ValidateGameMove(Move{
		BoardBefore: nil,
		StacksToAdd: []CardStack{run},
		HandCardsPlayed: []Card{
			{1, Heart, 0}, {2, Heart, 0}, {3, Heart, 0}, {4, Heart, 0},
		},
	}, bounds)
	if err == nil || err.Stage != "inventory" {
		t.Fatalf("expected inventory error, got %v", err)
	}
}

func TestInventoryRejectsBoardDuplicate(t *testing.T) {
	run := stack(at(10, 10),
		bc(1, Heart, 0), bc(2, Heart, 0), bc(3, Heart, 0))

	// Add a set that includes AH — already on the board.
	dupSet := stack(at(60, 10),
		fresh(1, Heart, 0), fresh(1, Club, 0), fresh(1, Diamond, 0))

	err := ValidateGameMove(Move{
		BoardBefore: []CardStack{run},
		StacksToAdd: []CardStack{dupSet},
		HandCardsPlayed: []Card{
			{1, Heart, 0}, {1, Club, 0}, {1, Diamond, 0},
		},
	}, bounds)
	if err == nil || err.Stage != "inventory" {
		t.Fatalf("expected inventory error, got %v", err)
	}
}

func TestInventoryAllowsRearrangement(t *testing.T) {
	longRun := stack(at(10, 10),
		bc(1, Club, 0), bc(2, Club, 0), bc(3, Club, 0),
		bc(4, Club, 0), bc(5, Club, 0), bc(6, Club, 0))

	left := stack(at(10, 10),
		bc(1, Club, 0), bc(2, Club, 0), bc(3, Club, 0))
	right := stack(at(10, 200),
		bc(4, Club, 0), bc(5, Club, 0), bc(6, Club, 0))

	err := ValidateGameMove(Move{
		BoardBefore:    []CardStack{longRun},
		StacksToRemove: []CardStack{longRun},
		StacksToAdd:    []CardStack{left, right},
	}, bounds)
	if err != nil {
		t.Fatalf("expected valid rearrangement: %v", err)
	}
}

func TestInventoryRejectsMissingRemove(t *testing.T) {
	phantom := stack(at(10, 10),
		bc(1, Heart, 0), bc(2, Heart, 0), bc(3, Heart, 0))

	err := ValidateGameMove(Move{
		BoardBefore:    nil,
		StacksToRemove: []CardStack{phantom},
	}, bounds)
	if err == nil || err.Stage != "inventory" {
		t.Fatalf("expected inventory error, got %v", err)
	}
}

// --- ValidateTurnComplete tests ---

func TestTurnCompleteCleanBoard(t *testing.T) {
	run := stack(at(10, 10),
		bc(1, Heart, 0), bc(2, Heart, 0), bc(3, Heart, 0))
	set := stack(at(10, 200),
		bc(13, Club, 0), bc(13, Diamond, 0), bc(13, Spade, 0))

	if err := ValidateTurnComplete([]CardStack{run, set}, bounds); err != nil {
		t.Fatalf("clean board should pass: %v", err)
	}
}

func TestTurnCompleteRejectsIncomplete(t *testing.T) {
	incomplete := stack(at(10, 10),
		bc(1, Heart, 0), bc(2, Heart, 0))

	err := ValidateTurnComplete([]CardStack{incomplete}, bounds)
	if err == nil || err.Stage != "semantics" {
		t.Fatalf("expected semantics error, got %v", err)
	}
}

func TestTurnCompleteRejectsOverlap(t *testing.T) {
	s1 := stack(at(10, 10),
		bc(1, Heart, 0), bc(2, Heart, 0), bc(3, Heart, 0))
	s2 := stack(at(10, 10),
		bc(7, Club, 0), bc(7, Diamond, 0), bc(7, Spade, 0))

	err := ValidateTurnComplete([]CardStack{s1, s2}, bounds)
	if err == nil || err.Stage != "geometry" {
		t.Fatalf("expected geometry error, got %v", err)
	}
}

func TestTurnCompleteEmptyBoard(t *testing.T) {
	if err := ValidateTurnComplete(nil, bounds); err != nil {
		t.Fatalf("empty board should pass: %v", err)
	}
}

// --- Stages are independent ---

func TestStagesAreIndependent(t *testing.T) {
	validRun := stack(at(10, 10),
		bc(1, Club, 0), bc(2, Club, 0), bc(3, Club, 0))

	// Replace with bogus — mid-turn accepts, turn complete rejects.
	bogus := stack(at(10, 10),
		bc(1, Club, 0), fresh(5, Diamond, 0), fresh(13, Heart, 0))

	err := ValidateGameMove(Move{
		BoardBefore:    []CardStack{validRun},
		StacksToRemove: []CardStack{validRun},
		StacksToAdd:    []CardStack{bogus},
		HandCardsPlayed: []Card{
			{5, Diamond, 0}, {13, Heart, 0},
		},
	}, bounds)
	if err != nil {
		t.Fatalf("mid-turn bogus replacement should be accepted, got %v", err)
	}

	turnErr := ValidateTurnComplete([]CardStack{bogus}, bounds)
	if turnErr == nil || turnErr.Stage != "semantics" {
		t.Fatalf("turn complete should reject bogus, got %v", turnErr)
	}
}
