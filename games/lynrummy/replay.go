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
// CompleteTurn + Undo have their own transitions.

package lynrummy

import "math/rand"

type State struct {
	Board   []CardStack `json:"board"`
	Hands   []Hand      `json:"hands"`
	Deck    []Card      `json:"deck"`
	Discard []Card      `json:"discard"`

	// ActivePlayerIndex is the seat whose turn it is right now.
	// 0 or 1 in two-player. Advances on CompleteTurn.
	ActivePlayerIndex int `json:"active_player_index"`

	// Scores is the per-player running total, one entry per seat.
	// Updated at CompleteTurn: the outgoing player's cell gets
	// this-turn's score added. Indexed identically to Hands.
	Scores []int `json:"scores"`

	// VictorAwarded flips to true the first time a player
	// CompleteTurns with an empty hand. Later empty-hand turns
	// classify as SuccessWithHandEmpty (5-card draw, 1000 bonus)
	// rather than SuccessAsVictor (5-card draw, 1500 bonus).
	VictorAwarded bool `json:"victor_awarded"`

	// TurnStartBoardScore is the board score captured at the start
	// of the current turn. Used to compute the "board delta"
	// component of the turn score at CompleteTurn.
	TurnStartBoardScore int `json:"turn_start_board_score"`

	TurnIndex int `json:"turn_index"`

	// CardsPlayedThisTurn counts hand cards that left the active
	// player's hand for the board this turn (via PlaceHand,
	// MergeHand). Used to classify CompleteTurn; reset each turn.
	CardsPlayedThisTurn int `json:"cards_played_this_turn"`
}

// ActiveHand returns the hand belonging to the player whose turn
// it is. All hand-card actions target this hand during replay.
func (s State) ActiveHand() Hand {
	return s.Hands[s.ActivePlayerIndex]
}

