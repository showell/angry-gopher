// Package lynrummy implements the LynRummy game referee.
//
// The referee is stateless. You show it the board and the proposed
// move, it gives a ruling. It does not remember prior moves. It
// does not care who is playing or how many players there are.
//
// Two entry points:
//
//	ValidateGameMove — rule on a single move during a turn.
//	ValidateTurnComplete — rule on whether the turn can end.
//
// The referee does not enforce turn order, player identity, or
// how many moves per turn. Those are social rules, not physics.
//
// Mirrors elm-lynrummy's Referee.elm module.

package lynrummy

import "fmt"

// --- Public types ---

type RefereeError struct {
	Stage   string // "protocol", "geometry", "semantics", "inventory"
	Message string
}

func (e RefereeError) Error() string {
	return e.Stage + ": " + e.Message
}

type Move struct {
	BoardBefore     []CardStack
	StacksToRemove  []CardStack
	StacksToAdd     []CardStack
	HandCardsPlayed []Card // optional — omit for pure rearrangements
}

// --- Protocol validation ---

func checkProtocol(move Move) *RefereeError {
	for i, s := range move.StacksToRemove {
		if err := validateStack(s, fmt.Sprintf("stacks_to_remove[%d]", i)); err != nil {
			return err
		}
	}
	for i, s := range move.StacksToAdd {
		if err := validateStack(s, fmt.Sprintf("stacks_to_add[%d]", i)); err != nil {
			return err
		}
	}
	return nil
}

func validateStack(s CardStack, path string) *RefereeError {
	if len(s.BoardCards) == 0 {
		return &RefereeError{
			Stage:   "protocol",
			Message: fmt.Sprintf("%s: stack has no cards", path),
		}
	}
	for i, bc := range s.BoardCards {
		if err := validateCard(bc.Card, fmt.Sprintf("%s.board_cards[%d]", path, i)); err != nil {
			return err
		}
	}
	return nil
}

func validateCard(c Card, path string) *RefereeError {
	if c.Value < 1 || c.Value > 13 {
		return &RefereeError{
			Stage:   "protocol",
			Message: fmt.Sprintf("%s: invalid value %d", path, c.Value),
		}
	}
	if c.Suit < 0 || c.Suit > 3 {
		return &RefereeError{
			Stage:   "protocol",
			Message: fmt.Sprintf("%s: invalid suit %d", path, c.Suit),
		}
	}
	if c.OriginDeck != 0 && c.OriginDeck != 1 {
		return &RefereeError{
			Stage:   "protocol",
			Message: fmt.Sprintf("%s: invalid origin_deck %d", path, c.OriginDeck),
		}
	}
	return nil
}

// --- Semantics ---

func checkSemantics(board []CardStack) *RefereeError {
	for _, s := range board {
		st := s.Type()
		if st == Incomplete || st == Bogus || st == Dup {
			return &RefereeError{
				Stage:   "semantics",
				Message: fmt.Sprintf("stack \"%s\" is %s", s.Str(), st),
			}
		}
	}
	return nil
}

// --- Inventory ---

func checkInventory(move Move, boardAfter []CardStack) *RefereeError {
	var pool []Card

	for _, s := range move.StacksToRemove {
		for _, bc := range s.BoardCards {
			pool = append(pool, bc.Card)
		}
	}

	var handCards []Card
	for _, hc := range move.HandCardsPlayed {
		handCards = append(handCards, hc)
		pool = append(pool, hc)
	}

	for _, s := range move.StacksToAdd {
		for _, bc := range s.BoardCards {
			idx := findCardInPool(pool, bc.Card)
			if idx < 0 {
				return &RefereeError{
					Stage:   "inventory",
					Message: "card " + bc.Card.Str() + " appeared on the board with no source",
				}
			}
			pool = append(pool[:idx], pool[idx+1:]...)
		}
	}

	for _, c := range handCards {
		if findCardInPool(pool, c) >= 0 {
			return &RefereeError{
				Stage:   "inventory",
				Message: "hand card " + c.Str() + " was declared played but not placed on the board",
			}
		}
	}

	allCards := collectBoardCards(boardAfter)
	if dup := findFirstDuplicate(allCards); dup != nil {
		return &RefereeError{
			Stage:   "inventory",
			Message: "duplicate card on board: " + dup.Str(),
		}
	}

	return nil
}

func findCardInPool(pool []Card, target Card) int {
	for i, c := range pool {
		if c.Equals(target) {
			return i
		}
	}
	return -1
}

func collectBoardCards(board []CardStack) []Card {
	var cards []Card
	for _, s := range board {
		for _, bc := range s.BoardCards {
			cards = append(cards, bc.Card)
		}
	}
	return cards
}

func findFirstDuplicate(cards []Card) *Card {
	for i := 0; i < len(cards); i++ {
		for j := i + 1; j < len(cards); j++ {
			if cards[i].Equals(cards[j]) {
				c := cards[i]
				return &c
			}
		}
	}
	return nil
}

// --- Compute resulting board ---

func computeBoardAfter(move Move) ([]CardStack, *RefereeError) {
	toRemove := make([]CardStack, len(move.StacksToRemove))
	copy(toRemove, move.StacksToRemove)

	var remaining []CardStack
	for _, s := range move.BoardBefore {
		idx := findMatchingStack(toRemove, s)
		if idx >= 0 {
			toRemove = append(toRemove[:idx], toRemove[idx+1:]...)
		} else {
			remaining = append(remaining, s)
		}
	}

	if len(toRemove) > 0 {
		return nil, &RefereeError{
			Stage:   "inventory",
			Message: "stacks_to_remove contains a stack not on the board",
		}
	}

	boardAfter := append(remaining, move.StacksToAdd...)
	return boardAfter, nil
}

func findMatchingStack(stacks []CardStack, target CardStack) int {
	for i, s := range stacks {
		if s.Equals(target) {
			return i
		}
	}
	return -1
}

// --- Entry points ---

// ValidateGameMove rules on a single move during a turn.
// Returns nil if the move is valid.
//
// Checks protocol and inventory. Geometry is temporarily disabled
// for the console player's learning phase. Semantics are enforced
// at turn boundaries via ValidateTurnComplete.
func ValidateGameMove(move Move, bounds BoardBounds) *RefereeError {
	if err := checkProtocol(move); err != nil {
		return err
	}

	boardAfter, err := computeBoardAfter(move)
	if err != nil {
		return err
	}

	// Geometry temporarily disabled — see referee.go:ValidateGameMove.
	_ = bounds
	// if err := checkGeometry(boardAfter, bounds); err != nil {
	// 	return err
	// }

	if err := checkInventory(move, boardAfter); err != nil {
		return err
	}

	return nil
}

// ValidateTurnComplete rules on whether the turn can end.
// The board must be clean before we hand it off.
// Returns nil if the board is ready.
func ValidateTurnComplete(board []CardStack, bounds BoardBounds) *RefereeError {
	if err := checkGeometry(board, bounds); err != nil {
		return err
	}
	if err := checkSemantics(board); err != nil {
		return err
	}
	return nil
}
