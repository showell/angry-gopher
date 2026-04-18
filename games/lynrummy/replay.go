// Replay primitives: apply a WireAction to a (board, hand) state
// to produce the next state. Mirror of
// elm-port-docs/src/LynRummy/Replay.elm.
//
// This is the server's authoritative state-reconstruction function.
// Given any action log, calling ApplyAction in sequence from
// InitialState produces the game state after those actions. All
// downstream queries (score, hints, turn-state) read from state
// produced this way.
//
// No-op for Draw / Discard / CompleteTurn / Undo — turn-logic
// isn't modeled yet. When it is, they'll get their own transitions
// here.

package lynrummy

import "math/rand"

type State struct {
	Board     []CardStack `json:"board"`
	Hand      Hand        `json:"hand"`
	Deck      []Card      `json:"deck"`
	Discard   []Card      `json:"discard"`
	TurnIndex int         `json:"turn_index"`

	// CardsPlayedThisTurn counts hand cards that left the hand
	// for the board this turn (via PlaceHand, MergeHand). Used to
	// compute the per-turn bonus at CompleteTurn; reset each turn.
	CardsPlayedThisTurn int `json:"cards_played_this_turn"`
}

// InitialState produces the starting state with a deterministic
// (unshuffled) deck. Used by tests and as a fallback when no
// per-session seed exists.
func InitialState() State {
	return InitialStateWithSeed(0)
}

// InitialStateWithSeed produces the starting state for a session
// with the deck shuffled by the given seed. Seed = 0 means
// deterministic (no shuffle); any non-zero seed produces a
// reproducible shuffle. Replays of a session use its stored seed
// so reconstructions always agree.
func InitialStateWithSeed(seed int64) State {
	board := InitialBoard()
	hand := OpeningHand()
	deck := remainingDeckAfter(board, hand)
	if seed != 0 {
		deck = shuffleDeckSeeded(deck, seed)
	}
	return State{
		Board:   board,
		Hand:    hand,
		Deck:    deck,
		Discard: []Card{},
	}
}

// shuffleDeckSeeded returns a copy of deck shuffled with a fixed
// seed. Same seed → same order, every time.
func shuffleDeckSeeded(deck []Card, seed int64) []Card {
	out := append([]Card{}, deck...)
	r := rand.New(rand.NewSource(seed))
	r.Shuffle(len(out), func(i, j int) {
		out[i], out[j] = out[j], out[i]
	})
	return out
}

// remainingDeckAfter = "double deck minus cards in board + hand."
// Used to set up InitialState's draw pile. Uses the deterministic
// unshuffled double deck so repeated state reconstructions see the
// SAME draw order — critical for replay correctness. (Randomness
// per session will come from a server-assigned seed later; for now
// agent-side testing + solo play work cleanly with a fixed order.)
func remainingDeckAfter(board []CardStack, hand Hand) []Card {
	full := BuildDeterministicDoubleDeck()
	used := map[Card]int{}
	for _, s := range board {
		for _, bc := range s.BoardCards {
			used[bc.Card]++
		}
	}
	for _, hc := range hand.HandCards {
		used[hc.Card]++
	}
	deck := make([]Card, 0, len(full))
	for _, c := range full {
		if used[c] > 0 {
			used[c]--
			continue
		}
		deck = append(deck, c)
	}
	return deck
}

