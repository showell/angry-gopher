// Stack-type classification — given a list of cards, what kind of
// group (if any) do they form? Mirrors elm-lynrummy's StackType.elm.
//
// Elm uses a custom sum type for StackType; Go uses `type StackType
// string` for cheap debuggability at the cost of exhaustiveness
// checks. The string values match Elm's tag names in lowercase
// where sensible.

package lynrummy

type StackType string

const (
	Incomplete  StackType = "incomplete"
	Bogus       StackType = "bogus"
	Dup         StackType = "dup"
	Set         StackType = "set"
	PureRun     StackType = "pure run"
	RedBlackRun StackType = "red/black alternating"
)

func successor(val int) int {
	// K wraps to A, A goes to 2.
	if val == 13 {
		return 1
	}
	return val + 1
}

func cardPairType(c1, c2 Card) StackType {
	if c1.IsDup(c2) {
		return Dup
	}
	if c1.Value == c2.Value {
		return Set
	}
	if c2.Value == successor(c1.Value) {
		if c1.Suit == c2.Suit {
			return PureRun
		}
		if SuitColor(c1.Suit) != SuitColor(c2.Suit) {
			return RedBlackRun
		}
	}
	return Bogus
}

func hasDuplicateCards(cards []Card) bool {
	for i := 0; i < len(cards); i++ {
		for j := i + 1; j < len(cards); j++ {
			if cards[i].IsDup(cards[j]) {
				return true
			}
		}
	}
	return false
}

func followsConsistentPattern(cards []Card, st StackType) bool {
	for i := 0; i < len(cards)-1; i++ {
		if cardPairType(cards[i], cards[i+1]) != st {
			return false
		}
	}
	return true
}

// GetStackType determines the type of a card group.
// This is the most important function of the game.
func GetStackType(cards []Card) StackType {
	if len(cards) <= 1 {
		return Incomplete
	}

	provisional := cardPairType(cards[0], cards[1])

	if provisional == Bogus {
		return Bogus
	}
	if provisional == Dup {
		return Dup
	}
	if len(cards) == 2 {
		return Incomplete
	}

	if provisional == Set {
		if hasDuplicateCards(cards) {
			return Dup
		}
	}

	if !followsConsistentPattern(cards, provisional) {
		return Bogus
	}

	return provisional
}
