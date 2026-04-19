// Companion helpers for the generated dsl_conformance_test.go.
// This file is hand-edited (the generator deliberately leaves
// these primitives out so tests can be authored without forcing
// the generator to know about every comparison shape).

package tricks

import (
	"strings"

	lr "angry-gopher/games/lynrummy"
)

// stringsContainsDSL matches the generator's error-message
// substring check. A thin wrapper keeps the test output readable
// and avoids importing strings in every generated test body.
func stringsContainsDSL(haystack, needle string) bool {
	return strings.Contains(haystack, needle)
}

// handsEqualDSL compares two lists of HandCards by the `Card`
// identity only (value / suit / origin_deck). State isn't part
// of the DSL scenario grammar, so comparing state here would
// make the tests over-specify.
func handsEqualDSL(a, b []lr.HandCard) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Card != b[i].Card {
			return false
		}
	}
	return true
}

// rawCardsEqualDSL compares two lists of raw Cards (value / suit
// / origin_deck). Used by build_suggestions scenarios where the
// expected hand cards are emitted as plain Cards rather than
// HandCards.
func rawCardsEqualDSL(a, b []lr.Card) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// boardsEqualDSL compares two board snapshots: same length,
// same locations in order, same cards in order (identity = value
// + suit + origin_deck). Re-implemented here rather than calling
// the package-private `lynrummy.stacksEqual` because tests live
// in a sibling package.
func boardsEqualDSL(a, b []lr.CardStack) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Loc != b[i].Loc {
			return false
		}
		if len(a[i].BoardCards) != len(b[i].BoardCards) {
			return false
		}
		for j := range a[i].BoardCards {
			if a[i].BoardCards[j].Card != b[i].BoardCards[j].Card {
				return false
			}
		}
	}
	return true
}