// ApplyAction applies a single WireAction to the given state and
// returns the resulting state. Returns the state unchanged if the
// action refers to indices or hand cards that aren't present (the
// same silent-pass-through contract as the Elm side).
func ApplyAction(action WireAction, state State) State {
	switch a := action.(type) {
	case SplitAction:
		return applySplit(a.StackIndex, a.CardIndex, state)

	case MergeStackAction:
		return applyMergeStack(a, state)

	case MergeHandAction:
		return applyMergeHand(a, state)

	case PlaceHandAction:
		return applyPlaceHand(a, state)

	case MoveStackAction:
		return applyMoveStack(a, state)

	case DrawAction:
		return applyDraw(state)

	case DiscardAction:
		return applyDiscard(a, state)

	case CompleteTurnAction:
		return applyCompleteTurn(state)

	case UndoAction:
		// Snapshot-based undo is deferred. For now a no-op so the
		// wire accepts undo events without breaking replay.
		return state

	case PlayTrickAction:
		// The action handler expands PlayTrick to TrickResult at
		// submission time, so this case shouldn't normally fire
		// during replay. If it ever does (old log, raw POST), no-op.
		return state

	case TrickResultAction:
		return applyTrickResult(a, state)
	}
	return state
}

// --- Transition helpers ---
//
// Each helper preserves Deck / Discard / TurnIndex unless it's
// specifically mutating one of them (Draw, Discard, CompleteTurn).
// The plays-per-turn counter bumps on PlaceHand and MergeHand.

func applySplit(stackIdx, cardIdx int, state State) State {
	if stackIdx < 0 || stackIdx >= len(state.Board) {
		return state
	}
	stack := state.Board[stackIdx]
	newStacks := stack.Split(cardIdx)
	newBoard := removeStack(state.Board, stack)
	newBoard = append(newBoard, newStacks...)
	out := state
	out.Board = newBoard
	return out
}

func applyMergeStack(a MergeStackAction, state State) State {
	if a.SourceStack < 0 || a.SourceStack >= len(state.Board) {
		return state
	}
	if a.TargetStack < 0 || a.TargetStack >= len(state.Board) {
		return state
	}
	source := state.Board[a.SourceStack]
	target := state.Board[a.TargetStack]
	var merged *CardStack
	switch a.Side {
	case LeftSide:
		merged = target.LeftMerge(source)
	case RightSide:
		merged = target.RightMerge(source)
	}
	if merged == nil {
		return state
	}
	newBoard := removeStack(state.Board, source)
	newBoard = removeStack(newBoard, target)
	newBoard = append(newBoard, *merged)
	out := state
	out.Board = newBoard
	return out
}

func applyMergeHand(a MergeHandAction, state State) State {
	if a.TargetStack < 0 || a.TargetStack >= len(state.Board) {
		return state
	}
	hc := state.Hand.FindByCard(a.HandCard)
	if hc == nil {
		return state
	}
	target := state.Board[a.TargetStack]
	sourceStack := FromHandCard(*hc, Location{Top: -1, Left: -1})
	var merged *CardStack
	switch a.Side {
	case LeftSide:
		merged = target.LeftMerge(sourceStack)
	case RightSide:
		merged = target.RightMerge(sourceStack)
	}
	if merged == nil {
		return state
	}
	newBoard := removeStack(state.Board, target)
	newBoard = append(newBoard, *merged)
	out := state
	out.Board = newBoard
	out.Hand = state.Hand.RemoveHandCard(*hc)
	out.CardsPlayedThisTurn = state.CardsPlayedThisTurn + 1
	return out
}

func applyPlaceHand(a PlaceHandAction, state State) State {
	hc := state.Hand.FindByCard(a.HandCard)
	if hc == nil {
		return state
	}
	newStack := FromHandCard(*hc, a.Loc)
	newBoard := append([]CardStack{}, state.Board...)
	newBoard = append(newBoard, newStack)
	out := state
	out.Board = newBoard
	out.Hand = state.Hand.RemoveHandCard(*hc)
	out.CardsPlayedThisTurn = state.CardsPlayedThisTurn + 1
	return out
}

func applyMoveStack(a MoveStackAction, state State) State {
	if a.StackIndex < 0 || a.StackIndex >= len(state.Board) {
		return state
	}
	old := state.Board[a.StackIndex]
	moved := NewCardStack(old.BoardCards, a.NewLoc)
	newBoard := removeStack(state.Board, old)
	newBoard = append(newBoard, moved)
	out := state
	out.Board = newBoard
	return out
}

