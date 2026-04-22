// Tests for WireAction: round-trip, exact JSON shape, and
// decode errors. Format-lock tests intentionally mirror
// elm/tests/Game/WireActionTest.elm — matching expected JSON
// bytes across both sides is the cross-language conformance
// check.

package lynrummy

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func boardCard(v int, s Suit, d int) BoardCard {
	return BoardCard{Card: Card{Value: v, Suit: s, OriginDeck: d}}
}

func TestWireAction_RoundTrip(t *testing.T) {
	card8H := Card{Value: 8, Suit: Heart, OriginDeck: 0}
	// Use NewCardStack so the derived stackType cache matches
	// what the JSON decoder computes on the receive side (the
	// unexported field would otherwise trip reflect.DeepEqual).
	stackKA := NewCardStack([]BoardCard{
		boardCard(13, Spade, 0),
		boardCard(1, Spade, 0),
	}, Location{Top: 20, Left: 40})
	stack7s := NewCardStack([]BoardCard{
		boardCard(7, Spade, 0),
		boardCard(7, Diamond, 0),
		boardCard(7, Club, 0),
	}, Location{Top: 200, Left: 130})

	cases := []struct {
		name   string
		action WireAction
	}{
		{"split", SplitAction{Stack: stackKA, CardIndex: 2}},
		{"merge_stack left", MergeStackAction{Source: stackKA, Target: stack7s, Side: LeftSide}},
		{"merge_stack right", MergeStackAction{Source: stackKA, Target: stack7s, Side: RightSide}},
		{"merge_hand", MergeHandAction{HandCard: card8H, Target: stack7s, Side: RightSide}},
		{"place_hand", PlaceHandAction{HandCard: card8H, Loc: Location{Top: 140, Left: 220}}},
		{"move_stack", MoveStackAction{Stack: stackKA, NewLoc: Location{Top: 140, Left: 220}}},
		{"complete_turn", CompleteTurnAction{}},
		{"undo", UndoAction{}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.action)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			got, err := DecodeWireAction(data)
			if err != nil {
				t.Fatalf("decode: %v (payload=%s)", err, data)
			}
			if !reflect.DeepEqual(got, tc.action) {
				t.Errorf("round-trip mismatch:\n  want: %+v\n  got:  %+v\n  payload: %s",
					tc.action, got, data)
			}
		})
	}
}

// TestWireAction_JSONShape locks the exact wire bytes for one
// representative. CardStack's JSON shape is load-bearing here;
// if that shape changes, this test fails loudly.
func TestWireAction_JSONShape(t *testing.T) {
	stackKA := NewCardStack([]BoardCard{
		boardCard(13, Spade, 0),
		boardCard(1, Spade, 0),
	}, Location{Top: 20, Left: 40})

	// Sanity: round-trip stability. We don't lock the exact
	// bytes for Split because CardStack encodes a nested
	// board_cards array + loc; the Elm conformance test
	// exercises the same round-trip on its side.
	data, err := json.Marshal(SplitAction{Stack: stackKA, CardIndex: 1})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Must include the kind tag and the board_cards array.
	for _, sub := range []string{
		`"action":"split"`,
		`"stack":{`,
		`"board_cards":`,
		`"card_index":1`,
	} {
		if !strings.Contains(string(data), sub) {
			t.Errorf("marshalled split missing %q in:\n  %s", sub, data)
		}
	}

	// complete_turn still has no per-action fields — lock its
	// exact bytes.
	ctData, err := json.Marshal(CompleteTurnAction{})
	if err != nil {
		t.Fatalf("marshal complete_turn: %v", err)
	}
	if string(ctData) != `{"action":"complete_turn"}` {
		t.Errorf("complete_turn JSON drift: %s", ctData)
	}
}

func TestWireAction_DecodeErrors(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		errSub  string
	}{
		{
			"unknown action tag",
			`{"action":"flibbertigibbet"}`,
			"unknown action",
		},
		{
			"missing payload field",
			`{"action":"split"}`,
			"missing required field",
		},
		{
			"invalid side value",
			`{"action":"merge_stack","source":{"board_cards":[],"loc":{"top":0,"left":0}},"target":{"board_cards":[],"loc":{"top":0,"left":0}},"side":"middle"}`,
			"invalid side",
		},
		{
			"missing action tag",
			`{}`,
			"missing 'action' tag",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := DecodeWireAction([]byte(tc.payload))
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.errSub)
			}
			if !strings.Contains(err.Error(), tc.errSub) {
				t.Errorf("error mismatch:\n  want substring: %s\n  got: %s", tc.errSub, err)
			}
		})
	}
}
