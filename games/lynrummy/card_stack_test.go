package lynrummy

import (
	"encoding/json"
	"testing"
)

// Regression: maybeMerge must accept 2-card Incomplete results.
//
// The bug: my initial Go port rejected Incomplete in maybeMerge
// alongside Bogus and Dup. That broke direct_play's "extend a
// loose 1-card stack" case — the merged result is a valid 2-card
// partial group that the player will flesh out later.
//
// TS and Elm both accept Incomplete merges; the referee's
// semantics check runs only at turn boundaries
// (ValidateTurnComplete), so 2-card stacks are fine mid-turn.
//
// Why it slipped through the fixture set: every authored fixture
// used ≥3-card merges (happy paths that immediately form complete
// groups). None exercised the loose-drop-then-extend gesture, so
// no fixture produced an Incomplete merge. The bug was invisible
// until live-game data from Steve's "Second Try" surfaced it.
//
// This test locks in the correct behavior: a singleton + a
// singleton merging into a 2-card Incomplete stack must succeed.
func TestMaybeMergeAcceptsTwoCardIncomplete(t *testing.T) {
	loneFive := NewCardStack([]BoardCard{
		{Card: Card{Value: 5, Suit: Heart, OriginDeck: 0}, State: FirmlyOnBoard},
	}, Location{Top: 10, Left: 50})

	singleSix := NewCardStack([]BoardCard{
		{Card: Card{Value: 6, Suit: Heart, OriginDeck: 0}, State: FreshlyPlayed},
	}, Location{Top: 0, Left: 0})

	merged := loneFive.RightMerge(singleSix)
	if merged == nil {
		t.Fatal("right_merge returned nil; expected successful 2-card Incomplete merge")
	}
	if merged.Size() != 2 {
		t.Fatalf("expected size 2, got %d", merged.Size())
	}
	if merged.Type() != Incomplete {
		t.Fatalf("expected Incomplete stack type, got %s", merged.Type())
	}
}

// Regression: Location.UnmarshalJSON accepts fractional pixel
// coordinates.
//
// The bug: Go's Location had `Top int` / `Left int`. Cat's
// drag-and-drop UI sends floats like 401.9333190917969 (from
// getBoundingClientRect + drag offsets). encoding/json refused
// to coerce, returning an error on every move event that touched
// a dragged stack. ParseMoveEvent silently returned nil,
// retroactive trick detection never fired.
//
// Why it slipped through the fixture set: every authored fixture
// used integer coords (from the dealer's hard-coded initial
// board). No fixture exercised the browser-produced wire shape.
// The pitfall is general — see feedback_browser_fractional_pixels
// in the memory index.
//
// This test locks in the correct behavior: a JSON loc with
// fractional values must decode to int via truncation.
func TestLocationUnmarshalAcceptsFractional(t *testing.T) {
	data := []byte(`{"top": 153.2000123, "left": 401.9333190917969}`)
	var loc Location
	if err := json.Unmarshal(data, &loc); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if loc.Top != 153 {
		t.Errorf("Top: got %d, want 153", loc.Top)
	}
	if loc.Left != 401 {
		t.Errorf("Left: got %d, want 401", loc.Left)
	}

	// Integer coords still work (backward compat).
	data2 := []byte(`{"top": 10, "left": 20}`)
	var loc2 Location
	if err := json.Unmarshal(data2, &loc2); err != nil {
		t.Fatalf("int unmarshal failed: %v", err)
	}
	if loc2.Top != 10 || loc2.Left != 20 {
		t.Errorf("int path broken: got (%d, %d)", loc2.Top, loc2.Left)
	}
}

// Regression: a CardStack with fractional loc round-trips through
// JSON (via custom UnmarshalJSON) and behaves correctly.
//
// End-to-end coverage: parse a wire-format stack with float loc,
// verify the domain CardStack is usable by merge operations.
func TestCardStackJSONWithFractionalLoc(t *testing.T) {
	data := []byte(`{
		"board_cards": [
			{"card": {"value": 7, "suit": 3, "origin_deck": 0}, "state": 0}
		],
		"loc": {"top": 153.2000, "left": 401.9333}
	}`)
	var s CardStack
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if s.Loc.Top != 153 || s.Loc.Left != 401 {
		t.Fatalf("loc: got (%d, %d), want (153, 401)", s.Loc.Top, s.Loc.Left)
	}
	// Merge still works on a stack decoded from fractional loc.
	other := NewCardStack([]BoardCard{
		{Card: Card{Value: 8, Suit: Heart, OriginDeck: 0}, State: FreshlyPlayed},
	}, Location{Top: 0, Left: 0})
	merged := s.RightMerge(other)
	if merged == nil {
		t.Fatal("RightMerge on fractional-loc-decoded stack returned nil")
	}
}
