// Hand-written helpers for the DSL-generated conformance tests.
// Separate file so the generator can safely overwrite its own
// output without touching these.

package tricks

import (
	"encoding/json"
	"strings"

	"angry-gopher/lynrummy"
)

// handsEqualDSL compares two HandCard lists by serializing both
// and byte-comparing. Uses the domain types' own Marshal rules,
// so any difference — card value, suit, deck, state — shows up.
func handsEqualDSL(a, b []lynrummy.HandCard) bool {
	return jsonEqualDSL(a, b)
}

// boardsEqualDSL compares two CardStack lists likewise.
func boardsEqualDSL(a, b []lynrummy.CardStack) bool {
	return jsonEqualDSL(a, b)
}

func jsonEqualDSL(a, b interface{}) bool {
	ab, err := json.Marshal(a)
	if err != nil {
		return false
	}
	bb, err := json.Marshal(b)
	if err != nil {
		return false
	}
	return string(ab) == string(bb)
}

// stringsContainsDSL is an alias so the emitter doesn't have to
// import "strings" into every generated file.
func stringsContainsDSL(s, substr string) bool {
	return strings.Contains(s, substr)
}
