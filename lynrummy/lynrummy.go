// Package lynrummy implements the LynRummy game referee.
//
// The referee is stateless. You show it the board and the proposed
// move, it gives a ruling. It does not remember prior moves. It
// does not care who is playing or how many players there are.
//
// Two entry points:
//
//   ValidateGameMove — rule on a single move during a turn.
//   ValidateTurnComplete — rule on whether the turn can end.
//
// The referee does not enforce turn order, player identity, or
// how many moves per turn. Those are social rules, not physics.
package lynrummy

import "fmt"

// --- Card types ---

type Suit int

const (
	Club    Suit = 0
	Diamond Suit = 1
	Spade   Suit = 2
	Heart   Suit = 3
)

type CardColor int

const (
	Black CardColor = 0
	Red   CardColor = 1
)

func SuitColor(s Suit) CardColor {
	switch s {
	case Club, Spade:
		return Black
	default:
		return Red
	}
}

type Card struct {
	Value      int  // 1=Ace through 13=King
	Suit       Suit
	OriginDeck int // 0 or 1 (double deck)
}

func (c Card) Equals(other Card) bool {
	return c.Value == other.Value &&
		c.Suit == other.Suit &&
		c.OriginDeck == other.OriginDeck
}

func (c Card) IsDup(other Card) bool {
	// Same value and suit, possibly different deck.
	return c.Value == other.Value && c.Suit == other.Suit
}

func (c Card) Str() string {
	v := valueStr(c.Value)
	s := suitStr(c.Suit)
	return v + s
}

func valueStr(v int) string {
	switch v {
	case 1:
		return "A"
	case 10:
		return "T"
	case 11:
		return "J"
	case 12:
		return "Q"
	case 13:
		return "K"
	default:
		return fmt.Sprintf("%d", v)
	}
}

func suitStr(s Suit) string {
	switch s {
	case Club:
		return "C"
	case Diamond:
		return "D"
	case Spade:
		return "S"
	case Heart:
		return "H"
	default:
		return "?"
	}
}

// --- Stack types ---

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

// --- Board types ---

type Location struct {
	Top  int
	Left int
}

type BoardCard struct {
	Card  Card
	State int // 0=firmly, 1=freshly played, 2=played by last player
}

type CardStack struct {
	BoardCards []BoardCard
	Loc        Location
	stackType  StackType // cached
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

func (s CardStack) Equals(other CardStack) bool {
	if s.Loc != other.Loc {
		return false
	}
	if len(s.BoardCards) != len(other.BoardCards) {
		return false
	}
	for i := range s.BoardCards {
		if !s.BoardCards[i].Card.Equals(other.BoardCards[i].Card) {
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

// --- Geometry ---

const (
	CardWidth  = 27
	CardHeight = 40
	CardPitch  = CardWidth + 6
)

type BoardBounds struct {
	MaxWidth  int
	MaxHeight int
	Margin    int // minimum gap between stacks
}

type rect struct {
	left, top, right, bottom int
}

func stackRect(s CardStack) rect {
	w := CardWidth
	if s.Size() > 1 {
		w = CardWidth + (s.Size()-1)*CardPitch
	}
	return rect{
		left:   s.Loc.Left,
		top:    s.Loc.Top,
		right:  s.Loc.Left + w,
		bottom: s.Loc.Top + CardHeight,
	}
}

func rectsOverlap(a, b rect) bool {
	return a.left < b.right &&
		a.right > b.left &&
		a.top < b.bottom &&
		a.bottom > b.top
}

func checkGeometry(board []CardStack, bounds BoardBounds) *RefereeError {
	for i, s := range board {
		r := stackRect(s)
		if r.left < 0 || r.top < 0 || r.right > bounds.MaxWidth || r.bottom > bounds.MaxHeight {
			return &RefereeError{
				Stage:   "geometry",
				Message: fmt.Sprintf("stack %d out of bounds", i),
			}
		}
	}

	for i := 0; i < len(board); i++ {
		for j := i + 1; j < len(board); j++ {
			if rectsOverlap(stackRect(board[i]), stackRect(board[j])) {
				return &RefereeError{
					Stage:   "geometry",
					Message: fmt.Sprintf("stacks %d and %d overlap", i, j),
				}
			}
		}
	}

	return nil
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
	// Build a pool of available cards: removed stacks + hand.
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

	// Every added card must consume one from the pool.
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

	// Hand cards declared but never placed.
	for _, c := range handCards {
		if findCardInPool(pool, c) >= 0 {
			return &RefereeError{
				Stage:   "inventory",
				Message: "hand card " + c.Str() + " was declared played but not placed on the board",
			}
		}
	}

	// No duplicate cards on the resulting board.
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

// --- Entry points ---

// ValidateGameMove rules on a single move during a turn.
// Returns nil if the move is valid.
func ValidateGameMove(move Move, bounds BoardBounds) *RefereeError {
	// Stage 1: Protocol.
	if err := checkProtocol(move); err != nil {
		return err
	}

	// Compute the resulting board.
	boardAfter, err := computeBoardAfter(move)
	if err != nil {
		return err
	}

	// Stage 2: Geometry.
	if err := checkGeometry(boardAfter, bounds); err != nil {
		return err
	}

	// Stage 3: Semantics.
	if err := checkSemantics(boardAfter); err != nil {
		return err
	}

	// Stage 4: Inventory.
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
