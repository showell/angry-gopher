// Stack types, card state enums, and stack operations. Mirrors
// elm-lynrummy's CardStack.elm module.
//
// Owns: Location, BoardCardState, HandCardState, BoardCard,
// HandCard, CardStack, merge operations, FromHandCard constructor,
// and the shared card-display width constant.
//
// JSON shape matches Elm's encoder/decoder output. BoardCard,
// HandCard, and Location use struct tags directly; CardStack has
// custom JSON methods because it carries a cached stackType field
// that must be re-derived on unmarshal.

package lynrummy

import "encoding/json"

// CardWidth is the on-board visual width of a single card in
// pixels. Elm exports `cardWidth` from CardStack.elm; Go mirrors
// that placement.
const CardWidth = 27

// --- State enums ---

type BoardCardState int

const (
	FirmlyOnBoard             BoardCardState = 0
	FreshlyPlayed             BoardCardState = 1
	FreshlyPlayedByLastPlayer BoardCardState = 2
)

type HandCardState int

const (
	HandNormal    HandCardState = 0
	FreshlyDrawn  HandCardState = 1
	BackFromBoard HandCardState = 2
)

// --- Primitive types ---

type Location struct {
	Top  int `json:"top"`
	Left int `json:"left"`
}

// UnmarshalJSON accepts either integer or floating-point
// coordinates on the wire. Cat's drag-and-drop UI sends floats
// (e.g. 401.9333190917969); the dealer and the referee work in
// ints. Truncating on decode mirrors what the referee's geometry
// check would treat them as anyway.
func (l *Location) UnmarshalJSON(data []byte) error {
	var raw struct {
		Top  float64 `json:"top"`
		Left float64 `json:"left"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	l.Top = int(raw.Top)
	l.Left = int(raw.Left)
	return nil
}

type BoardCard struct {
	Card  Card           `json:"card"`
	State BoardCardState `json:"state"`
}

type HandCard struct {
	Card  Card          `json:"card"`
	State HandCardState `json:"state"`
}

// --- CardStack ---

type CardStack struct {
	BoardCards []BoardCard
	Loc        Location
	stackType  StackType // cached; re-derived on construction
}

func NewCardStack(cards []BoardCard, loc Location) CardStack {
	raw := make([]Card, len(cards))
	for i, bc := range cards {
		raw[i] = bc.Card
	}
	return CardStack{
		BoardCards: cards,
		Loc:        loc,
		stackType:  GetStackType(raw),
	}
}

// FromHandCard builds a singleton stack at `loc` containing the
// hand card's Card as a freshly-played BoardCard. Mirrors Elm's
// CardStack.fromHandCard.
func FromHandCard(hc HandCard, loc Location) CardStack {
	return NewCardStack(
		[]BoardCard{{Card: hc.Card, State: FreshlyPlayed}},
		loc,
	)
}

func (s CardStack) Type() StackType {
	return s.stackType
}

func (s CardStack) Cards() []Card {
	cards := make([]Card, len(s.BoardCards))
	for i, bc := range s.BoardCards {
		cards[i] = bc.Card
	}
	return cards
}

func (s CardStack) Size() int {
	return len(s.BoardCards)
}

// Contains reports whether the stack holds the given card
// (by Card.Equals, ignoring per-card BoardCardState).
func (s CardStack) Contains(c Card) bool {
	for _, bc := range s.BoardCards {
		if bc.Card.Equals(c) {
			return true
		}
	}
	return false
}

// Equals compares two CardStacks: same loc AND same cards as
// a **multiset** (card-order-independent). Mirrors Elm's
// `CardStack.stacksEqual`. BoardCard state (per-card "recency"
// markers) is ignored — identity is about the cards present,
// not turn-accounting.
//
// Multiset rather than sequence equality so two clients that
// independently form the same logical group in different card
// orders still read as the same stack. See
// `games/lynrummy/WIRE.md`.
func (s CardStack) Equals(other CardStack) bool {
	if s.Loc != other.Loc {
		return false
	}
	return cardsEqualMultiset(s.BoardCards, other.BoardCards)
}

// stacksEqual compares card contents only (ignoring location).
// Used inside merge to prevent merging a stack with a same-card
// pile. Mirrors Elm's CardStack.stacksEqual.
func stacksEqual(a, b CardStack) bool {
	return cardsEqualMultiset(a.BoardCards, b.BoardCards)
}

// cardsEqualMultiset returns true when the two BoardCard
// slices carry the same cards regardless of order. Ignores
// per-card BoardCardState.
func cardsEqualMultiset(a, b []BoardCard) bool {
	if len(a) != len(b) {
		return false
	}
	counts := map[Card]int{}
	for _, bc := range a {
		counts[bc.Card]++
	}
	for _, bc := range b {
		counts[bc.Card]--
		if counts[bc.Card] < 0 {
			return false
		}
	}
	return true
}

func (s CardStack) Str() string {
	result := ""
	for i, bc := range s.BoardCards {
		if i > 0 {
			result += " "
		}
		result += bc.Card.Str()
	}
	return result
}

// --- JSON ---
//
// CardStack's on-wire shape is {board_cards, loc}. We drop the
// cached stackType when marshaling and rebuild it via NewCardStack
// when unmarshaling.

type cardStackJSON struct {
	BoardCards []BoardCard `json:"board_cards"`
	Loc        Location    `json:"loc"`
}

func (s CardStack) MarshalJSON() ([]byte, error) {
	return json.Marshal(cardStackJSON{
		BoardCards: s.BoardCards,
		Loc:        s.Loc,
	})
}

func (s *CardStack) UnmarshalJSON(data []byte) error {
	var raw cardStackJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*s = NewCardStack(raw.BoardCards, raw.Loc)
	return nil
}

// CanExtract reports whether the card at `cardIdx` in this stack
// can be legally extracted by a trick:
//   - End peel: first/last card of a 4+ stack (any stack type).
//   - Set peel: any card in a 4+ SET.
//   - Middle peel: card in a run where both halves would be 3+.
//
// Mirrors TS's `can_extract` from core/board_physics.ts.
func (s CardStack) CanExtract(cardIdx int) bool {
	size := s.Size()
	st := s.Type()

	if st == Set {
		return size >= 4
	}
	if st != PureRun && st != RedBlackRun {
		return false
	}
	if size >= 4 && (cardIdx == 0 || cardIdx == size-1) {
		return true
	}
	if cardIdx >= 3 && (size-cardIdx-1) >= 3 {
		return true
	}
	return false
}

// --- Merge ---

// maybeMerge attempts to merge s1 and s2 at loc. Returns nil if the
// result would be Bogus or Dup, or if the stacks are card-equal.
// Incomplete (2-card) results ARE allowed — mid-turn boards
// legitimately contain 2-card stacks en route to a run or set.
// Mirrors TS's CardStack.maybe_merge / Elm's problematic check.
func maybeMerge(s1, s2 CardStack, loc Location) *CardStack {
	if stacksEqual(s1, s2) {
		return nil
	}
	merged := NewCardStack(
		append(append([]BoardCard{}, s1.BoardCards...), s2.BoardCards...),
		loc,
	)
	switch merged.Type() {
	case Bogus, Dup:
		return nil
	}
	return &merged
}

// LeftMerge attempts to merge `other` onto the LEFT of `s`. The
// resulting stack sits at a location offset left by other.size *
// pitch. Mirrors Elm's CardStack.leftMerge.
func (s CardStack) LeftMerge(other CardStack) *CardStack {
	loc := Location{
		Left: s.Loc.Left - (CardWidth+6)*other.Size(),
		Top:  s.Loc.Top,
	}
	return maybeMerge(other, s, loc)
}

// RightMerge attempts to merge `other` onto the RIGHT of `s`. The
// resulting stack keeps `s`'s location. Mirrors Elm's
// CardStack.rightMerge.
func (s CardStack) RightMerge(other CardStack) *CardStack {
	return maybeMerge(s, other, s.Loc)
}

// Split divides `s` at `cardIndex` into two stacks. If `s` has
// one card, returns a single-element list (caller can detect
// no-op). Mirrors Elm's CardStack.split.
func (s CardStack) Split(cardIndex int) []CardStack {
	if s.Size() <= 1 {
		return []CardStack{s}
	}
	if cardIndex+1 <= s.Size()/2 {
		return leftSplit(cardIndex+1, s)
	}
	return rightSplit(cardIndex, s)
}

func leftSplit(leftCount int, s CardStack) []CardStack {
	leftCards := append([]BoardCard{}, s.BoardCards[:leftCount]...)
	rightCards := append([]BoardCard{}, s.BoardCards[leftCount:]...)
	pitch := CardWidth + 6
	return []CardStack{
		NewCardStack(leftCards, Location{Top: s.Loc.Top - 4, Left: s.Loc.Left - 2}),
		NewCardStack(rightCards, Location{Top: s.Loc.Top, Left: s.Loc.Left + leftCount*pitch + 8}),
	}
}

func rightSplit(leftCount int, s CardStack) []CardStack {
	leftCards := append([]BoardCard{}, s.BoardCards[:leftCount]...)
	rightCards := append([]BoardCard{}, s.BoardCards[leftCount:]...)
	pitch := CardWidth + 6
	return []CardStack{
		NewCardStack(leftCards, Location{Top: s.Loc.Top, Left: s.Loc.Left - 8}),
		NewCardStack(rightCards, Location{Top: s.Loc.Top - 4, Left: s.Loc.Left + leftCount*pitch + 4}),
	}
}