// applyDraw pulls the top card off the deck, adds it to the hand
// as FreshlyDrawn. Silent no-op if the deck is empty.
func applyDraw(state State) State {
	if len(state.Deck) == 0 {
		return state
	}
	drawn := state.Deck[0]
	out := state
	out.Deck = append([]Card{}, state.Deck[1:]...)
	out.Hand = Hand{HandCards: append(append([]HandCard{}, state.Hand.HandCards...),
		HandCard{Card: drawn, State: FreshlyDrawn},
	)}
	return out
}

// applyDiscard removes a card from the hand and pushes it onto the
// discard pile. Silent no-op if the card isn't in hand.
func applyDiscard(a DiscardAction, state State) State {
	hc := state.Hand.FindByCard(a.HandCard)
	if hc == nil {
		return state
	}
	out := state
	out.Hand = state.Hand.RemoveHandCard(*hc)
	out.Discard = append(append([]Card{}, state.Discard...), a.HandCard)
	return out
}

// applyTrickResult applies the board diff computed at submission
// time + removes the released hand cards. Tricks often span 2+
// hand cards and non-trivial board transformations; the diff
// captures all of it so replay is a single-step operation.
func applyTrickResult(a TrickResultAction, state State) State {
	out := state
	newBoard := append([]CardStack{}, state.Board...)
	for _, r := range a.StacksToRemove {
		newBoard = removeStack(newBoard, r)
	}
	newBoard = append(newBoard, a.StacksToAdd...)
	out.Board = newBoard

	newHand := state.Hand
	for _, c := range a.HandCardsReleased {
		if hc := newHand.FindByCard(c); hc != nil {
			newHand = newHand.RemoveHandCard(*hc)
		}
	}
	out.Hand = newHand
	out.CardsPlayedThisTurn = state.CardsPlayedThisTurn + len(a.HandCardsReleased)
	return out
}

// applyCompleteTurn resets per-turn flags: every hand card returns
// to HandNormal, CardsPlayedThisTurn resets to 0, TurnIndex++.
func applyCompleteTurn(state State) State {
	out := state
	out.Hand = state.Hand.ResetState()
	out.TurnIndex = state.TurnIndex + 1
	out.CardsPlayedThisTurn = 0
	return out
}

// removeStack returns a new slice with the first occurrence of
// `target` (by structural equality) removed.
func removeStack(board []CardStack, target CardStack) []CardStack {
	for i, s := range board {
		if stacksEqual(s, target) {
			out := append([]CardStack{}, board[:i]...)
			return append(out, board[i+1:]...)
		}
	}
	return board
}

// ReplayActions walks the given action list from InitialState
// (deterministic deck order). Used by tests and as a fallback.
func ReplayActions(actions []WireAction) State {
	return ReplayActionsSeeded(actions, 0)
}

// ReplayActionsSeeded walks the action list from
// InitialStateWithSeed(seed). The server stores a per-session
// seed when the session is created and passes it here on every
// replay — so reconstructions are reproducible per session.
// Undo actions are resolved during a preprocessing pass.
func ReplayActionsSeeded(actions []WireAction, seed int64) State {
	state := InitialStateWithSeed(seed)
	for _, a := range EffectiveActions(actions) {
		state = ApplyAction(a, state)
	}
	return state
}

// EffectiveActions resolves Undo actions against the raw log.
// Each Undo cancels the most recent non-Undo action. Multiple
// Undos pop multiple actions. An Undo with no history to cancel
// is a no-op.
//
// Net effect: ReplayActions(InitialState, log) ==
// fold(ApplyAction, InitialState, EffectiveActions(log)).
//
// This keeps the action log append-only (audit trail intact)
// while letting undo semantically "remove" a prior action
// from the game state.
func EffectiveActions(actions []WireAction) []WireAction {
	var stack []WireAction
	for _, a := range actions {
		if _, isUndo := a.(UndoAction); isUndo {
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
			continue
		}
		stack = append(stack, a)
	}
	return stack
}