// withActiveHand returns a state whose active hand has been
// replaced. Preserves immutability of the input state.
func (s State) withActiveHand(h Hand) State {
	hands := append([]Hand{}, s.Hands...)
	hands[s.ActivePlayerIndex] = h
	s.Hands = hands
	return s
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
	hands := OpeningHands()
	deck := remainingDeckAfterHands(board, hands)
	if seed != 0 {
		deck = shuffleDeckSeeded(deck, seed)
	}
	return State{
		Board:               board,
		Hands:               hands,
		Deck:                deck,
		Discard:             []Card{},
		ActivePlayerIndex:   0,
		Scores:              make([]int, len(hands)),
		TurnStartBoardScore: ScoreForStacks(board),
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
func remainingDeckAfterHands(board []CardStack, hands []Hand) []Card {
	full := BuildDeterministicDoubleDeck()
	used := map[Card]int{}
	for _, s := range board {
		for _, bc := range s.BoardCards {
			used[bc.Card]++
		}
	}
	for _, h := range hands {
		for _, hc := range h.HandCards {
			used[hc.Card]++
		}
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

	case CompleteTurnAction:
		return applyCompleteTurn(state)

	case UndoAction:
		// Snapshot-based undo is deferred. For now a no-op so the
		// wire accepts undo events without breaking replay.
		return state
	}
	return state
}

// --- Transition helpers ---
//
// Each helper preserves Deck / Discard / TurnIndex unless it's
// specifically mutating one of them (CompleteTurn).
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
	hand := state.ActiveHand()
	hc := hand.FindByCard(a.HandCard)
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
	out := state.withActiveHand(hand.RemoveHandCard(*hc))
	out.Board = newBoard
	out.CardsPlayedThisTurn = state.CardsPlayedThisTurn + 1
	return out
}

func applyPlaceHand(a PlaceHandAction, state State) State {
	hand := state.ActiveHand()
	hc := hand.FindByCard(a.HandCard)
	if hc == nil {
		return state
	}
	newStack := FromHandCard(*hc, a.Loc)
	newBoard := append([]CardStack{}, state.Board...)
	newBoard = append(newBoard, newStack)
	out := state.withActiveHand(hand.RemoveHandCard(*hc))
	out.Board = newBoard
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

// ageStack transitions each BoardCard's state one step closer to
// "firm" at the turn boundary. Mirrors TS CardStack.aged_from_prior_turn.
// Cards the active player just put down this turn were FreshlyPlayed;
// after their CompleteTurn they become FreshlyPlayedByLastPlayer so
// the INCOMING player sees them highlighted (opponent color). The
// cycle before that is already FreshlyPlayedByLastPlayer — those
// settle to FirmlyOnBoard.
func ageStack(s CardStack) CardStack {
	aged := make([]BoardCard, len(s.BoardCards))
	for i, bc := range s.BoardCards {
		next := bc.State
		switch bc.State {
		case FreshlyPlayed:
			next = FreshlyPlayedByLastPlayer
		case FreshlyPlayedByLastPlayer:
			next = FirmlyOnBoard
		}
		aged[i] = BoardCard{Card: bc.Card, State: next}
	}
	return NewCardStack(aged, s.Loc)
}

// applyCompleteTurn finishes the outgoing player's turn. In order:
//
//  1. Classify the turn (SuccessButNeedsCards / SuccessAsVictor /
//     SuccessWithHandEmpty / Success — Failure isn't reached here
//     because the /actions gate rejects dirty boards upstream).
//  2. Compute and bank the outgoing player's turn score.
//  3. If the result awards a victor bonus, mark VictorAwarded so
//     later empty-hand turns classify as plain SuccessWithHandEmpty.
//  4. Reset the outgoing hand's per-turn card state, then draw N
//     cards from the deck based on the result (0/3/5).
//  5. Age board cards: FreshlyPlayed → FreshlyPlayedByLastPlayer,
//     FreshlyPlayedByLastPlayer → FirmlyOnBoard. Mirror of TS
//     Board.age_cards — so the incoming player sees the outgoing
//     player's recent plays highlighted (lavender), and their own
//     prior freshly-played cards settle to firm white.
//  6. Advance TurnIndex, reset CardsPlayedThisTurn, cycle the seat,
//     and capture a fresh TurnStartBoardScore for the incoming turn.
//
// Mirrors TS Player.end_turn + PlayerGroup.advance_turn.
func applyCompleteTurn(state State) State {
	outgoingIdx := state.ActivePlayerIndex
	result := ClassifyTurnResult(state, state.VictorAwarded)

	boardScore := ScoreForStacks(state.Board)
	boardDelta := boardScore - state.TurnStartBoardScore
	turnScore := boardDelta + ScoreForCardsPlayed(state.CardsPlayedThisTurn)
	switch result {
	case TurnResultSuccessAsVictor:
		turnScore += 1000 + 500 // empty-hand + victor
	case TurnResultSuccessWithHandEmpty:
		turnScore += 1000
	}

	scores := append([]int{}, state.Scores...)
	if outgoingIdx < len(scores) {
		scores[outgoingIdx] += turnScore
	}

	outgoingHand := state.Hands[outgoingIdx].ResetState()
	deck := append([]Card{}, state.Deck...)
	var drawCount int
	switch result {
	case TurnResultSuccessButNeedsCards:
		drawCount = 3
	case TurnResultSuccessAsVictor, TurnResultSuccessWithHandEmpty:
		drawCount = 5
	}
	for i := 0; i < drawCount && len(deck) > 0; i++ {
		outgoingHand = outgoingHand.AddCards([]Card{deck[0]}, FreshlyDrawn)
		deck = deck[1:]
	}

	hands := append([]Hand{}, state.Hands...)
	hands[outgoingIdx] = outgoingHand

	nextActive := outgoingIdx
	if len(hands) > 0 {
		nextActive = (outgoingIdx + 1) % len(hands)
	}

	agedBoard := make([]CardStack, len(state.Board))
	for i, stk := range state.Board {
		agedBoard[i] = ageStack(stk)
	}

	return State{
		Board:               agedBoard,
		Hands:               hands,
		Deck:                deck,
		Discard:             state.Discard,
		ActivePlayerIndex:   nextActive,
		Scores:              scores,
		VictorAwarded:       state.VictorAwarded || result == TurnResultSuccessAsVictor,
		TurnStartBoardScore: boardScore,
		TurnIndex:           state.TurnIndex + 1,
		CardsPlayedThisTurn: 0,
	}
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
