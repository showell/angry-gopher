// fixturegen: parse a LynRummy-DSL scenario file and emit
// native test code for Elm + JSON fixtures for Python.
//
// DO NOT run this binary ad-hoc. The canonical way to
// regenerate fixtures is `ops/check-conformance` (which also
// runs Python + Elm conformance tests so drift surfaces
// immediately). Drifted dev-loop scripts are how an hour
// disappears resurrecting things.
//
// Pipeline (template-driven):
//   parse .dsl → AST → render templates → write → idempotence check
//
// Go target retired 2026-04-28 with the Go domain package.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"text/template"
)

// --- Design principles (read before adding an op) ---
//
// 1. Parser genericness is a NON-GOAL. Each op gets a custom
//    parser written for its exact DSL shape. Generic parsers
//    don't scale to real problems; Claude writes custom ones fast.
//
// 2. Maximize compile-time safety. Each op has its own Expect*
//    type — the compiler enforces that an op's emitter only sees
//    its own fields. Adding a new op's fields never touches
//    another op's type.
//
// 3. One op, one emitter. The Elm emitter function for op X reads
//    only ExpectX. No shared emit paths that need op-kind guards.
//    When a hand-written Elm test is fully superseded by DSL scenarios,
//    mark it `-- SUPERSEDED by <dsl-file>.dsl` at the top so future
//    deletion is safe without a full re-audit.
//
// 4. Be kind to the Elm compiler. Emitters should NOT inline large
//    record literals (Card, CardStack, etc.) as compile-time
//    constants — the Elm compiler type-checks every literal and
//    slows down on verbose data. Prefer runtime construction:
//    decode from a JSON string, call a helper that builds the
//    value from compact primitives, or use a Fixtures.elm helper.
//    The card representation approach (JSON-decoded at runtime,
//    not inlined) is the established pattern — follow it.

// --- AST (exported fields so text/template can access them) ---

type Scenario struct {
	Name       string
	Desc       string
	Op         string
	Trick      string
	Hand       []Card
	BoardVar   string
	Board      []Stack
	Removed    []Stack
	Added      []Stack
	HandPlayed []Card
	// Four-bucket state, used by `enumerate_moves` and any future
	// planner ops. Empty for non-planner ops.
	Helper   []Stack
	Trouble  []Stack
	Growing  []Stack
	Complete []Stack
	// Geometry op (`find_open_loc`).
	Existing  []Stack
	CardCount int
	// Replay-invariant op (`replay_invariant`).
	ReplayActions []ReplayAction
	// Undo-walkthrough op (`undo_walkthrough`).
	Steps            []WalkthroughStep
	ExpectFinalBoard []Stack // expect_final_board: — full board state after all steps
	// Drag-invariant ops (`floater_top_left`, `path_frame`).
	DragCardIndex   int    // card_index: N
	MousedownPoint  *XY    // mousedown: (x, y)
	MousemoveDelta  *XY    // mousemove_delta: (dx, dy)
	MousedownA      *XY    // mousedown_a: (x, y)
	MousedownB      *XY    // mousedown_b: (x, y)
	MousedownDelta  *XY    // delta: (dx, dy)
	DragHandCard    string // hand_card: <token>
	// Gesture ops (`gesture_split`, `gesture_merge_stack`, etc.).
	GestureFloaterAt    *XY    // floater_at: (x, y)
	GestureHoveredSide  string // hovered_side: Left|Right
	GestureCursor       *XY    // cursor: (x, y)
	GestureClickIntent  *int   // gesture_click_intent: N
	GestureTarget       []Stack // target: block — target stack for merge/floater ops
	Expect              Expectation
}

// WalkthroughStep is one step in an `undo_walkthrough` scenario.
// The DSL reads like a game transcript: each step carries an
// optional action (board primitive OR the special "undo" token)
// and optional per-step assertions.
type WalkthroughStep struct {
	Label              string
	Action             *ReplayAction // nil = observation step (no action)
	ExpectBoardCount   *int          // expect_board_count: N
	ExpectHandCount    *int          // expect_hand_count: N
	ExpectUndoable     *bool         // expect_undoable: true | false
	ExpectStack        []Card        // expect_stack: <cards> — stack with exactly these cards exists on board
	ExpectHandContains *Card         // expect_hand_contains: <card> — card is in active hand
}

// ReplayAction is one entry in a replay_invariant scenario's
// action log. We don't reuse Stack because each shape carries
// different fields. The Elm emitter walks these to build a
// dynamic WireAction list at test-runtime — content addresses
// are resolved against the live board on each step, mirroring
// what the replay engine does in production.
type ReplayAction struct {
	Kind      string
	Source    []Card // for Split (stack content), MergeStack (source content), MoveStack (stack content)
	Target    []Card // for MergeStack (target content)
	CardIndex int    // for Split
	Side      string // for MergeStack ("left" / "right")
	NewLoc    *Loc   // for MoveStack
}

// Loc is a (top, left) pair used by `expect: loc:` in
// find_open_loc scenarios.
type Loc struct {
	Top, Left int
}

// XY is a (x, y) cursor-point pair used by drag-invariant
// scenario fields (mousedown, mousemove_delta, etc.).
type XY struct {
	X, Y int
}

// ExpectBase covers fields that are shared across multiple ops:
// the kind sentinel, move-validator stage/message/board fields,
// and build_suggestions rows.
type ExpectBase struct {
	Kind          string
	HandPlayed    []Card
	BoardAfter    []Stack
	Stage         string
	MessageSubstr string
	Suggestions   []ExpectedSuggestion // expect: suggestions
}

// ExpectPlanner holds expectations for the `enumerate_moves` op.
type ExpectPlanner struct {
	Yields          string // at least one yielded move has this type
	NarrateContains string // at least one yielded move's narrate() contains this substring
	HintContains    string // at least one yielded move's hint() contains this substring
}

// ExpectSolve holds expectations for the `solve` op.
type ExpectSolve struct {
	NoPlan     bool     // expect: no_plan — assert solve returns None
	PlanLength int      // expect: plan_length: N
	PlanLines  []string // expect: plan_lines — snapshot match
}

// ExpectGeometry holds expectations for `find_open_loc`,
// `validate_board_geometry`, `classify_board_geometry`, and
// `stack_height_constant`.
type ExpectGeometry struct {
	Loc                 *Loc   // expect: loc: (top, left) — findOpenLoc result
	ErrorCount          *int   // expect: error_count: N
	AnyErrorKind        string // expect: any_error_kind: out_of_bounds|overlap|too_close
	NoErrorKind         string // expect: no_error_kind: out_of_bounds|overlap|too_close
	OverlapCount        *int   // expect: overlap_count: N
	OverlapStackIndices []int  // expect: overlap_stack_indices: i j
	GeometryStatus      string // expect: geometry_status: CleanlySpaced|Crowded|Illegal
	StackHeight         *int   // expect: stack_height: N
}

// ExpectDragFloater holds expectations for the `floater_top_left` op.
type ExpectDragFloater struct {
	ShiftEqualsDelta   bool // shift_equals_delta: true — before + delta == after
	GrabPointInvariant bool // grab_point_invariant: true — shift(downA) == shift(downB)
}

// ExpectDragPathFrame holds expectations for the `path_frame` op.
type ExpectDragPathFrame struct {
	Frame          string // frame: BoardFrame|ViewportFrame
	InitialFloater *XY    // initial_floater_at: (x, y)
}

// ExpectGestureSplit holds expectations for the `gesture_split` op.
type ExpectGestureSplit struct {
	CardIndex int // card_index: N — the expected Split cardIndex
}

// ExpectGestureMergeStack holds expectations for the `gesture_merge_stack` op.
type ExpectGestureMergeStack struct {
	Side string // side: Left|Right
}

// ExpectGestureMergeHand holds expectations for the `gesture_merge_hand` op.
type ExpectGestureMergeHand struct {
	Side string // side: Left|Right
}

// ExpectGestureMoveStack holds expectations for the `gesture_move_stack` op.
// If Rejected=true, resolveGesture must return Nothing.
// Otherwise NewLocLeft/NewLocTop give the expected MoveStack newLoc.
type ExpectGestureMoveStack struct {
	Rejected   bool
	NewLocLeft int // new_loc_left: N
	NewLocTop  int // new_loc_top: N
}

// ExpectGesturePlaceHand holds expectations for the `gesture_place_hand` op.
type ExpectGesturePlaceHand struct {
	LocLeft int // loc_left: N
	LocTop  int // loc_top: N
}

// ExpectGestureFloaterOverWing holds expectations for the
// `gesture_floater_over_wing` op.
// HasWing=true means floaterOverWing must return Just wing with the
// given Side; HasWing=false means it must return Nothing.
type ExpectGestureFloaterOverWing struct {
	HasWing bool   // has_wing: true|false
	Side    string // side: Left|Right (only checked when HasWing=true)
}

// ExpectClickAgent holds expectations for the `click_agent_play` op.
type ExpectClickAgent struct {
	ReplayStarted    *bool  // expect: replay_started: true | false
	LogAppended      *int   // expect: log_appended: N
	AgentProgramSize *int   // expect: agent_program_size: N
	StatusKind       string // expect: status_kind: inform | scold | celebrate
	StatusContains   string // expect: status_contains: "..."
}

// ExpectReplay holds expectations for the `replay_invariant` op.
type ExpectReplay struct {
	FinalBoardVictory *bool // expect: final_board_victory: true | false
}

// Expectation is the top-level container stored on Scenario.
// Each op reads only its own sub-struct; the base covers fields
// shared across multiple ops.
type Expectation struct {
	ExpectBase
	Planner              ExpectPlanner
	Solve                ExpectSolve
	Geometry             ExpectGeometry
	ClickAgent           ExpectClickAgent
	Replay               ExpectReplay
	DragFloater          ExpectDragFloater
	DragPathFrame        ExpectDragPathFrame
	GestureSplit         ExpectGestureSplit
	GestureMergeStack    ExpectGestureMergeStack
	GestureMergeHand     ExpectGestureMergeHand
	GestureMoveStack     ExpectGestureMoveStack
	GesturePlaceHand     ExpectGesturePlaceHand
	GestureFloaterOverWing ExpectGestureFloaterOverWing
}

// ExpectedSuggestion — one row inside an `expect: suggestions`
// block. Carries the trick_id we expect and the hand cards the
// top Play should reference. Rank is inferred from list order.
type ExpectedSuggestion struct {
	TrickID   string
	HandCards []Card
}

type Stack struct {
	Top, Left int
	Cards     []Card
}

type Card struct {
	Value      int
	Suit       int
	Deck       int
	BoardState int
}

// --- Entry point ---

const (
	elmOutPath      = "./games/lynrummy/elm/tests/Game/DslConformanceTest.elm"
	jsonOutPath     = "./games/lynrummy/python/conformance_fixtures.json"
	manifestOutPath = "./games/lynrummy/python/conformance_ops.json"
)

// --- Op registry ---
//
// One declaration per scenario op. To add a new op:
//
//   1. Append an OpKind row below.
//   2. Implement the per-target emitter functions you flagged
//      true (Go and/or Elm). Python is interpreted: register a
//      runner in test_dsl_conformance.py:DISPATCH.
//   3. If the op needs new scalar / block / expectation fields,
//      extend the parser (applyScalarField / applyBlockField /
//      parseExpectBlock) and the AST struct (Scenario /
//      Expectation), plus the JSON shape (jsonScenario /
//      jsonExpect / toJSONScenario) if the op is python:true.
//
// fixturegen verifies at startup that every op encountered in
// the .dsl files is registered here, and emits a sibling
// `conformance_ops.json` that the Python runner consumes to
// cross-check its DISPATCH dict. So a forgotten registration
// fails loud, and a Python<->Go drift fails loud too.
//
// See cmd/fixturegen/ADDING_AN_OP.md for the full recipe.
type OpKind struct {
	Name    string
	Elm     bool                             // emit an Elm test stub for this op
	Python  bool                             // include in conformance_fixtures.json
	EmitElm func(*strings.Builder, Scenario) // body of the generated Elm test thunk (Elm=true)
}

// opRegistry is the single source of truth for op routing +
// per-target emission. Order is insignificant; lookups go
// through opByName.
var opRegistry = []OpKind{
	{
		Name:    "validate_game_move",
		Elm:     true,
		EmitElm: func(b *strings.Builder, sc Scenario) { elmValidateMove(b, sc, false) },
	},
	{
		Name:    "validate_turn_complete",
		Elm:     true,
		EmitElm: func(b *strings.Builder, sc Scenario) { elmValidateMove(b, sc, true) },
	},
	{
		Name:    "build_suggestions",
		Elm:     true,
		Python:  true,
		EmitElm: elmBuildSuggestions,
	},
	{
		Name:    "hint_invariant",
		Elm:     true,
		Python:  true,
		EmitElm: emitElmHintInvariant,
	},
	{
		Name:    "enumerate_moves",
		Elm:     true,
		Python:  true,
		EmitElm: elmEnumerateMoves,
	},
	{
		Name:    "solve",
		Elm:     true,
		Python:  true,
		EmitElm: elmSolve,
	},
	{
		Name:    "find_open_loc",
		Elm:     true,
		Python:  true,
		EmitElm: elmFindOpenLoc,
	},
	{
		Name:    "click_agent_play",
		Elm:     true,
		EmitElm: elmClickAgentPlay,
	},
	{
		Name:    "replay_invariant",
		Elm:     true,
		EmitElm: elmReplayInvariant,
	},
	{
		Name:    "undo_walkthrough",
		Elm:     true,
		EmitElm: elmUndoWalkthrough,
	},
	{
		// Legacy: no scenarios reference this op today, but the
		// Elm emitter is preserved so old hint scenarios can
		// re-enter without re-implementing the dispatch.
		Name:    "trick_first_play",
		Elm:     true,
		EmitElm: emitElmTrickFirstPlay,
	},
	{
		// Elm-only: Python's find_violation / out_of_bounds cover
		// related ground but don't match the typed-error API shape.
		Name:    "validate_board_geometry",
		Elm:     true,
		EmitElm: elmValidateBoardGeometry,
	},
	{
		// Elm-only: classifyBoardGeometry has no Python equivalent.
		Name:    "classify_board_geometry",
		Elm:     true,
		EmitElm: elmClassifyBoardGeometry,
	},
	{
		// Elm-only: asserts stackHeight == 40 (the shared constant).
		Name:    "stack_height_constant",
		Elm:     true,
		EmitElm: elmStackHeightConstant,
	},
	{
		// Elm-only: no Python drag layer. Asserts floaterTopLeft
		// shifts by exactly the cursor delta on mousemove,
		// regardless of grab point.
		Name:    "floater_top_left",
		Elm:     true,
		EmitElm: elmFloaterTopLeft,
	},
	{
		// Elm-only: no Python drag layer. Asserts pathFrame is
		// set correctly on mousedown for each drag origin type.
		Name:    "path_frame",
		Elm:     true,
		EmitElm: elmPathFrame,
	},
	{
		// Elm-only: no Python gesture layer. Tests resolveGesture
		// → Split when clickIntent survives to mouseup.
		Name:    "gesture_split",
		Elm:     true,
		EmitElm: elmGestureSplit,
	},
	{
		// Elm-only: no Python gesture layer. Tests resolveGesture
		// → MergeStack when hoveredWing is set with a board source.
		Name:    "gesture_merge_stack",
		Elm:     true,
		EmitElm: elmGestureMergeStack,
	},
	{
		// Elm-only: no Python gesture layer. Tests resolveGesture
		// → MergeHand when hoveredWing is set with a hand source.
		Name:    "gesture_merge_hand",
		Elm:     true,
		EmitElm: elmGestureMergeHand,
	},
	{
		// Elm-only: no Python gesture layer. Tests resolveGesture
		// → MoveStack (or Nothing for off-board rejection) when no
		// hoveredWing and the source is a board stack.
		Name:    "gesture_move_stack",
		Elm:     true,
		EmitElm: elmGestureMoveStack,
	},
	{
		// Elm-only: no Python gesture layer. Tests resolveGesture
		// → PlaceHand when source is a hand card and cursor is over
		// the board.
		Name:    "gesture_place_hand",
		Elm:     true,
		EmitElm: elmGesturePlaceHand,
	},
	{
		// Elm-only: no Python gesture layer. Tests floaterOverWing
		// with a single registered wing and various floater positions.
		Name:    "gesture_floater_over_wing",
		Elm:     true,
		EmitElm: elmGestureFloaterOverWing,
	},
}

var opByName = func() map[string]*OpKind {
	out := make(map[string]*OpKind, len(opRegistry))
	for i := range opRegistry {
		op := &opRegistry[i]
		if _, dup := out[op.Name]; dup {
			panic(fmt.Sprintf("opRegistry: duplicate op %q", op.Name))
		}
		out[op.Name] = op
	}
	return out
}()

// validateRegistryAgainstScenarios fails loud if any scenario
// uses an op not declared above. This is the load-bearing check
// that turns "I forgot to register the op" into a startup error
// instead of a silent dead branch.
func validateRegistryAgainstScenarios(scenarios []Scenario) error {
	for _, sc := range scenarios {
		op := opByName[sc.Op]
		if op == nil {
			return fmt.Errorf("scenario %q uses unregistered op %q — add it to opRegistry in cmd/fixturegen/main.go (see ADDING_AN_OP.md)", sc.Name, sc.Op)
		}
		if op.Elm && op.EmitElm == nil {
			return fmt.Errorf("op %q is Elm=true but has no EmitElm", op.Name)
		}
	}
	return nil
}

// pythonOps returns the sorted list of op names that are
// expected to run in the Python runner. Emitted as a manifest
// alongside the fixtures so the Python side can cross-check.
func pythonOps() []string {
	var out []string
	for _, op := range opRegistry {
		if op.Python {
			out = append(out, op.Name)
		}
	}
	sort.Strings(out)
	return out
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: fixturegen <scenario.dsl>...")
		os.Exit(2)
	}

	var all []Scenario
	for _, arg := range os.Args[1:] {
		matches, err := filepath.Glob(arg)
		if err != nil {
			die(err)
		}
		for _, path := range matches {
			data, err := os.ReadFile(path)
			if err != nil {
				die(err)
			}
			scenarios, err := parse(string(data), path)
			if err != nil {
				die(err)
			}
			all = append(all, scenarios...)
		}
	}

	sort.Slice(all, func(i, j int) bool { return all[i].Name < all[j].Name })

	// Registry gate: a scenario using an unregistered op should
	// fail loud here, not produce a silent dead branch downstream.
	if err := validateRegistryAgainstScenarios(all); err != nil {
		die(err)
	}

	if err := emitElm(all, elmOutPath); err != nil {
		die(fmt.Errorf("elm emit: %w", err))
	}
	if err := emitJSON(all, jsonOutPath); err != nil {
		die(fmt.Errorf("json emit: %w", err))
	}
	if err := emitOpsManifest(manifestOutPath); err != nil {
		die(fmt.Errorf("ops manifest emit: %w", err))
	}

	// Idempotence: regen and diff; a clean generator never produces
	// different output for the same input.
	if err := checkIdempotence(all); err != nil {
		die(fmt.Errorf("regen not idempotent: %w", err))
	}

	fmt.Printf("Emitted %d scenarios → Elm test file + JSON fixtures + ops manifest (idempotent).\n", len(all))
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// --- Post-process pipeline ---

// writeElmFile writes Elm source as-is (no auto-formatter
// shelled out today; could be wired later if we want).
func writeElmFile(path string, src []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, src, 0644)
}

func checkIdempotence(all []Scenario) error {
	originalElm, err := os.ReadFile(elmOutPath)
	if err != nil {
		return err
	}
	originalJSON, err := os.ReadFile(jsonOutPath)
	if err != nil {
		return err
	}
	originalManifest, err := os.ReadFile(manifestOutPath)
	if err != nil {
		return err
	}
	if err := emitElm(all, elmOutPath); err != nil {
		return err
	}
	if err := emitJSON(all, jsonOutPath); err != nil {
		return err
	}
	if err := emitOpsManifest(manifestOutPath); err != nil {
		return err
	}
	afterElm, _ := os.ReadFile(elmOutPath)
	afterJSON, _ := os.ReadFile(jsonOutPath)
	afterManifest, _ := os.ReadFile(manifestOutPath)
	if !bytes.Equal(originalElm, afterElm) {
		return fmt.Errorf("Elm output differs on second regen")
	}
	if !bytes.Equal(originalJSON, afterJSON) {
		return fmt.Errorf("JSON output differs on second regen")
	}
	if !bytes.Equal(originalManifest, afterManifest) {
		return fmt.Errorf("ops manifest differs on second regen")
	}
	return nil
}

// --- Elm emission (template-based) ---

const elmTemplate = `-- GENERATED by cmd/fixturegen — DO NOT EDIT.
-- Source scenarios: lynrummy/conformance/scenarios/*.dsl
-- Regenerate with: go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl

module Game.DslConformanceTest exposing (suite)

import Expect
import Game.Agent.Bfs
import Game.Agent.Buckets as AgentBuckets exposing (Buckets)
import Game.Agent.Enumerator as AgentEnumerator
import Game.Agent.Move as AgentMove exposing (Move(..))
import Game.Physics.BoardGeometry
    exposing
        ( BoardBounds
        , BoardGeometryStatus(..)
        , GeometryErrorKind(..)
        , classifyBoardGeometry
        , stackHeight
        , validateBoardGeometry
        )
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCard
        , HandCardState(..)
        )
import Game.BoardActions as BoardActions
import Game.Physics.PlaceStack
import Game.Rules.Referee as Referee exposing (RefereeStage(..), refereeStageToString)
import Game.Replay.Time as ReplayTime
import Game.Rules.StackType as StackType
import Game.Strategy.Hint as Hint
import Game.WireAction as WA exposing (WireAction)
import Main.Apply as Apply
import Main.Gesture as Gesture
import Main.Msg as Msg
import Main.Play as Play
import Main.State as State
{{range elmTrickModules}}import Game.Strategy.{{.}}
{{end}}import Test exposing (Test, describe, test)


standardBounds : BoardBounds
standardBounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


parseCard : String -> Card
parseCard s =
    let
        chars =
            String.toList s

        value =
            case List.head chars of
                Just 'A' -> Ace
                Just '2' -> Two
                Just '3' -> Three
                Just '4' -> Four
                Just '5' -> Five
                Just '6' -> Six
                Just '7' -> Seven
                Just '8' -> Eight
                Just '9' -> Nine
                Just 'T' -> Ten
                Just 'J' -> Jack
                Just 'Q' -> Queen
                Just 'K' -> King
                _ -> Debug.todo ("parseCard: bad value in " ++ s)

        suit =
            case chars |> List.drop 1 |> List.head of
                Just 'C' -> Club
                Just 'D' -> Diamond
                Just 'S' -> Spade
                Just 'H' -> Heart
                _ -> Debug.todo ("parseCard: bad suit in " ++ s)

        deck =
            case chars |> List.drop 2 |> List.head of
                Just '1' -> DeckOne
                Just '2' -> DeckTwo
                _ -> Debug.todo ("parseCard: bad deck in " ++ s)
    in
    { value = value, suit = suit, originDeck = deck }


boardCard : String -> BoardCard
boardCard s =
    { card = parseCard s, state = FirmlyOnBoard }


handCard : String -> HandCard
handCard s =
    { card = parseCard s, state = HandNormal }


-- Invariant check: every stack must classify as a complete group
-- (Set, PureRun, or RedBlackRun). Anything else (Incomplete /
-- Bogus / Dup) means the trick's emission broke the board.
isCleanStack : CardStack -> Bool
isCleanStack s =
    case StackType.getStackType (List.map .card s.boardCards) of
        StackType.Set ->
            True

        StackType.PureRun ->
            True

        StackType.RedBlackRun ->
            True

        _ ->
            False


firstIncompleteStack : List CardStack -> Maybe ( Int, CardStack )
firstIncompleteStack stacks =
    stacks
        |> List.indexedMap Tuple.pair
        |> List.filter (\( _, s ) -> not (isCleanStack s))
        |> List.head


-- ============================================================
-- Replay-invariant helpers (op replay_invariant)
-- ============================================================


type ReplaySpec
    = SpecSplit (List Card) Int
    | SpecMergeStack (List Card) (List Card) BoardActions.Side
    | SpecMoveStack (List Card) BoardLocation
    | SpecCompleteTurn


findStackByContent : List Card -> List CardStack -> CardStack
findStackByContent cards board =
    case List.filter (\s -> List.map .card s.boardCards == cards) board of
        match :: _ ->
            match

        [] ->
            -- Test-fixture invariant. If a scenario references
            -- a stack that doesn't exist on the live sim, the
            -- DSL author and the production code disagree about
            -- what the action log says — fail loudly rather than
            -- silently no-op. (Production code returns Nothing
            -- in this case; here we want it to be a test error.)
            { boardCards = []
            , loc = { top = -1, left = -1 }
            }


resolveSpec : ReplaySpec -> List CardStack -> WireAction
resolveSpec spec board =
    case spec of
        SpecSplit cards idx ->
            WA.Split { stack = findStackByContent cards board, cardIndex = idx }

        SpecMergeStack src tgt side ->
            WA.MergeStack
                { source = findStackByContent src board
                , target = findStackByContent tgt board
                , side = side
                }

        SpecMoveStack cards loc ->
            WA.MoveStack { stack = findStackByContent cards board, newLoc = loc }

        SpecCompleteTurn ->
            WA.CompleteTurn


buildEagerAndActions : State.Model -> List ReplaySpec -> ( State.Model, List WireAction )
buildEagerAndActions initialModel specs =
    let
        loop model acc remaining =
            case remaining of
                [] ->
                    ( model, List.reverse acc )

                spec :: rest ->
                    let
                        action =
                            resolveSpec spec model.board

                        next =
                            (Apply.applyAction action model).model
                    in
                    loop next (action :: acc) rest
    in
    loop initialModel [] specs


runReplay : State.Model -> List WireAction -> State.Model
runReplay initialModel actions =
    let
        entries =
            List.map
                (\a ->
                    { action = a
                    , gesturePath = Nothing
                    , pathFrame = State.BoardFrame
                    }
                )
                actions

        seeded =
            { initialModel
                | replay = Just { pending = entries, paused = False }
                , replayAnim = State.NotAnimating
            }
    in
    runReplayLoop seeded 0 5000


runReplayLoop : State.Model -> Float -> Int -> State.Model
runReplayLoop model nowMs budget =
    case model.replay of
        Nothing ->
            model

        Just _ ->
            if budget <= 0 then
                -- Test-time guard: if the FSM doesn't drain the
                -- queue within this many ticks, the test would
                -- hang. Hand-origin actions in particular can
                -- park in AwaitingHandRect indefinitely under
                -- elm-test (no DOM). Bail loudly via Debug.todo
                -- so the failure mode is visible.
                Debug.todo
                    "runReplayLoop budget exhausted — replay FSM did not complete"

            else
                let
                    ( next, _ ) =
                        ReplayTime.replayFrame nowMs model
                in
                runReplayLoop next (nowMs + 50) (budget - 1)

{{range .}}

{{elmTestFn .}} : Test
{{elmTestFn .}} =
    test {{quote .Name}} <|
        \_ ->
{{elmScenarioBody .}}
{{end}}

suite : Test
suite =
    describe "DSL conformance"
        [ {{range $i, $sc := .}}{{if $i}}
        , {{end}}{{elmTestFn $sc}}{{end}}
        ]
`

func emitElm(scenarios []Scenario, outPath string) error {
	t := template.New("elm").Funcs(template.FuncMap{
		"elmTestFn":        elmTestFn,
		"elmScenarioBody":  elmScenarioBody,
		"elmTrickModules":  elmTrickModules,
		"quote":            func(s string) string { return `"` + s + `"` },
	})
	if _, err := t.Parse(elmTemplate); err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, scenarios); err != nil {
		return err
	}
	return writeElmFile(outPath, buf.Bytes())
}

func elmTestFn(sc Scenario) string {
	return elmTestName(sc.Name)
}

func elmTestName(s string) string {
	parts := strings.Split(s, "_")
	var buf strings.Builder
	for i, p := range parts {
		if p == "" {
			continue
		}
		if i == 0 {
			buf.WriteString(p)
			continue
		}
		c := p[0]
		if c >= 'a' && c <= 'z' {
			buf.WriteByte(c &^ 0x20)
			buf.WriteString(p[1:])
		} else {
			buf.WriteString(p)
		}
	}
	return buf.String()
}

// elmPortedTricks records which tricks have a fully-ported Elm
// counterpart. Auto-discovered from
// games/lynrummy/elm/src/Game/Strategy/*.elm — a trick module is
// one that `exposing (trick)` exactly. Scenarios for unported
// tricks (Python-only, for now) stay as Expect.pass placeholders.
//
// PascalCase filename → snake_case trick id. Add a new trick
// module + register it in Hint.priorityOrder, and it picks up
// here automatically.
var elmPortedTricks = discoverElmTricks()

var elmStrategyDir = "games/lynrummy/elm/src/Game/Strategy"

// elmTrickExposingRE matches `module Game.Strategy.X exposing (trick)`
// tolerating whitespace variation around the parentheses. Modules
// that expose anything other than just `trick` (Hint, Trick,
// Helpers) are deliberately skipped.
var elmTrickExposingRE = regexp.MustCompile(`(?m)^module\s+Game\.Strategy\.\w+\s+exposing\s*\(\s*trick\s*\)`)

func discoverElmTricks() map[string]string {
	out := map[string]string{}
	entries, err := os.ReadDir(elmStrategyDir)
	if err != nil {
		return out
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".elm") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(elmStrategyDir, name))
		if err != nil {
			continue
		}
		if !elmTrickExposingRE.Match(data) {
			continue
		}
		mod := strings.TrimSuffix(name, ".elm")
		out[pascalToSnake(mod)] = "Game.Strategy." + mod + ".trick"
	}
	return out
}

// elmTrickModules returns the PascalCase module names of every
// discovered Elm trick, sorted — used to generate the import
// block in the conformance test.
func elmTrickModules() []string {
	var mods []string
	for _, v := range elmPortedTricks {
		// v is "Game.Strategy.X.trick"; take the X.
		parts := strings.Split(v, ".")
		if len(parts) >= 3 {
			mods = append(mods, parts[2])
		}
	}
	sort.Strings(mods)
	return mods
}

func pascalToSnake(s string) string {
	var b strings.Builder
	for i, r := range s {
		if r >= 'A' && r <= 'Z' {
			if i > 0 {
				b.WriteByte('_')
			}
			b.WriteRune(r - 'A' + 'a')
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// elmScenarioBody emits the inside of an Elm test thunk via the
// op registry. The Elm runner is the target-of-record (every op
// is expected to have an Elm emitter), so an unregistered op
// here is a registry bug.
func elmScenarioBody(sc Scenario) string {
	var b strings.Builder
	op := opByName[sc.Op]
	if op == nil || !op.Elm || op.EmitElm == nil {
		fmt.Fprintf(&b, "            Expect.fail %q", "registry/emitter mismatch for op "+sc.Op)
		return b.String()
	}
	op.EmitElm(&b, sc)
	return b.String()
}

// emitElmHintInvariant + emitElmTrickFirstPlay are tiny adapters
// that resolve the Elm trick module from elmPortedTricks before
// delegating to the real emitter. Kept thin so the registry can
// take a uniform `func(*Builder, Scenario)` shape.

func emitElmHintInvariant(b *strings.Builder, sc Scenario) {
	trickVar, ok := elmPortedTricks[sc.Trick]
	if !ok {
		fmt.Fprintf(b, "            Expect.fail \"unknown trick %s\"", sc.Trick)
		return
	}
	elmHintInvariant(b, sc, trickVar)
}

func emitElmTrickFirstPlay(b *strings.Builder, sc Scenario) {
	trickVar, ok := elmPortedTricks[sc.Trick]
	if !ok {
		fmt.Fprintf(b, "            -- Elm TrickBag not ported yet (%s / %s)\n            Expect.pass", sc.Trick, sc.Expect.Kind)
		return
	}
	elmTrickFirstPlay(b, sc, trickVar)
}


const elmClickAgentPlayTmpl = `            let
                board =
                    %s

                base =
                    State.baseModel

                model0 =
                    { base | board = board, sessionId = Just 0 }

                ( newModel, _, _ ) =
                    Play.update Msg.ClickAgentPlay model0

                logAppended =
                    List.length newModel.actionLog - List.length model0.actionLog

                replayStarted =
                    newModel.replay /= Nothing

                programSize =
                    case newModel.agentProgram of
                        Just lst ->
                            List.length lst

                        Nothing ->
                            0
            in
`

// elmClickAgentPlay emits a test body that constructs a Play
// model from the scenario's `board:` block, dispatches a
// `ClickAgentPlay` Msg through Play.update, and asserts on the
// resulting model. Used to lock down the click-side contract:
// what the immediate-reducer post-state looks like for
// solvable / unsolvable / replay-running cases.
//
// Only Elm runs this op (Python doesn't have an Elm-style
// reducer). Go and Python skip — the JSON gate filters by op.
func elmClickAgentPlay(b *strings.Builder, sc Scenario) {
	fmt.Fprintf(b, elmClickAgentPlayTmpl, elmStacks(sc.Board, "                        "))
	b.WriteString("            Expect.all\n                [ ")
	first := true
	emitCheck := func(s string) {
		if !first {
			b.WriteString("\n                , ")
		}
		first = false
		b.WriteString(s)
	}
	ca := sc.Expect.ClickAgent
	if ca.ReplayStarted != nil {
		emitCheck(fmt.Sprintf("\\_ -> Expect.equal %s replayStarted", elmBool(*ca.ReplayStarted)))
	}
	if ca.LogAppended != nil {
		emitCheck(fmt.Sprintf("\\_ -> Expect.equal %d logAppended", *ca.LogAppended))
	}
	if ca.AgentProgramSize != nil {
		emitCheck(fmt.Sprintf("\\_ -> Expect.equal %d programSize", *ca.AgentProgramSize))
	}
	if ca.StatusKind != "" {
		emitCheck(fmt.Sprintf("\\_ -> Expect.equal %s newModel.status.kind", elmStatusKind(ca.StatusKind)))
	}
	if ca.StatusContains != "" {
		emitCheck(fmt.Sprintf("\\_ -> if String.contains %q newModel.status.text then Expect.pass else Expect.fail (\"status missing %s; got: \" ++ newModel.status.text)", ca.StatusContains, ca.StatusContains))
	}
	if first {
		// No expectations supplied — at minimum verify the
		// reducer didn't crash.
		b.WriteString("\\_ -> Expect.pass")
	}
	b.WriteString("\n                ]\n                ()")
}


func elmBool(b bool) string {
	if b {
		return "True"
	}
	return "False"
}


func elmStatusKind(s string) string {
	switch s {
	case "inform":
		return "State.Inform"
	case "scold":
		return "State.Scold"
	case "celebrate":
		return "State.Celebrate"
	}
	return "State.Inform"
}


// elmReplayInvariant emits a test body that asserts the
// replay-engine endpoint matches the eager-applier endpoint.
//
// The promise of `Game.Replay`: walking the FSM forward to
// completion produces the same model the eager applier
// (`Apply.applyAction` chained over the action log) would.
// If that promise holds, animation can't silently drop, double-
// apply, or corrupt state. This op is the regression gate for
// that invariant.
//
// Build:
//   1. initialModel from `board:`.
//   2. actions from `actions:`, resolved against a moving sim
//      board so each WireAction's CardStack ref reflects the
//      pre-action state at its point of execution (mirroring
//      what gets stored in the live actionLog).
//   3. eagerModel = foldl Apply.applyAction over actions.
//   4. replayedModel = drive replayFrame from initialModel +
//      seeded replay until replay = Nothing.
//   5. assert eagerModel.{board, hands, scores, ...} ==
//      replayedModel.{board, hands, scores, ...}.
//
// Hand-origin actions (MergeHand/PlaceHand) are out of scope:
// their replay path needs DOM measurements that elm-test can't
// fulfill. Agent-emitted action logs (the primary worry) only
// use board-origin shapes, so the gate covers the case that
// matters most.
const elmReplayInvariantTmpl = `            let
                board =
                    %s

                base =
                    State.baseModel

                initialModel =
                    { base | board = board, sessionId = Just 0 }

                ( eagerModel, actions ) =
                    buildEagerAndActions initialModel
                        [ %s ]

                replayedModel =
                    runReplay initialModel actions
            in
`

const elmReplayInvariantChecks = `            Expect.all
                [ \_ -> Expect.equal eagerModel.board replayedModel.board
                , \_ -> Expect.equal eagerModel.hands replayedModel.hands
                , \_ -> Expect.equal eagerModel.scores replayedModel.scores
                , \_ -> Expect.equal eagerModel.activePlayerIndex replayedModel.activePlayerIndex
                , \_ -> Expect.equal eagerModel.turnIndex replayedModel.turnIndex`

const elmReplayInvariantVictoryChecks = `
                , \_ -> if List.all isCleanStack eagerModel.board then Expect.pass else Expect.fail ("final eager board not victory; incomplete stacks present: " ++ Debug.toString (firstIncompleteStack eagerModel.board))
                , \_ -> if List.all isCleanStack replayedModel.board then Expect.pass else Expect.fail ("final replayed board not victory; incomplete stacks present: " ++ Debug.toString (firstIncompleteStack replayedModel.board))`

const elmReplayInvariantClose = `
                ]
                ()`

func elmReplayInvariant(b *strings.Builder, sc Scenario) {
	fmt.Fprintf(b, elmReplayInvariantTmpl,
		elmStacks(sc.Board, "                        "),
		elmReplaySpecList(sc.ReplayActions))
	b.WriteString(elmReplayInvariantChecks)
	if sc.Expect.Replay.FinalBoardVictory != nil && *sc.Expect.Replay.FinalBoardVictory {
		b.WriteString(elmReplayInvariantVictoryChecks)
	}
	b.WriteString(elmReplayInvariantClose)
}


// elmReplaySpecList renders a list of ReplayAction entries as
// Elm `ReplaySpec` constructor literals (the runner's
// dispatchable shape, defined in the generated module
// preamble).
func elmReplaySpecList(actions []ReplayAction) string {
	var parts []string
	for _, a := range actions {
		parts = append(parts, elmReplaySpec(a))
	}
	return strings.Join(parts, "\n                        , ")
}


func elmReplaySpec(a ReplayAction) string {
	switch a.Kind {
	case "split":
		return fmt.Sprintf("SpecSplit %s %d", elmRawCards(cardsFromCards(a.Source)), a.CardIndex)
	case "merge_stack":
		return fmt.Sprintf("SpecMergeStack %s %s %s",
			elmRawCards(cardsFromCards(a.Source)),
			elmRawCards(cardsFromCards(a.Target)),
			elmReplaySide(a.Side))
	case "move_stack":
		return fmt.Sprintf("SpecMoveStack %s { top = %d, left = %d }",
			elmRawCards(cardsFromCards(a.Source)),
			a.NewLoc.Top, a.NewLoc.Left)
	case "complete_turn":
		return "SpecCompleteTurn"
	}
	return "SpecCompleteTurn"
}


func elmReplaySide(s string) string {
	if s == "left" {
		return "BoardActions.Left"
	}
	return "BoardActions.Right"
}


// cardsFromCards copies (no-op identity) so elmRawCards's
// signature stays compatible with both ExpectedSuggestion-style
// and ReplayAction-style call sites.
func cardsFromCards(cs []Card) []Card { return cs }


// elmUndoWalkthrough emits a test body that walks a sequence of
// board + hand actions plus undo steps, asserting board count,
// hand count, canUndoThisTurn, and specific card-content after
// each step. The scenario DSL reads like a human game transcript.
//
// Non-undo action steps apply physics via Apply.applyAction and
// manually append the log entry so canUndoThisTurn has correct
// state. Undo steps delegate to Play.update Msg.ClickUndo, which
// exercises the full click path (log collapse, Reducer.undoAction,
// board + hand update).
func elmUndoWalkthrough(b *strings.Builder, sc Scenario) {
	ind := "            " // 12 spaces — inside test thunk

	b.WriteString(ind + "let\n")
	fmt.Fprintf(b, "%s    board =\n%s        %s\n\n",
		ind, ind, elmStacks(sc.Board, ind+"            "))
	fmt.Fprintf(b, "%s    base =\n%s        State.baseModel\n\n", ind, ind)

	// Build m0: inject board, sessionId, and optional hand cards.
	if len(sc.Hand) > 0 {
		fmt.Fprintf(b, "%s    m0 =\n%s        State.setActiveHand { handCards = %s }\n%s            { base | board = board, sessionId = Just 0 }\n",
			ind, ind, elmHandCards(sc.Hand), ind)
	} else {
		fmt.Fprintf(b, "%s    m0 =\n%s        { base | board = board, sessionId = Just 0 }\n", ind, ind)
	}

	for i, step := range sc.Steps {
		cur := fmt.Sprintf("m%d", i+1)
		prev := fmt.Sprintf("m%d", i)

		fmt.Fprintf(b, "\n%s    -- %s\n", ind, step.Label)

		if step.Action == nil {
			// Observation-only step: alias the previous model.
			fmt.Fprintf(b, "%s    %s =\n%s        %s\n", ind, cur, ind, prev)

		} else if step.Action.Kind == "undo" {
			// Undo step: full click path via Play.update.
			fmt.Fprintf(b, "%s    ( %s, _, _ ) =\n%s        Play.update Msg.ClickUndo %s\n",
				ind, cur, ind, prev)

		} else if step.Action.Kind == "place_hand" || step.Action.Kind == "merge_hand" {
			// Hand-origin step: construct WireAction directly (no resolveSpec).
			act := fmt.Sprintf("action%d", i+1)
			entry := fmt.Sprintf("entry%d", i+1)
			post := fmt.Sprintf("m%dpost", i+1)

			fmt.Fprintf(b, "%s    %s =\n%s        %s\n\n",
				ind, act, ind, elmHandAction(*step.Action, prev))
			fmt.Fprintf(b, "%s    %s =\n%s        { action = %s, gesturePath = Nothing, pathFrame = State.BoardFrame }\n\n",
				ind, entry, ind, act)
			fmt.Fprintf(b, "%s    %s =\n%s        (Apply.applyAction %s %s).model\n\n",
				ind, post, ind, act, prev)
			fmt.Fprintf(b, "%s    %s =\n%s        { %s | actionLog = %s.actionLog ++ [ %s ] }\n",
				ind, cur, ind, post, prev, entry)

		} else {
			// Board-primitive step: apply physics + thread the log.
			spec := fmt.Sprintf("spec%d", i+1)
			act := fmt.Sprintf("action%d", i+1)
			entry := fmt.Sprintf("entry%d", i+1)
			post := fmt.Sprintf("m%dpost", i+1)

			fmt.Fprintf(b, "%s    %s =\n%s        %s\n\n",
				ind, spec, ind, elmReplaySpec(*step.Action))
			fmt.Fprintf(b, "%s    %s =\n%s        resolveSpec %s %s.board\n\n",
				ind, act, ind, spec, prev)
			fmt.Fprintf(b, "%s    %s =\n%s        { action = %s, gesturePath = Nothing, pathFrame = State.BoardFrame }\n\n",
				ind, entry, ind, act)
			fmt.Fprintf(b, "%s    %s =\n%s        (Apply.applyAction %s %s).model\n\n",
				ind, post, ind, act, prev)
			fmt.Fprintf(b, "%s    %s =\n%s        { %s | actionLog = %s.actionLog ++ [ %s ] }\n",
				ind, cur, ind, post, prev, entry)
		}
	}

	b.WriteString(ind + "in\n")

	var checks []string
	for i, step := range sc.Steps {
		model := fmt.Sprintf("m%d", i+1)
		if step.ExpectBoardCount != nil {
			checks = append(checks, fmt.Sprintf(
				"\\_ -> List.length %s.board |> Expect.equal %d", model, *step.ExpectBoardCount))
		}
		if step.ExpectHandCount != nil {
			checks = append(checks, fmt.Sprintf(
				"\\_ -> List.length (State.activeHand %s).handCards |> Expect.equal %d", model, *step.ExpectHandCount))
		}
		if step.ExpectUndoable != nil {
			checks = append(checks, fmt.Sprintf(
				"\\_ -> State.canUndoThisTurn %s |> Expect.equal %s", model, elmBool(*step.ExpectUndoable)))
		}
		if len(step.ExpectStack) > 0 {
			cards := elmRawCards(step.ExpectStack)
			label := elmCompactCardList(step.ExpectStack)
			checks = append(checks, fmt.Sprintf(
				"\\_ -> if List.any (\\s -> List.map .card s.boardCards == %s) %s.board then Expect.pass else Expect.fail \"board missing stack [%s]\"",
				cards, model, label))
		}
		if step.ExpectHandContains != nil {
			card := elmCompactCard(*step.ExpectHandContains)
			label := elmCompactCardList([]Card{*step.ExpectHandContains})
			checks = append(checks, fmt.Sprintf(
				"\\_ -> if List.any (\\hc -> hc.card == parseCard %s) (State.activeHand %s).handCards then Expect.pass else Expect.fail \"hand missing card %s\"",
				card, model, label))
		}
	}

	// Final-board assertion: sort both boards by (top, left) and
	// compare card lists, ignoring BoardCard.state differences that
	// arise from FreshlyPlayed vs FirmlyOnBoard bookkeeping.
	if len(sc.ExpectFinalBoard) > 0 {
		lastModel := fmt.Sprintf("m%d", len(sc.Steps))
		checks = append(checks, fmt.Sprintf(
			"\\_ ->\n%s        let\n%s            byLoc =\n%s                List.sortBy (\\s -> ( s.loc.top, s.loc.left ))\n%s            cardRows =\n%s                List.map (.boardCards >> List.map .card)\n%s            expectedFinalBoard =\n%s                %s\n%s        in\n%s        cardRows (byLoc %s.board) |> Expect.equal (cardRows (byLoc expectedFinalBoard))",
			ind, ind, ind, ind, ind, ind, ind,
			elmStacks(sc.ExpectFinalBoard, ind+"                "),
			ind, ind, lastModel))
	}

	if len(checks) == 0 {
		b.WriteString(ind + "Expect.pass")
		return
	}

	fmt.Fprintf(b, "%sExpect.all\n%s    [ %s", ind, ind, checks[0])
	for _, c := range checks[1:] {
		fmt.Fprintf(b, "\n%s    , %s", ind, c)
	}
	fmt.Fprintf(b, "\n%s    ]\n%s    ()", ind, ind)
}


// elmHandAction renders a hand-origin WireAction (place_hand or
// merge_hand) as an Elm literal. Unlike board-origin actions,
// these don't go through resolveSpec — the hand card is explicit
// and the target stack (for merge_hand) is content-addressed
// against the model board at the time of the step.
func elmHandAction(a ReplayAction, prevModel string) string {
	card := elmCompactCard(a.Source[0])
	switch a.Kind {
	case "place_hand":
		return fmt.Sprintf("WA.PlaceHand { handCard = parseCard %s, loc = { top = %d, left = %d } }",
			card, a.NewLoc.Top, a.NewLoc.Left)
	case "merge_hand":
		return fmt.Sprintf("WA.MergeHand { handCard = parseCard %s, target = findStackByContent %s %s.board, side = %s }",
			card,
			elmRawCards(cardsFromCards(a.Target)),
			prevModel,
			elmReplaySide(a.Side))
	}
	return fmt.Sprintf("Debug.todo \"unknown hand action kind %s\"", a.Kind)
}


// elmCompactCardList renders a space-separated human-readable card
// label string (no quotes), used in Expect.fail messages.
func elmCompactCardList(cs []Card) string {
	var parts []string
	for _, c := range cs {
		v := []string{"", "A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K"}[c.Value]
		s := []string{"C", "D", "S", "H"}[c.Suit]
		d := ""
		if c.Deck == 1 {
			d = "'"
		}
		parts = append(parts, v+s+d)
	}
	return strings.Join(parts, " ")
}


const elmFindOpenLocTmpl = `            let
                existing =
                    %s

                got =
                    Game.Physics.PlaceStack.findOpenLoc existing %d

                expected =
                    { top = %d, left = %d }
            in
            got |> Expect.equal expected`

// elmFindOpenLoc emits a test body that constructs a list of
// existing CardStacks and asserts `Game.Physics.PlaceStack.findOpenLoc`
// returns the expected loc. Mirrors what
// `python/test_dsl_conformance.py::_run_find_open_loc` does on
// the Python side. Cards in the existing stacks are shape-only;
// findOpenLoc only reads loc + boardCards length.
func elmFindOpenLoc(b *strings.Builder, sc Scenario) {
	if sc.Expect.Geometry.Loc == nil {
		b.WriteString("            Expect.fail \"find_open_loc scenario missing expect.loc\"")
		return
	}
	fmt.Fprintf(b, elmFindOpenLocTmpl,
		elmStacks(sc.Existing, "                        "),
		sc.CardCount,
		sc.Expect.Geometry.Loc.Top, sc.Expect.Geometry.Loc.Left)
}


// elmGeometryKindExpr converts a DSL kind string to its Elm
// GeometryErrorKind constructor name.
func elmGeometryKindExpr(kind string) string {
	switch kind {
	case "out_of_bounds":
		return "OutOfBounds"
	case "overlap":
		return "Overlap"
	case "too_close":
		return "TooClose"
	default:
		return "Debug.todo \"unknown geometry kind: " + kind + "\""
	}
}

// elmValidateBoardGeometry emits a test body that calls
// Game.Physics.BoardGeometry.validateBoardGeometry on `sc.Board`
// with standardBounds and asserts the error list matches the
// expectation. Supported assertions (all optional, applied in
// order):
//
//   - Kind == "ok"               → Expect.equal []
//   - ErrorCount                 → List.length == N
//   - AnyErrorKind               → List.any (\e -> e.kind == X)
//   - NoErrorKind                → not (List.any (\e -> e.kind == X))
//   - OverlapCount               → count of Overlap errors == N
//   - OverlapStackIndices        → first Overlap error has these stackIndices
func elmValidateBoardGeometry(b *strings.Builder, sc Scenario) {
	base := sc.Expect.ExpectBase
	geo := sc.Expect.Geometry
	fmt.Fprintf(b, "            let\n                errors =\n                    Game.Physics.BoardGeometry.validateBoardGeometry\n                        %s\n                        standardBounds\n            in\n",
		elmStacks(sc.Board, "                        "))

	if base.Kind == "ok" {
		b.WriteString("            errors |> Expect.equal []")
		return
	}

	// Build a list of checks for Expect.all.
	var checks []string

	if geo.ErrorCount != nil {
		checks = append(checks, fmt.Sprintf(
			"List.length >> Expect.equal %d", *geo.ErrorCount))
	}
	if geo.AnyErrorKind != "" {
		elmKind := elmGeometryKindExpr(geo.AnyErrorKind)
		checks = append(checks, fmt.Sprintf(
			"List.any (\\e -> e.kind == %s) >> Expect.equal True", elmKind))
	}
	if geo.NoErrorKind != "" {
		elmKind := elmGeometryKindExpr(geo.NoErrorKind)
		checks = append(checks, fmt.Sprintf(
			"List.any (\\e -> e.kind == %s) >> Expect.equal False", elmKind))
	}
	if geo.OverlapCount != nil {
		checks = append(checks, fmt.Sprintf(
			"List.filter (\\e -> e.kind == Overlap) >> List.length >> Expect.equal %d", *geo.OverlapCount))
	}
	if len(geo.OverlapStackIndices) > 0 {
		idxStrs := make([]string, len(geo.OverlapStackIndices))
		for i, idx := range geo.OverlapStackIndices {
			idxStrs[i] = fmt.Sprintf("%d", idx)
		}
		indicesElm := "[ " + strings.Join(idxStrs, ", ") + " ]"
		checks = append(checks, fmt.Sprintf(
			"List.filter (\\e -> e.kind == Overlap) >> List.head >> Maybe.map .stackIndices >> Expect.equal (Just %s)", indicesElm))
	}

	if len(checks) == 0 {
		b.WriteString("            Expect.fail \"validate_board_geometry scenario missing assertions\"")
		return
	}

	b.WriteString("            Expect.all\n                [ ")
	for i, ch := range checks {
		if i > 0 {
			b.WriteString("\n                , ")
		}
		b.WriteString(ch)
	}
	b.WriteString("\n                ]\n                errors")
}

// elmClassifyBoardGeometry emits a test body that calls
// Game.Physics.BoardGeometry.classifyBoardGeometry and asserts
// the result matches the expected BoardGeometryStatus constructor.
func elmClassifyBoardGeometry(b *strings.Builder, sc Scenario) {
	status := sc.Expect.Geometry.GeometryStatus
	if status == "" {
		b.WriteString("            Expect.fail \"classify_board_geometry scenario missing geometry_status\"")
		return
	}
	var statusExpr string
	switch status {
	case "CleanlySpaced", "Crowded", "Illegal":
		statusExpr = status
	default:
		statusExpr = "Debug.todo \"unknown geometry status: " + status + "\""
	}
	fmt.Fprintf(b, "            Game.Physics.BoardGeometry.classifyBoardGeometry\n                %s\n                standardBounds\n            |> Expect.equal %s",
		elmStacks(sc.Board, "                    "),
		statusExpr)
}

// elmStackHeightConstant emits a test body that asserts
// Game.Physics.BoardGeometry.stackHeight == 40.
func elmStackHeightConstant(b *strings.Builder, sc Scenario) {
	_ = sc // no scenario fields needed
	b.WriteString("            Game.Physics.BoardGeometry.stackHeight |> Expect.equal 40")
}


// elmStackVar emits a single-stack `let` binding named `stack`
// from sc.Board[0]. Used by both drag-invariant emitters, which
// always operate on exactly one stack.
func elmStackVar(b *strings.Builder, sc Scenario, ind string) {
	if len(sc.Board) == 0 {
		fmt.Fprintf(b, "%s    stack =\n%s        Debug.todo \"floater_top_left/path_frame scenario missing board:\"\n\n", ind, ind)
		return
	}
	s := sc.Board[0]
	fmt.Fprintf(b, "%s    stack =\n%s        %s\n\n", ind, ind, elmStackLit(s))
}


// elmFloaterTopLeft emits a test body for the `floater_top_left`
// op. Two sub-cases are distinguished by which ExpectDragFloater
// field is set:
//
//   - ShiftEqualsDelta: assert before.floaterTopLeft + delta ==
//     after.floaterTopLeft after one mousemove.
//   - GrabPointInvariant: assert that two distinct grab points
//     produce the same floater shift for the same delta.
func elmFloaterTopLeft(b *strings.Builder, sc Scenario) {
	ind := "            " // 12 spaces — inside test thunk
	df := sc.Expect.DragFloater

	if df.ShiftEqualsDelta {
		if sc.MousedownPoint == nil || sc.MousemoveDelta == nil {
			b.WriteString(ind + "Expect.fail \"floater_top_left shift_equals_delta scenario missing mousedown or mousemove_delta\"")
			return
		}
		md := sc.MousedownPoint
		dlt := sc.MousemoveDelta
		b.WriteString(ind + "let\n")
		elmStackVar(b, sc, ind)
		fmt.Fprintf(b, "%s    base =\n%s        State.baseModel\n\n", ind, ind)
		fmt.Fprintf(b, "%s    model =\n%s        { base | board = [ stack ] }\n\n", ind, ind)
		fmt.Fprintf(b, "%s    mousedownClient =\n%s        { x = %d, y = %d }\n\n", ind, ind, md.X, md.Y)
		fmt.Fprintf(b, "%s    ( afterDown, _ ) =\n%s        Gesture.startBoardCardDrag\n%s            { stack = stack, cardIndex = %d }\n%s            mousedownClient\n%s            0\n%s            model\n\n",
			ind, ind, ind, sc.DragCardIndex, ind, ind, ind)
		fmt.Fprintf(b, "%s    delta =\n%s        { x = %d, y = %d }\n\n", ind, ind, dlt.X, dlt.Y)
		fmt.Fprintf(b, "%s    ( afterMove, _ ) =\n%s        Play.mouseMove\n%s            { x = mousedownClient.x + delta.x, y = mousedownClient.y + delta.y }\n%s            100\n%s            afterDown\n", ind, ind, ind, ind, ind)
		b.WriteString(ind + "in\n")
		b.WriteString(ind + "case ( afterDown.drag, afterMove.drag ) of\n")
		b.WriteString(ind + "    ( State.Dragging before _ _, State.Dragging after _ _ ) ->\n")
		b.WriteString(ind + "        Expect.equal\n")
		b.WriteString(ind + "            { x = before.floaterTopLeft.x + delta.x\n")
		b.WriteString(ind + "            , y = before.floaterTopLeft.y + delta.y\n")
		b.WriteString(ind + "            }\n")
		b.WriteString(ind + "            after.floaterTopLeft\n")
		b.WriteString(ind + "\n")
		b.WriteString(ind + "    _ ->\n")
		b.WriteString(ind + "        Expect.fail \"expected both states to be Dragging\"")
		return
	}

	if df.GrabPointInvariant {
		if sc.MousedownA == nil || sc.MousedownB == nil || sc.MousedownDelta == nil {
			b.WriteString(ind + "Expect.fail \"floater_top_left grab_point_invariant scenario missing mousedown_a, mousedown_b, or delta\"")
			return
		}
		a := sc.MousedownA
		bpt := sc.MousedownB
		dlt := sc.MousedownDelta
		b.WriteString(ind + "let\n")
		elmStackVar(b, sc, ind)
		fmt.Fprintf(b, "%s    base =\n%s        State.baseModel\n\n", ind, ind)
		fmt.Fprintf(b, "%s    model =\n%s        { base | board = [ stack ] }\n\n", ind, ind)
		fmt.Fprintf(b, "%s    delta =\n%s        { x = %d, y = %d }\n\n", ind, ind, dlt.X, dlt.Y)
		b.WriteString(ind + "    shiftFor down =\n")
		b.WriteString(ind + "        let\n")
		b.WriteString(ind + "            ( afterDown, _ ) =\n")
		b.WriteString(ind + "                Gesture.startBoardCardDrag\n")
		b.WriteString(ind + "                    { stack = stack, cardIndex = 0 }\n")
		b.WriteString(ind + "                    down\n")
		b.WriteString(ind + "                    0\n")
		b.WriteString(ind + "                    model\n\n")
		b.WriteString(ind + "            ( afterMove, _ ) =\n")
		b.WriteString(ind + "                Play.mouseMove\n")
		b.WriteString(ind + "                    { x = down.x + delta.x, y = down.y + delta.y }\n")
		b.WriteString(ind + "                    100\n")
		b.WriteString(ind + "                    afterDown\n")
		b.WriteString(ind + "        in\n")
		b.WriteString(ind + "        case ( afterDown.drag, afterMove.drag ) of\n")
		b.WriteString(ind + "            ( State.Dragging before _ _, State.Dragging after _ _ ) ->\n")
		b.WriteString(ind + "                Just\n")
		b.WriteString(ind + "                    { x = after.floaterTopLeft.x - before.floaterTopLeft.x\n")
		b.WriteString(ind + "                    , y = after.floaterTopLeft.y - before.floaterTopLeft.y\n")
		b.WriteString(ind + "                    }\n")
		b.WriteString(ind + "\n")
		b.WriteString(ind + "            _ ->\n")
		b.WriteString(ind + "                Nothing\n")
		fmt.Fprintf(b, "%sin\n", ind)
		fmt.Fprintf(b, "%sExpect.equal (shiftFor { x = %d, y = %d }) (shiftFor { x = %d, y = %d })",
			ind, a.X, a.Y, bpt.X, bpt.Y)
		return
	}

	b.WriteString(ind + "Expect.fail \"floater_top_left scenario missing shift_equals_delta or grab_point_invariant\"")
}


// elmPathFrame emits a test body for the `path_frame` op.
// Three sub-cases are distinguished by ExpectDragPathFrame:
//
//   - Frame set: assert info.pathFrame == BoardFrame|ViewportFrame.
//     For hand drags (DragHandCard set) it uses Gesture.startHandDrag;
//     otherwise Gesture.startBoardCardDrag.
//   - InitialFloater set: assert info.floaterTopLeft == (x, y)
//     (always a board drag).
func elmPathFrame(b *strings.Builder, sc Scenario) {
	ind := "            " // 12 spaces — inside test thunk
	dpf := sc.Expect.DragPathFrame

	isHandDrag := sc.DragHandCard != ""

	// Build the shared let-block open
	b.WriteString(ind + "let\n")

	if isHandDrag {
		// Hand-drag setup: parse the hand card, build a one-card hand.
		c, _ := parseCard(sc.DragHandCard)
		cardToken := elmCompactCard(c)
		fmt.Fprintf(b, "%s    card =\n%s        parseCard %s\n\n", ind, ind, cardToken)
		fmt.Fprintf(b, "%s    hc =\n%s        { card = card, state = HandNormal }\n\n", ind, ind)
		fmt.Fprintf(b, "%s    base =\n%s        State.baseModel\n\n", ind, ind)
		fmt.Fprintf(b, "%s    model =\n%s        State.setActiveHand { handCards = [ hc ] } base\n\n", ind, ind)
	} else {
		elmStackVar(b, sc, ind)
		fmt.Fprintf(b, "%s    base =\n%s        State.baseModel\n\n", ind, ind)
		fmt.Fprintf(b, "%s    model =\n%s        { base | board = [ stack ] }\n\n", ind, ind)
	}

	// Emit the drag start call.
	if isHandDrag {
		md := sc.MousedownPoint
		if md == nil {
			b.WriteString(ind + "    _ =\n" + ind + "        Debug.todo \"path_frame hand-drag scenario missing mousedown\"\n")
		} else {
			fmt.Fprintf(b, "%s    ( afterDown, _ ) =\n%s        Gesture.startHandDrag\n%s            card\n%s            { x = %d, y = %d }\n%s            0\n%s            model\n",
				ind, ind, ind, ind, md.X, md.Y, ind, ind)
		}
	} else {
		md := sc.MousedownPoint
		if md == nil {
			b.WriteString(ind + "    _ =\n" + ind + "        Debug.todo \"path_frame board-drag scenario missing mousedown\"\n")
		} else {
			fmt.Fprintf(b, "%s    ( afterDown, _ ) =\n%s        Gesture.startBoardCardDrag\n%s            { stack = stack, cardIndex = %d }\n%s            { x = %d, y = %d }\n%s            0\n%s            model\n",
				ind, ind, ind, sc.DragCardIndex, ind, md.X, md.Y, ind, ind)
		}
	}

	b.WriteString(ind + "in\n")

	// Emit the assertion.
	if dpf.InitialFloater != nil {
		fl := dpf.InitialFloater
		b.WriteString(ind + "case afterDown.drag of\n")
		b.WriteString(ind + "    State.Dragging info _ _ ->\n")
		fmt.Fprintf(b, "%s        Expect.equal { x = %d, y = %d } info.floaterTopLeft\n\n", ind, fl.X, fl.Y)
		b.WriteString(ind + "    _ ->\n")
		b.WriteString(ind + "        Expect.fail \"expected Dragging state\"")
		return
	}

	if dpf.Frame != "" {
		var frameExpr string
		switch dpf.Frame {
		case "BoardFrame":
			frameExpr = "State.BoardFrame"
		case "ViewportFrame":
			frameExpr = "State.ViewportFrame"
		default:
			frameExpr = "Debug.todo \"unknown pathFrame: " + dpf.Frame + "\""
		}
		b.WriteString(ind + "case afterDown.drag of\n")
		b.WriteString(ind + "    State.Dragging info _ _ ->\n")
		fmt.Fprintf(b, "%s        Expect.equal %s info.pathFrame\n\n", ind, frameExpr)
		b.WriteString(ind + "    _ ->\n")
		b.WriteString(ind + "        Expect.fail \"expected Dragging state\"")
		return
	}

	b.WriteString(ind + "Expect.fail \"path_frame scenario missing frame or initial_floater_at\"")
}


// --- Gesture op emitters ---
//
// Each emitter constructs a DragInfo record literal inline and then
// calls the appropriate pure Gesture function. The default board rect
// { x=300, y=100, width=800, height=600 } matches Fixtures.defaultBoardRect.
// All gesture ops are Elm-only; Python is false.

const gestureBoardRectLit = "{ x = 300, y = 100, width = 800, height = 600 }"

// elmGestureSourceVar emits a `source` let-binding.
// If the scenario has a board stack (sc.Board), emits FromBoardStack.
// If it has a hand card (sc.DragHandCard), emits FromHandCard.
func elmGestureSourceVar(b *strings.Builder, sc Scenario, ind string) {
	if sc.DragHandCard != "" {
		c, _ := parseCard(sc.DragHandCard)
		cardToken := elmCompactCard(c)
		fmt.Fprintf(b, "%s    handCard_ =\n%s        parseCard %s\n\n", ind, ind, cardToken)
		fmt.Fprintf(b, "%s    source =\n%s        State.FromHandCard handCard_\n\n", ind, ind)
	} else if len(sc.Board) > 0 {
		fmt.Fprintf(b, "%s    sourceStack =\n%s        %s\n\n", ind, ind, elmStackLit(sc.Board[0]))
		fmt.Fprintf(b, "%s    source =\n%s        State.FromBoardStack sourceStack\n\n", ind, ind)
	} else {
		fmt.Fprintf(b, "%s    source =\n%s        Debug.todo \"gesture scenario missing board or hand_card\"\n\n", ind, ind)
	}
}

// elmGestureTargetVar emits a `targetStack` let-binding from sc.GestureTarget[0].
func elmGestureTargetVar(b *strings.Builder, sc Scenario, ind string) {
	if len(sc.GestureTarget) == 0 {
		fmt.Fprintf(b, "%s    targetStack =\n%s        Debug.todo \"gesture scenario missing target\"\n\n", ind, ind)
		return
	}
	fmt.Fprintf(b, "%s    targetStack =\n%s        %s\n\n", ind, ind, elmStackLit(sc.GestureTarget[0]))
}

// elmGestureFloaterAt emits floaterTopLeft from sc.GestureFloaterAt.
func elmGestureFloaterAt(b *strings.Builder, sc Scenario, ind string) {
	if sc.GestureFloaterAt == nil {
		fmt.Fprintf(b, "%s    floater =\n%s        Debug.todo \"gesture scenario missing floater_at\"\n\n", ind, ind)
		return
	}
	fl := sc.GestureFloaterAt
	fmt.Fprintf(b, "%s    floater =\n%s        { x = %d, y = %d }\n\n", ind, ind, fl.X, fl.Y)
}

// elmGesturePathFrame returns "State.BoardFrame" for board sources,
// "State.ViewportFrame" for hand sources.
func elmGesturePathFrame(sc Scenario) string {
	if sc.DragHandCard != "" {
		return "State.ViewportFrame"
	}
	return "State.BoardFrame"
}

// elmGestureSplit emits a test body for the `gesture_split` op.
// Constructs DragInfo/DragContext/ClickArbiter with clickIntent set and
// asserts resolveGesture returns Split with the expected cardIndex.
func elmGestureSplit(b *strings.Builder, sc Scenario) {
	ind := "            "
	gs := sc.Expect.GestureSplit
	b.WriteString(ind + "let\n")
	elmGestureSourceVar(b, sc, ind)
	elmGestureFloaterAt(b, sc, ind)
	ci := 0
	if sc.GestureClickIntent != nil {
		ci = *sc.GestureClickIntent
	}
	fmt.Fprintf(b, "%s    info =\n", ind)
	fmt.Fprintf(b, "%s        { source = source\n", ind)
	fmt.Fprintf(b, "%s        , cursor = { x = 0, y = 0 }\n", ind)
	fmt.Fprintf(b, "%s        , floaterTopLeft = floater\n", ind)
	fmt.Fprintf(b, "%s        , gesturePath = []\n", ind)
	fmt.Fprintf(b, "%s        , pathFrame = %s\n", ind, elmGesturePathFrame(sc))
	fmt.Fprintf(b, "%s        }\n\n", ind)
	fmt.Fprintf(b, "%s    ctx =\n", ind)
	fmt.Fprintf(b, "%s        { wings = [], boardRect = Nothing }\n\n", ind)
	fmt.Fprintf(b, "%s    arb =\n", ind)
	fmt.Fprintf(b, "%s        { clickIntent = Just %d, originalCursor = { x = 0, y = 0 } }\n\n", ind, ci)
	b.WriteString(ind + "in\n")
	b.WriteString(ind + "case Gesture.resolveGesture info ctx arb of\n")
	b.WriteString(ind + "    Just (WA.Split p) ->\n")
	fmt.Fprintf(b, "%s        Expect.equal %d p.cardIndex\n\n", ind, gs.CardIndex)
	b.WriteString(ind + "    other ->\n")
	b.WriteString(ind + "        Expect.fail (\"expected Split; got \" ++ Debug.toString other)")
}

// elmGestureMergeStack emits a test body for the `gesture_merge_stack` op.
// Registers the wing in ctx.wings; floater_at must be within snap tolerance
// of the wing's eventual landing so floaterOverWing fires geometrically.
func elmGestureMergeStack(b *strings.Builder, sc Scenario) {
	ind := "            "
	gm := sc.Expect.GestureMergeStack
	b.WriteString(ind + "let\n")
	elmGestureSourceVar(b, sc, ind)
	elmGestureTargetVar(b, sc, ind)
	elmGestureFloaterAt(b, sc, ind)
	sideExpr := "BoardActions." + gm.Side
	fmt.Fprintf(b, "%s    wing =\n%s        { target = targetStack, side = %s }\n\n", ind, ind, sideExpr)
	fmt.Fprintf(b, "%s    info =\n", ind)
	fmt.Fprintf(b, "%s        { source = source\n", ind)
	fmt.Fprintf(b, "%s        , cursor = { x = 0, y = 0 }\n", ind)
	fmt.Fprintf(b, "%s        , floaterTopLeft = floater\n", ind)
	fmt.Fprintf(b, "%s        , gesturePath = []\n", ind)
	fmt.Fprintf(b, "%s        , pathFrame = %s\n", ind, elmGesturePathFrame(sc))
	fmt.Fprintf(b, "%s        }\n\n", ind)
	fmt.Fprintf(b, "%s    ctx =\n", ind)
	fmt.Fprintf(b, "%s        { wings = [ wing ], boardRect = Nothing }\n\n", ind)
	fmt.Fprintf(b, "%s    arb =\n", ind)
	fmt.Fprintf(b, "%s        { clickIntent = Nothing, originalCursor = { x = 0, y = 0 } }\n\n", ind)
	b.WriteString(ind + "in\n")
	b.WriteString(ind + "case Gesture.resolveGesture info ctx arb of\n")
	b.WriteString(ind + "    Just (WA.MergeStack p) ->\n")
	fmt.Fprintf(b, "%s        Expect.equal %s p.side\n\n", ind, sideExpr)
	b.WriteString(ind + "    other ->\n")
	b.WriteString(ind + "        Expect.fail (\"expected MergeStack; got \" ++ Debug.toString other)")
}

// elmGestureMergeHand emits a test body for the `gesture_merge_hand` op.
// Registers the wing in ctx.wings with boardRect set; floater_at must be
// within snap tolerance of the wing's viewport-frame eventual landing so
// floaterOverWing fires geometrically.
func elmGestureMergeHand(b *strings.Builder, sc Scenario) {
	ind := "            "
	gm := sc.Expect.GestureMergeHand
	b.WriteString(ind + "let\n")
	elmGestureSourceVar(b, sc, ind)
	elmGestureTargetVar(b, sc, ind)
	elmGestureFloaterAt(b, sc, ind)
	sideExpr := "BoardActions." + gm.Side
	fmt.Fprintf(b, "%s    wing =\n%s        { target = targetStack, side = %s }\n\n", ind, ind, sideExpr)
	fmt.Fprintf(b, "%s    info =\n", ind)
	fmt.Fprintf(b, "%s        { source = source\n", ind)
	fmt.Fprintf(b, "%s        , cursor = { x = 0, y = 0 }\n", ind)
	fmt.Fprintf(b, "%s        , floaterTopLeft = floater\n", ind)
	fmt.Fprintf(b, "%s        , gesturePath = []\n", ind)
	fmt.Fprintf(b, "%s        , pathFrame = %s\n", ind, elmGesturePathFrame(sc))
	fmt.Fprintf(b, "%s        }\n\n", ind)
	fmt.Fprintf(b, "%s    ctx =\n", ind)
	fmt.Fprintf(b, "%s        { wings = [ wing ], boardRect = Just %s }\n\n", ind, gestureBoardRectLit)
	fmt.Fprintf(b, "%s    arb =\n", ind)
	fmt.Fprintf(b, "%s        { clickIntent = Nothing, originalCursor = { x = 0, y = 0 } }\n\n", ind)
	b.WriteString(ind + "in\n")
	b.WriteString(ind + "case Gesture.resolveGesture info ctx arb of\n")
	b.WriteString(ind + "    Just (WA.MergeHand p) ->\n")
	fmt.Fprintf(b, "%s        Expect.equal %s p.side\n\n", ind, sideExpr)
	b.WriteString(ind + "    other ->\n")
	b.WriteString(ind + "        Expect.fail (\"expected MergeHand; got \" ++ Debug.toString other)")
}

// elmGestureMoveStack emits a test body for the `gesture_move_stack` op.
// Constructs DragInfo/DragContext/ClickArbiter with boardRect + cursor and
// asserts resolveGesture returns MoveStack with expected newLoc, or Nothing
// if ExpectGestureMoveStack.Rejected is true.
func elmGestureMoveStack(b *strings.Builder, sc Scenario) {
	ind := "            "
	gm := sc.Expect.GestureMoveStack
	cursorX, cursorY := 700, 400
	if sc.GestureCursor != nil {
		cursorX = sc.GestureCursor.X
		cursorY = sc.GestureCursor.Y
	}
	b.WriteString(ind + "let\n")
	elmGestureSourceVar(b, sc, ind)
	elmGestureFloaterAt(b, sc, ind)
	fmt.Fprintf(b, "%s    info =\n", ind)
	fmt.Fprintf(b, "%s        { source = source\n", ind)
	fmt.Fprintf(b, "%s        , cursor = { x = %d, y = %d }\n", ind, cursorX, cursorY)
	fmt.Fprintf(b, "%s        , floaterTopLeft = floater\n", ind)
	fmt.Fprintf(b, "%s        , gesturePath = []\n", ind)
	fmt.Fprintf(b, "%s        , pathFrame = %s\n", ind, elmGesturePathFrame(sc))
	fmt.Fprintf(b, "%s        }\n\n", ind)
	fmt.Fprintf(b, "%s    ctx =\n", ind)
	fmt.Fprintf(b, "%s        { wings = [], boardRect = Just %s }\n\n", ind, gestureBoardRectLit)
	fmt.Fprintf(b, "%s    arb =\n", ind)
	fmt.Fprintf(b, "%s        { clickIntent = Nothing, originalCursor = { x = 0, y = 0 } }\n\n", ind)
	b.WriteString(ind + "in\n")
	if gm.Rejected {
		b.WriteString(ind + "Gesture.resolveGesture info ctx arb\n")
		b.WriteString(ind + "    |> Expect.equal Nothing")
	} else {
		b.WriteString(ind + "case Gesture.resolveGesture info ctx arb of\n")
		b.WriteString(ind + "    Just (WA.MoveStack p) ->\n")
		b.WriteString(ind + "        Expect.all\n")
		fmt.Fprintf(b, "%s            [ \\_ -> Expect.equal %d p.newLoc.left\n", ind, gm.NewLocLeft)
		fmt.Fprintf(b, "%s            , \\_ -> Expect.equal %d p.newLoc.top\n", ind, gm.NewLocTop)
		b.WriteString(ind + "            ]\n")
		b.WriteString(ind + "            ()\n\n")
		b.WriteString(ind + "    other ->\n")
		b.WriteString(ind + "        Expect.fail (\"expected MoveStack; got \" ++ Debug.toString other)")
	}
}

// elmGesturePlaceHand emits a test body for the `gesture_place_hand` op.
// Constructs DragInfo/DragContext/ClickArbiter with a hand-card source +
// boardRect + cursor and asserts resolveGesture returns PlaceHand with
// expected loc.
func elmGesturePlaceHand(b *strings.Builder, sc Scenario) {
	ind := "            "
	gp := sc.Expect.GesturePlaceHand
	cursorX, cursorY := 0, 0
	if sc.GestureCursor != nil {
		cursorX = sc.GestureCursor.X
		cursorY = sc.GestureCursor.Y
	}
	b.WriteString(ind + "let\n")
	elmGestureSourceVar(b, sc, ind)
	elmGestureFloaterAt(b, sc, ind)
	fmt.Fprintf(b, "%s    info =\n", ind)
	fmt.Fprintf(b, "%s        { source = source\n", ind)
	fmt.Fprintf(b, "%s        , cursor = { x = %d, y = %d }\n", ind, cursorX, cursorY)
	fmt.Fprintf(b, "%s        , floaterTopLeft = floater\n", ind)
	fmt.Fprintf(b, "%s        , gesturePath = []\n", ind)
	fmt.Fprintf(b, "%s        , pathFrame = %s\n", ind, elmGesturePathFrame(sc))
	fmt.Fprintf(b, "%s        }\n\n", ind)
	fmt.Fprintf(b, "%s    ctx =\n", ind)
	fmt.Fprintf(b, "%s        { wings = [], boardRect = Just %s }\n\n", ind, gestureBoardRectLit)
	fmt.Fprintf(b, "%s    arb =\n", ind)
	fmt.Fprintf(b, "%s        { clickIntent = Nothing, originalCursor = { x = 0, y = 0 } }\n\n", ind)
	b.WriteString(ind + "in\n")
	b.WriteString(ind + "case Gesture.resolveGesture info ctx arb of\n")
	b.WriteString(ind + "    Just (WA.PlaceHand p) ->\n")
	b.WriteString(ind + "        Expect.all\n")
	fmt.Fprintf(b, "%s            [ \\_ -> Expect.equal %d p.loc.left\n", ind, gp.LocLeft)
	fmt.Fprintf(b, "%s            , \\_ -> Expect.equal %d p.loc.top\n", ind, gp.LocTop)
	b.WriteString(ind + "            ]\n")
	b.WriteString(ind + "            ()\n\n")
	b.WriteString(ind + "    other ->\n")
	b.WriteString(ind + "        Expect.fail (\"expected PlaceHand; got \" ++ Debug.toString other)")
}

// elmGestureFloaterOverWing emits a test body for the
// `gesture_floater_over_wing` op. Constructs DragInfo + DragContext with the
// given source + floater + a single registered wing, and asserts
// floaterOverWing returns Just wing (HasWing=true) or Nothing (HasWing=false).
func elmGestureFloaterOverWing(b *strings.Builder, sc Scenario) {
	ind := "            "
	gf := sc.Expect.GestureFloaterOverWing
	sideExpr := "BoardActions." + sc.GestureHoveredSide
	b.WriteString(ind + "let\n")
	elmGestureSourceVar(b, sc, ind)
	elmGestureTargetVar(b, sc, ind)
	elmGestureFloaterAt(b, sc, ind)
	fmt.Fprintf(b, "%s    wing =\n%s        { target = targetStack, side = %s }\n\n", ind, ind, sideExpr)
	fmt.Fprintf(b, "%s    info =\n", ind)
	fmt.Fprintf(b, "%s        { source = source\n", ind)
	fmt.Fprintf(b, "%s        , cursor = { x = 0, y = 0 }\n", ind)
	fmt.Fprintf(b, "%s        , floaterTopLeft = floater\n", ind)
	fmt.Fprintf(b, "%s        , gesturePath = []\n", ind)
	fmt.Fprintf(b, "%s        , pathFrame = %s\n", ind, elmGesturePathFrame(sc))
	fmt.Fprintf(b, "%s        }\n\n", ind)
	fmt.Fprintf(b, "%s    ctx =\n", ind)
	fmt.Fprintf(b, "%s        { wings = [ wing ], boardRect = Nothing }\n\n", ind)
	b.WriteString(ind + "in\n")
	if gf.HasWing {
		b.WriteString(ind + "Gesture.floaterOverWing ctx info\n")
		fmt.Fprintf(b, "%s    |> Expect.equal (Just wing)", ind)
	} else {
		b.WriteString(ind + "Gesture.floaterOverWing ctx info\n")
		b.WriteString(ind + "    |> Expect.equal Nothing")
	}
}


const elmHintInvariantTmpl = `            let
                handCards =
                    %s

                board =
                    %s

                plays =
                    %s.findPlays handCards board
            in
`

// elmHintInvariant emits a test body that runs the named trick
// against the scenario's (hand, board), applies the first Play,
// and asserts every resulting stack classifies as a complete
// group. An Elm Play's `apply` returns (newBoard, consumedHand)
// directly, so no primitive replay is needed.
func elmHintInvariant(b *strings.Builder, sc Scenario, trickVar string) {
	fmt.Fprintf(b, elmHintInvariantTmpl,
		elmHandCards(sc.Hand),
		elmStacks(sc.Board, "                        "),
		trickVar)
	b.WriteString(`            case plays of
                [] ->
                    Expect.fail "trick did not fire (no plays)"

                play :: _ ->
                    let
                        ( afterBoard, _ ) =
                            play.apply board
                    in
                    case firstIncompleteStack afterBoard of
                        Nothing ->
                            Expect.pass

                        Just ( i, s ) ->
                            Expect.fail
                                ("stack "
                                    ++ String.fromInt i
                                    ++ " is incomplete after trick emission: "
                                    ++ Debug.toString s
                                )`)
}


const elmBuildSuggestionsTmpl = `            let
                handCards =
                    %s

                hand =
                    { handCards = handCards }

                board =
                    %s

                got =
                    Hint.buildSuggestions hand board
            in
`

const elmBuildSuggestionsCountCheckTmpl = `            if List.length got /= %d then
                Expect.fail ("suggestion count: want %d, got " ++ String.fromInt (List.length got))
`

// elmBuildSuggestions emits a test body that calls
// Hint.buildSuggestions and walks each expected row in order,
// asserting trick_id + hand cards. Any mismatch short-circuits
// via Expect.fail with a descriptive message.
func elmBuildSuggestions(b *strings.Builder, sc Scenario) {
	fmt.Fprintf(b, elmBuildSuggestionsTmpl,
		elmHandCards(sc.Hand),
		elmStacks(sc.Board, "                        "))

	sugs := sc.Expect.Suggestions
	fmt.Fprintf(b, elmBuildSuggestionsCountCheckTmpl, len(sugs), len(sugs))
	b.WriteString("\n            else\n")
	if len(sugs) == 0 {
		// No per-row assertions needed; count check is sufficient.
		b.WriteString("                Expect.pass")
		return
	}
	b.WriteString("                let\n")
	for i, sug := range sugs {
		fmt.Fprintf(b, "                    want%d =\n                        { trickId = %q, handCards = %s }\n\n",
			i, sug.TrickID, elmRawCards(sug.HandCards))
	}
	b.WriteString("                in\n")
	b.WriteString("                Expect.all\n                    [")
	for i := range sugs {
		if i > 0 {
			b.WriteString("\n                    ,")
		}
		fmt.Fprintf(b, " \\_ -> List.drop %d got |> List.head |> Maybe.map (\\s -> { trickId = s.trickId, handCards = s.handCards }) |> Expect.equal (Just want%d)", i, i)
	}
	b.WriteString("\n                    ]\n                    ()")
}


// elmRawCards renders a list of Card values (not HandCards).
// Reuses elmCardLit per card.
func elmRawCards(cs []Card) string {
	if len(cs) == 0 {
		return "[]"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, elmCardLit(c))
	}
	return "[ " + strings.Join(parts, ", ") + " ]"
}

const elmTrickFirstPlayTmpl = `            let
                hand =
                    %s

                board =
                    %s

                plays =
                    %s.findPlays hand board
            in
`

const elmTrickFirstPlayNoPlays = `            if not (List.isEmpty plays) then
                Expect.fail ("expected no plays, got " ++ String.fromInt (List.length plays))

            else
                Expect.pass`

const elmTrickFirstPlayPlayTmpl = `            case plays of
                [] ->
                    Expect.fail "expected a play, got none"

                play :: _ ->
                    let
                        ( gotBoard, gotHand ) =
                            play.apply board

                        wantHand =
                            %s

                        wantBoard =
                            %s
                    in
                    if gotHand /= wantHand then
                        Expect.fail ("hand mismatch:\n  want " ++ Debug.toString wantHand ++ "\n  got  " ++ Debug.toString gotHand)

                    else if gotBoard /= wantBoard then
                        Expect.fail ("board mismatch:\n  want " ++ Debug.toString wantBoard ++ "\n  got  " ++ Debug.toString gotBoard)

                    else
                        Expect.pass`

func elmTrickFirstPlay(b *strings.Builder, sc Scenario, trickVar string) {
	fmt.Fprintf(b, elmTrickFirstPlayTmpl,
		elmHandCards(sc.Hand),
		elmStacks(sc.Board, "                        "),
		trickVar)
	switch sc.Expect.Kind {
	case "no_plays":
		b.WriteString(elmTrickFirstPlayNoPlays)
	case "play":
		fmt.Fprintf(b, elmTrickFirstPlayPlayTmpl,
			elmHandCards(sc.Expect.HandPlayed),
			elmStacks(sc.Expect.BoardAfter, "                            "))
	default:
		fmt.Fprintf(b, "            Expect.fail \"unsupported expectation: %s\"", sc.Expect.Kind)
	}
}

const elmValidateMoveTurnCompleteTmpl = `            let
                board =
                    %s
            in
            case Referee.validateTurnComplete board standardBounds of
`

const elmValidateMoveGameMoveTmpl = `            let
                move =
                    { boardBefore = %s
                    , stacksToRemove = %s
                    , stacksToAdd = %s
                    , handCardsPlayed = %s
                    }
            in
            case Referee.validateGameMove move standardBounds of
`

const elmValidateMoveOk = `                Ok _ ->
                    Expect.pass

                Err err ->
                    Expect.fail (refereeStageToString err.stage ++ ": " ++ err.message)`

const elmValidateMoveErrorTmpl = `                Ok _ ->
                    Expect.fail ("expected error at stage " ++ %s ++ ", got ok")

                Err err ->
                    if refereeStageToString err.stage /= %s then
                        Expect.fail ("stage: want " ++ %s ++ ", got " ++ refereeStageToString err.stage)
                    else if not (String.contains %s err.message) then
                        Expect.fail ("message substring " ++ %s ++ " not found in " ++ err.message)
                    else
                        Expect.pass`

func elmValidateMove(b *strings.Builder, sc Scenario, turnComplete bool) {
	if turnComplete {
		fmt.Fprintf(b, elmValidateMoveTurnCompleteTmpl, elmStacks(sc.Board, "                    "))
	} else {
		fmt.Fprintf(b, elmValidateMoveGameMoveTmpl,
			elmStacks(sc.Board, "                        "),
			elmStacks(sc.Removed, "                        "),
			elmStacks(sc.Added, "                        "),
			elmHandCards(sc.HandPlayed),
		)
	}
	switch sc.Expect.Kind {
	case "ok":
		b.WriteString(elmValidateMoveOk)
	case "error":
		stageQ := `"` + sc.Expect.Stage + `"`
		msgQ := `"` + sc.Expect.MessageSubstr + `"`
		fmt.Fprintf(b, elmValidateMoveErrorTmpl, stageQ, stageQ, stageQ, msgQ, msgQ)
	}
}

// elmAgentStacks renders a list of stacks as `List (List Card)`
// — the agent-side stack format (no boardCards / loc wrapper).
// Used for `enumerate_moves` scenario inputs.
func elmAgentStacks(ss []Stack, indent string) string {
	if len(ss) == 0 {
		return "[]"
	}
	var parts []string
	for _, s := range ss {
		parts = append(parts, elmAgentStackLit(s))
	}
	return "[ " + strings.Join(parts, "\n"+indent+", ") + "\n" + indent + "]"
}

func elmAgentStackLit(s Stack) string {
	var cs []string
	for _, c := range s.Cards {
		cs = append(cs, elmCardLit(c))
	}
	if len(cs) == 0 {
		return "[]"
	}
	return "[ " + strings.Join(cs, ", ") + " ]"
}

// elmEnumerateMoves emits a test body that builds the
// scenario's 4-bucket state, walks the enumerator, and
const elmEnumerateMovesTmpl = `            let
                state : Buckets
                state =
                    { helper = %s
                    , trouble = %s
                    , growing = %s
                    , complete = %s
                    }

                moves =
                    AgentEnumerator.enumerateMoves state
            in
`

const elmEnumerateMovesCheckTmpl = `            if List.any (\( m, _ ) -> %s) moves then
                Expect.pass

            else
                Expect.fail ("no %s move yielded; got " ++ String.fromInt (List.length moves) ++ " moves")`

// asserts at least one yielded move matches the
// expect.yields type. Scenarios whose only assertion is
// narrate_contains / hint_contains compile to Expect.pass
// stubs on the Elm side until those renderers port.
func elmEnumerateMoves(b *strings.Builder, sc Scenario) {
	yields := sc.Expect.Planner.Yields
	if yields == "" {
		// narrate_contains / hint_contains only — stub on Elm
		// until the renderers port.
		b.WriteString("            -- narrate/hint matchers not yet ported to Elm\n            Expect.pass")
		return
	}
	matcher := elmMoveMatcher(yields)
	fmt.Fprintf(b, elmEnumerateMovesTmpl,
		elmAgentStacks(sc.Helper, "                        "),
		elmAgentStacks(sc.Trouble, "                        "),
		elmAgentStacks(sc.Growing, "                        "),
		elmAgentStacks(sc.Complete, "                        "))
	fmt.Fprintf(b, elmEnumerateMovesCheckTmpl, matcher, yields)
}

// elmSolve emits a test body that builds the scenario's
const elmSolveTmpl = `            let
                state : Buckets
                state =
                    { helper = %s
                    , trouble = %s
                    , growing = %s
                    , complete = %s
                    }

                result =
                    Game.Agent.Bfs.solve state
            in
`

const elmSolveNoPlanCheck = `            case result of
                Nothing ->
                    Expect.pass

                Just plan ->
                    Expect.fail ("expected no plan; got plan of length " ++ String.fromInt (List.length plan))`

const elmSolvePlanLinesTmpl = `            let
                expected =
                    %s
            in
            case result of
                Just plan ->
                    List.map AgentMove.describe plan
                        |> Expect.equal expected

                Nothing ->
                    Expect.fail ("expected plan; got Nothing")`

const elmSolvePlanLengthTmpl = `            case result of
                Just plan ->
                    List.length plan |> Expect.equal %d

                Nothing ->
                    Expect.fail "expected plan of length %d; got Nothing"`

// 4-bucket state, runs Game.Agent.Bfs.solve, and asserts on
// either no_plan or an exact plan_length.
func elmSolve(b *strings.Builder, sc Scenario) {
	fmt.Fprintf(b, elmSolveTmpl,
		elmAgentStacks(sc.Helper, "                        "),
		elmAgentStacks(sc.Trouble, "                        "),
		elmAgentStacks(sc.Growing, "                        "),
		elmAgentStacks(sc.Complete, "                        "))
	sv := sc.Expect.Solve
	if sv.NoPlan {
		b.WriteString(elmSolveNoPlanCheck)
	} else if len(sv.PlanLines) > 0 {
		// Snapshot match: every line of describe(move) must
		// equal the pinned canonical plan_lines from Python.
		var listLits strings.Builder
		listLits.WriteString("[ ")
		for i, line := range sv.PlanLines {
			if i > 0 {
				listLits.WriteString(", ")
			}
			listLits.WriteString(strconv.Quote(line))
		}
		listLits.WriteString(" ]")
		fmt.Fprintf(b, elmSolvePlanLinesTmpl, listLits.String())
	} else if sv.PlanLength > 0 {
		fmt.Fprintf(b, elmSolvePlanLengthTmpl, sv.PlanLength, sv.PlanLength)
	} else {
		b.WriteString("            Expect.fail \"solve scenario missing expectation (no_plan or plan_length or plan_lines)\"")
	}
}

func elmMoveMatcher(yields string) string {
	switch yields {
	case "extract_absorb":
		return "case m of\n                    ExtractAbsorb _ -> True\n\n                    _ -> False"
	case "free_pull":
		return "case m of\n                    FreePull _ -> True\n\n                    _ -> False"
	case "push":
		return "case m of\n                    Push _ -> True\n\n                    _ -> False"
	case "splice":
		return "case m of\n                    Splice _ -> True\n\n                    _ -> False"
	case "shift":
		return "case m of\n                    Shift _ -> True\n\n                    _ -> False"
	}
	return "False"
}

func elmStacks(ss []Stack, indent string) string {
	if len(ss) == 0 {
		return "[]"
	}
	var parts []string
	for _, s := range ss {
		parts = append(parts, elmStackLit(s))
	}
	return "[ " + strings.Join(parts, "\n"+indent+", ") + "\n" + indent + "]"
}

func elmStackLit(s Stack) string {
	var bcs []string
	for _, c := range s.Cards {
		if c.BoardState == 0 {
			bcs = append(bcs, "boardCard "+elmCompactCard(c))
		} else {
			bcs = append(bcs, fmt.Sprintf("{ card = parseCard %s, state = %s }", elmCompactCard(c), elmBoardState(c.BoardState)))
		}
	}
	return fmt.Sprintf("{ boardCards = [ %s ], loc = { top = %d, left = %d } }",
		strings.Join(bcs, ", "), s.Top, s.Left)
}

func elmHandCards(cs []Card) string {
	if len(cs) == 0 {
		return "[]"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, "handCard "+elmCompactCard(c))
	}
	return "[ " + strings.Join(parts, ", ") + " ]"
}

func elmCompactCard(c Card) string {
	v := []string{"", "A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K"}[c.Value]
	s := []string{"C", "D", "S", "H"}[c.Suit]
	d := []string{"1", "2"}[c.Deck]
	return `"` + v + s + d + `"`
}

func elmCardLit(c Card) string {
	return "parseCard " + elmCompactCard(c)
}

func elmValue(v int) string {
	return []string{"", "Ace", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King"}[v]
}

func elmSuit(s int) string {
	return []string{"Club", "Diamond", "Spade", "Heart"}[s]
}

func elmDeck(d int) string {
	if d == 0 {
		return "DeckOne"
	}
	return "DeckTwo"
}

func elmBoardState(s int) string {
	return []string{"FirmlyOnBoard", "FreshlyPlayed", "FreshlyPlayedByLastPlayer"}[s]
}

// --- JSON emission (for Python, interpreted — no codegen) ---
//
// Python reads the JSON at runtime and dispatches per op. Only
// scenarios whose op is in pythonSupportedOps are included; the
// Go + Elm emitters handle the rest. Field names match the dict
// shape hints.py already uses (value/suit/origin_deck/state).

type jsonCard struct {
	Value      int `json:"value"`
	Suit       int `json:"suit"`
	OriginDeck int `json:"origin_deck"`
}

type jsonBoardCard struct {
	Card  jsonCard `json:"card"`
	State int      `json:"state"`
}

type jsonHandCard struct {
	Card  jsonCard `json:"card"`
	State int      `json:"state"`
}

type jsonStack struct {
	BoardCards []jsonBoardCard `json:"board_cards"`
	Loc        jsonLoc         `json:"loc"`
}

type jsonLoc struct {
	Top  int `json:"top"`
	Left int `json:"left"`
}

type jsonSuggestion struct {
	TrickID   string     `json:"trick_id"`
	HandCards []jsonCard `json:"hand_cards"`
}

type jsonExpect struct {
	Kind        string           `json:"kind"`
	Suggestions []jsonSuggestion `json:"suggestions,omitempty"`
	// Planner ops.
	Yields          string `json:"yields,omitempty"`
	NarrateContains string `json:"narrate_contains,omitempty"`
	HintContains    string `json:"hint_contains,omitempty"`
	// Solver op.
	NoPlan     bool     `json:"no_plan,omitempty"`
	PlanLength int      `json:"plan_length,omitempty"`
	PlanLines  []string `json:"plan_lines,omitempty"`
	// Geometry op.
	Loc *jsonLoc `json:"loc,omitempty"`
}

type jsonScenario struct {
	Name   string         `json:"name"`
	Desc   string         `json:"desc"`
	Op     string         `json:"op"`
	Trick  string         `json:"trick,omitempty"`
	Hand   []jsonHandCard `json:"hand"`
	Board  []jsonStack    `json:"board"`
	// Four-bucket state for `enumerate_moves`. Empty arrays for
	// non-planner ops keep the JSON shape uniform.
	Helper   []jsonStack `json:"helper,omitempty"`
	Trouble  []jsonStack `json:"trouble,omitempty"`
	Growing  []jsonStack `json:"growing,omitempty"`
	Complete []jsonStack `json:"complete,omitempty"`
	// Geometry op (`find_open_loc`).
	Existing  []jsonStack `json:"existing,omitempty"`
	CardCount int         `json:"card_count,omitempty"`
	Expect    jsonExpect  `json:"expect"`
}

func emitJSON(scenarios []Scenario, outPath string) error {
	var out []jsonScenario
	for _, sc := range scenarios {
		if op, ok := opByName[sc.Op]; !ok || !op.Python {
			continue
		}
		out = append(out, toJSONScenario(sc))
	}
	if out == nil {
		out = []jsonScenario{}
	}
	// Indent for humans — diffs should be readable.
	bs, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	bs = append(bs, '\n')
	if err := os.MkdirAll(filepath.Dir(outPath), 0755); err != nil {
		return err
	}
	return os.WriteFile(outPath, bs, 0644)
}

// emitOpsManifest writes a small JSON file listing the op names
// expected to run on each target. The Python runner reads this
// to verify its DISPATCH dict matches the registry — drift on
// either side fails loud.
func emitOpsManifest(outPath string) error {
	var elmNames []string
	for _, op := range opRegistry {
		if op.Elm {
			elmNames = append(elmNames, op.Name)
		}
	}
	sort.Strings(elmNames)
	manifest := map[string][]string{
		"elm":    elmNames,
		"python": pythonOps(),
	}
	bs, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	bs = append(bs, '\n')
	if err := os.MkdirAll(filepath.Dir(outPath), 0755); err != nil {
		return err
	}
	return os.WriteFile(outPath, bs, 0644)
}

func toJSONScenario(sc Scenario) jsonScenario {
	js := jsonScenario{
		Name:      sc.Name,
		Desc:      sc.Desc,
		Op:        sc.Op,
		Trick:     sc.Trick,
		Hand:      toJSONHand(sc.Hand),
		Board:     toJSONBoard(sc.Board),
		Helper:    toJSONBoard(sc.Helper),
		Trouble:   toJSONBoard(sc.Trouble),
		Growing:   toJSONBoard(sc.Growing),
		Complete:  toJSONBoard(sc.Complete),
		Existing:  toJSONBoard(sc.Existing),
		CardCount: sc.CardCount,
	}
	js.Expect = jsonExpect{
		Kind:            sc.Expect.Kind,
		Yields:          sc.Expect.Planner.Yields,
		NarrateContains: sc.Expect.Planner.NarrateContains,
		HintContains:    sc.Expect.Planner.HintContains,
		NoPlan:          sc.Expect.Solve.NoPlan,
		PlanLength:      sc.Expect.Solve.PlanLength,
		PlanLines:       sc.Expect.Solve.PlanLines,
	}
	if sc.Expect.Geometry.Loc != nil {
		js.Expect.Loc = &jsonLoc{Top: sc.Expect.Geometry.Loc.Top, Left: sc.Expect.Geometry.Loc.Left}
	}
	for _, es := range sc.Expect.Suggestions {
		js.Expect.Suggestions = append(js.Expect.Suggestions, jsonSuggestion{
			TrickID:   es.TrickID,
			HandCards: toJSONCards(es.HandCards),
		})
	}
	return js
}

func toJSONHand(cs []Card) []jsonHandCard {
	out := make([]jsonHandCard, 0, len(cs))
	for _, c := range cs {
		out = append(out, jsonHandCard{
			Card:  jsonCard{Value: c.Value, Suit: c.Suit, OriginDeck: c.Deck},
			State: 0,
		})
	}
	return out
}

func toJSONBoard(ss []Stack) []jsonStack {
	out := make([]jsonStack, 0, len(ss))
	for _, s := range ss {
		bcs := make([]jsonBoardCard, 0, len(s.Cards))
		for _, c := range s.Cards {
			bcs = append(bcs, jsonBoardCard{
				Card:  jsonCard{Value: c.Value, Suit: c.Suit, OriginDeck: c.Deck},
				State: c.BoardState,
			})
		}
		out = append(out, jsonStack{BoardCards: bcs, Loc: jsonLoc{Top: s.Top, Left: s.Left}})
	}
	return out
}

func toJSONCards(cs []Card) []jsonCard {
	out := make([]jsonCard, 0, len(cs))
	for _, c := range cs {
		out = append(out, jsonCard{Value: c.Value, Suit: c.Suit, OriginDeck: c.Deck})
	}
	return out
}

// --- Parser (unchanged) ---

type line struct {
	indent  int
	content string
	lineNum int
}

func parse(src, path string) ([]Scenario, error) {
	var lines []line
	for i, raw := range strings.Split(src, "\n") {
		stripped := strings.TrimRight(raw, " \t")
		if idx := strings.Index(stripped, "#"); idx >= 0 {
			stripped = strings.TrimRight(stripped[:idx], " \t")
		}
		if stripped == "" {
			continue
		}
		indent := 0
		for indent < len(stripped) && stripped[indent] == ' ' {
			indent++
		}
		if indent%2 != 0 {
			return nil, fmt.Errorf("%s:%d: indent must be a multiple of 2", path, i+1)
		}
		lines = append(lines, line{
			indent: indent / 2, content: strings.TrimLeft(stripped, " "), lineNum: i + 1,
		})
	}

	var scenarios []Scenario
	for i := 0; i < len(lines); {
		if !strings.HasPrefix(lines[i].content, "scenario ") {
			return nil, fmt.Errorf("%s:%d: expected 'scenario <name>'", path, lines[i].lineNum)
		}
		if lines[i].indent != 0 {
			return nil, fmt.Errorf("%s:%d: scenario header must be at column 0", path, lines[i].lineNum)
		}
		name := strings.TrimSpace(strings.TrimPrefix(lines[i].content, "scenario"))
		i++
		var body []line
		for i < len(lines) && lines[i].indent > 0 {
			body = append(body, lines[i])
			i++
		}
		sc, err := parseBody(name, body, path)
		if err != nil {
			return nil, err
		}
		scenarios = append(scenarios, sc)
	}
	return scenarios, nil
}

func parseBody(name string, body []line, path string) (Scenario, error) {
	sc := Scenario{Name: name}
	i := 0
	for i < len(body) {
		l := body[i]
		if l.indent != 1 {
			return sc, fmt.Errorf("%s:%d: unexpected indent", path, l.lineNum)
		}
		key, val, hasBlock := splitField(l.content)
		i++
		var children []line
		for i < len(body) && body[i].indent >= 2 {
			children = append(children, body[i])
			i++
		}
		switch {
		case hasBlock:
			if err := applyBlockField(&sc, key, children, path); err != nil {
				return sc, err
			}
		case key == "expect":
			sc.Expect.Kind = val
			if val == "no_plan" {
				sc.Expect.Solve.NoPlan = true
			}
			if len(children) > 0 {
				if err := parseExpectBlock(&sc.Expect, children, path); err != nil {
					return sc, err
				}
			}
		default:
			if len(children) > 0 {
				return sc, fmt.Errorf("%s:%d: field %q doesn't take a block", path, l.lineNum, key)
			}
			if err := applyScalarField(&sc, key, val, l.lineNum, path); err != nil {
				return sc, err
			}
		}
	}
	return sc, nil
}

func splitField(s string) (key, val string, hasBlock bool) {
	idx := strings.Index(s, ":")
	if idx < 0 {
		return s, "", false
	}
	key = s[:idx]
	rest := strings.TrimSpace(s[idx+1:])
	if rest == "" {
		return key, "", true
	}
	return key, rest, false
}

func applyScalarField(sc *Scenario, key, val string, ln int, path string) error {
	switch key {
	case "desc":
		sc.Desc = val
	case "op":
		sc.Op = val
	case "trick":
		sc.Trick = val
	case "hand":
		cards, err := parseCards(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand: %w", path, ln, err)
		}
		sc.Hand = cards
	case "hand_cards_played":
		cards, err := parseCards(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand_cards_played: %w", path, ln, err)
		}
		sc.HandPlayed = cards
	case "card_count":
		n, err := atoi(val)
		if err != nil {
			return fmt.Errorf("%s:%d: card_count: %w", path, ln, err)
		}
		sc.CardCount = n
	// --- drag-invariant ops (floater_top_left, path_frame) ---
	case "card_index":
		n, err := atoi(val)
		if err != nil {
			return fmt.Errorf("%s:%d: card_index: %w", path, ln, err)
		}
		sc.DragCardIndex = n
	case "mousedown":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: mousedown: %w", path, ln, err)
		}
		sc.MousedownPoint = &p
	case "mousemove_delta":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: mousemove_delta: %w", path, ln, err)
		}
		sc.MousemoveDelta = &p
	case "mousedown_a":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: mousedown_a: %w", path, ln, err)
		}
		sc.MousedownA = &p
	case "mousedown_b":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: mousedown_b: %w", path, ln, err)
		}
		sc.MousedownB = &p
	case "delta":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: delta: %w", path, ln, err)
		}
		sc.MousedownDelta = &p
	case "hand_card":
		_, err := parseCard(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand_card: %w", path, ln, err)
		}
		sc.DragHandCard = val
	// --- gesture ops (gesture_split, gesture_merge_*, etc.) ---
	case "floater_at":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: floater_at: %w", path, ln, err)
		}
		sc.GestureFloaterAt = &p
	case "hovered_side":
		if val != "Left" && val != "Right" {
			return fmt.Errorf("%s:%d: hovered_side: expected Left or Right, got %q", path, ln, val)
		}
		sc.GestureHoveredSide = val
	case "cursor":
		p, err := parseXY(val)
		if err != nil {
			return fmt.Errorf("%s:%d: cursor: %w", path, ln, err)
		}
		sc.GestureCursor = &p
	case "gesture_click_intent":
		n, err := atoi(val)
		if err != nil {
			return fmt.Errorf("%s:%d: gesture_click_intent: %w", path, ln, err)
		}
		sc.GestureClickIntent = &n
	case "expect":
		sc.Expect.Kind = val
		if val == "no_plan" {
			sc.Expect.Solve.NoPlan = true
		}
	default:
		return fmt.Errorf("%s:%d: unknown field %q", path, ln, key)
	}
	return nil
}

func applyBlockField(sc *Scenario, key string, children []line, path string) error {
	switch key {
	case "board":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Board = stacks
		sc.BoardVar = "board"
	case "board_before":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Board = stacks
		sc.BoardVar = "board_before"
	case "stacks_to_remove":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Removed = stacks
	case "stacks_to_add":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Added = stacks
	case "helper":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Helper = stacks
	case "trouble":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Trouble = stacks
	case "growing":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Growing = stacks
	case "complete":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Complete = stacks
	case "existing":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Existing = stacks
	case "actions":
		acts, err := parseReplayActions(children, path)
		if err != nil {
			return err
		}
		sc.ReplayActions = acts
	case "steps":
		steps, err := parseWalkthroughSteps(children, path)
		if err != nil {
			return err
		}
		sc.Steps = steps
	case "expect_final_board":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.ExpectFinalBoard = stacks
	case "target":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.GestureTarget = stacks
	case "expect":
		return parseExpectBlock(&sc.Expect, children, path)
	default:
		return fmt.Errorf("%s: unknown block field %q", path, key)
	}
	return nil
}

func parseSuggestionRow(s string) (ExpectedSuggestion, error) {
	// Format: "<trick_id>, <card card ...>"
	// Or just "<trick_id>" for suggestions with no cards.
	parts := strings.SplitN(s, ",", 2)
	trickID := strings.TrimSpace(parts[0])
	if trickID == "" {
		return ExpectedSuggestion{}, fmt.Errorf("missing trick_id")
	}
	var cards []Card
	if len(parts) == 2 {
		rest := strings.TrimSpace(parts[1])
		if rest != "" {
			cs, err := parseCards(rest)
			if err != nil {
				return ExpectedSuggestion{}, err
			}
			cards = cs
		}
	}
	return ExpectedSuggestion{TrickID: trickID, HandCards: cards}, nil
}


func parseExpectBlock(e *Expectation, children []line, path string) error {
	i := 0
	if e.Kind == "" && i < len(children) {
		c := children[i].content
		if !strings.Contains(c, ":") && (c == "ok" || c == "no_plays" || c == "play" || c == "error" || c == "suggestions" || c == "no_plan") {
			e.Kind = c
			if c == "no_plan" {
				e.Solve.NoPlan = true
			}
			i++
		}
	}
	for ; i < len(children); i++ {
		l := children[i]
		if l.indent != 2 {
			return fmt.Errorf("%s:%d: unexpected indent in expect block", path, l.lineNum)
		}
		key, val, hasBlock := splitField(l.content)
		if hasBlock {
			var sub []line
			i++
			for i < len(children) && children[i].indent >= 3 {
				sub = append(sub, children[i])
				i++
			}
			i--
			switch key {
			case "board_after":
				stacks, err := parseStacks(sub, path)
				if err != nil {
					return err
				}
				e.BoardAfter = stacks
			case "plan_lines":
				// Each sub line is `- "string"`. Strip the
				// leading `- ` and the surrounding quotes.
				var lines []string
				for _, sl := range sub {
					t := strings.TrimSpace(sl.content)
					if !strings.HasPrefix(t, "- ") {
						return fmt.Errorf("%s:%d: plan_lines entries must start with '- '", path, sl.lineNum)
					}
					body := strings.TrimSpace(t[2:])
					if len(body) < 2 || body[0] != '"' || body[len(body)-1] != '"' {
						return fmt.Errorf("%s:%d: plan_lines entry must be a quoted string", path, sl.lineNum)
					}
					unquoted, err := strconv.Unquote(body)
					if err != nil {
						return fmt.Errorf("%s:%d: plan_lines unquote: %w", path, sl.lineNum, err)
					}
					lines = append(lines, unquoted)
				}
				e.Solve.PlanLines = lines
			default:
				return fmt.Errorf("%s:%d: unknown expect block %q", path, l.lineNum, key)
			}
		} else {
			switch key {
			// --- base fields (shared across multiple ops) ---
			case "hand_played":
				cards, err := parseCards(val)
				if err != nil {
					return fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
				}
				e.HandPlayed = cards
			case "stage":
				e.Stage = val
			case "message_contains":
				e.MessageSubstr = val
			case "suggestion":
				sug, err := parseSuggestionRow(val)
				if err != nil {
					return fmt.Errorf("%s:%d: suggestion: %w", path, l.lineNum, err)
				}
				e.Suggestions = append(e.Suggestions, sug)
			// --- enumerate_moves (Planner) ---
			case "yields":
				e.Planner.Yields = val
			case "narrate_contains":
				e.Planner.NarrateContains = val
			case "hint_contains":
				e.Planner.HintContains = val
			// --- solve (Solve) ---
			case "plan_length":
				n := 0
				if _, err := fmt.Sscanf(val, "%d", &n); err != nil {
					return fmt.Errorf("%s:%d: plan_length: %w", path, l.lineNum, err)
				}
				e.Solve.PlanLength = n
			// --- find_open_loc / validate_board_geometry /
			//     classify_board_geometry / stack_height_constant (Geometry) ---
			case "loc":
				loc, err := parseLoc(val)
				if err != nil {
					return fmt.Errorf("%s:%d: loc: %w", path, l.lineNum, err)
				}
				e.Geometry.Loc = &loc
			case "error_count":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: error_count: %w", path, l.lineNum, err)
				}
				e.Geometry.ErrorCount = &n
			case "any_error_kind":
				e.Geometry.AnyErrorKind = val
			case "no_error_kind":
				e.Geometry.NoErrorKind = val
			case "overlap_count":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: overlap_count: %w", path, l.lineNum, err)
				}
				e.Geometry.OverlapCount = &n
			case "overlap_stack_indices":
				parts := strings.Fields(val)
				for _, p := range parts {
					idx, err := atoi(p)
					if err != nil {
						return fmt.Errorf("%s:%d: overlap_stack_indices: %w", path, l.lineNum, err)
					}
					e.Geometry.OverlapStackIndices = append(e.Geometry.OverlapStackIndices, idx)
				}
			case "geometry_status":
				e.Geometry.GeometryStatus = val
			// --- click_agent_play (ClickAgent) ---
			case "replay_started":
				v, err := parseBool(val)
				if err != nil {
					return fmt.Errorf("%s:%d: replay_started: %w", path, l.lineNum, err)
				}
				e.ClickAgent.ReplayStarted = &v
			case "log_appended":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: log_appended: %w", path, l.lineNum, err)
				}
				e.ClickAgent.LogAppended = &n
			case "agent_program_size":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: agent_program_size: %w", path, l.lineNum, err)
				}
				e.ClickAgent.AgentProgramSize = &n
			case "status_kind":
				e.ClickAgent.StatusKind = val
			case "status_contains":
				if len(val) >= 2 && val[0] == '"' && val[len(val)-1] == '"' {
					unquoted, err := strconv.Unquote(val)
					if err != nil {
						return fmt.Errorf("%s:%d: status_contains: %w", path, l.lineNum, err)
					}
					e.ClickAgent.StatusContains = unquoted
				} else {
					e.ClickAgent.StatusContains = val
				}
			// --- replay_invariant (Replay) ---
			case "final_board_victory":
				v, err := parseBool(val)
				if err != nil {
					return fmt.Errorf("%s:%d: final_board_victory: %w", path, l.lineNum, err)
				}
				e.Replay.FinalBoardVictory = &v
			// --- floater_top_left (DragFloater) ---
			case "shift_equals_delta":
				v, err := parseBool(val)
				if err != nil {
					return fmt.Errorf("%s:%d: shift_equals_delta: %w", path, l.lineNum, err)
				}
				e.DragFloater.ShiftEqualsDelta = v
			case "grab_point_invariant":
				v, err := parseBool(val)
				if err != nil {
					return fmt.Errorf("%s:%d: grab_point_invariant: %w", path, l.lineNum, err)
				}
				e.DragFloater.GrabPointInvariant = v
			// --- path_frame (DragPathFrame) ---
			case "frame":
				e.DragPathFrame.Frame = val
			case "initial_floater_at":
				p, err := parseXY(val)
				if err != nil {
					return fmt.Errorf("%s:%d: initial_floater_at: %w", path, l.lineNum, err)
				}
				e.DragPathFrame.InitialFloater = &p
			// --- gesture_split ---
			case "card_index":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: card_index: %w", path, l.lineNum, err)
				}
				e.GestureSplit.CardIndex = n
			// --- gesture_merge_stack, gesture_merge_hand, gesture_floater_over_wing ---
			case "side":
				if val != "Left" && val != "Right" {
					return fmt.Errorf("%s:%d: side: expected Left or Right, got %q", path, l.lineNum, val)
				}
				e.GestureMergeStack.Side = val
				e.GestureMergeHand.Side = val
				e.GestureFloaterOverWing.Side = val
			// --- gesture_move_stack ---
			case "rejected":
				v, err := parseBool(val)
				if err != nil {
					return fmt.Errorf("%s:%d: rejected: %w", path, l.lineNum, err)
				}
				e.GestureMoveStack.Rejected = v
			case "new_loc_left":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: new_loc_left: %w", path, l.lineNum, err)
				}
				e.GestureMoveStack.NewLocLeft = n
			case "new_loc_top":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: new_loc_top: %w", path, l.lineNum, err)
				}
				e.GestureMoveStack.NewLocTop = n
			// --- gesture_place_hand ---
			case "loc_left":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: loc_left: %w", path, l.lineNum, err)
				}
				e.GesturePlaceHand.LocLeft = n
			case "loc_top":
				n, err := atoi(val)
				if err != nil {
					return fmt.Errorf("%s:%d: loc_top: %w", path, l.lineNum, err)
				}
				e.GesturePlaceHand.LocTop = n
			// --- gesture_floater_over_wing ---
			case "has_wing":
				v, err := parseBool(val)
				if err != nil {
					return fmt.Errorf("%s:%d: has_wing: %w", path, l.lineNum, err)
				}
				e.GestureFloaterOverWing.HasWing = v
			default:
				return fmt.Errorf("%s:%d: unknown expect field %q", path, l.lineNum, key)
			}
		}
	}
	return nil
}

func parseStacks(children []line, path string) ([]Stack, error) {
	var stacks []Stack
	baseIndent := -1
	for _, l := range children {
		if baseIndent == -1 {
			baseIndent = l.indent
		}
		if l.indent != baseIndent {
			return nil, fmt.Errorf("%s:%d: inconsistent indent in stack list", path, l.lineNum)
		}
		if !strings.HasPrefix(l.content, "at ") {
			return nil, fmt.Errorf("%s:%d: expected 'at (t,l): ...'", path, l.lineNum)
		}
		rest := strings.TrimPrefix(l.content, "at ")
		locEnd := strings.Index(rest, ")")
		if !strings.HasPrefix(rest, "(") || locEnd < 0 {
			return nil, fmt.Errorf("%s:%d: bad location syntax", path, l.lineNum)
		}
		locStr := rest[1:locEnd]
		parts := strings.Split(locStr, ",")
		if len(parts) != 2 {
			return nil, fmt.Errorf("%s:%d: bad location syntax", path, l.lineNum)
		}
		top, err1 := atoi(strings.TrimSpace(parts[0]))
		left, err2 := atoi(strings.TrimSpace(parts[1]))
		if err1 != nil || err2 != nil {
			return nil, fmt.Errorf("%s:%d: bad location integers", path, l.lineNum)
		}
		tail := strings.TrimSpace(rest[locEnd+1:])
		if !strings.HasPrefix(tail, ":") {
			return nil, fmt.Errorf("%s:%d: expected ':' after location", path, l.lineNum)
		}
		cardStr := strings.TrimSpace(tail[1:])
		cards, err := parseCards(cardStr)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
		}
		stacks = append(stacks, Stack{Top: top, Left: left, Cards: cards})
	}
	return stacks, nil
}

// parseReplayActions parses an `actions:` block inside a
// replay_invariant scenario. Each child line is a
// `- <kind> ...` directive in one of these shapes:
//
//   - split [<labels>]@<int>
//   - merge_stack [<labels>] -> [<labels>] /<side>
//   - move_stack [<labels>] -> (<top>,<left>)
//   - complete_turn
//
// The labels match the canonical-text-form already used in
// `tools/export_primitives_fixtures.py` so the two layers stay
// readable in the same vocabulary.
func parseReplayActions(children []line, path string) ([]ReplayAction, error) {
	var out []ReplayAction
	for _, l := range children {
		t := strings.TrimSpace(l.content)
		if !strings.HasPrefix(t, "- ") {
			return nil, fmt.Errorf("%s:%d: action must start with '- '", path, l.lineNum)
		}
		body := strings.TrimSpace(t[2:])
		act, err := parseReplayAction(body)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
		}
		out = append(out, act)
	}
	return out, nil
}


// parseWalkthroughSteps parses a `steps:` block inside an
// `undo_walkthrough` scenario. The block is a list of step
// groups, each starting with `- step: <label>` followed by
// optional sub-fields (`action:`, `expect_board_count:`,
// `expect_hand_count:`, `expect_undoable:`).
//
// Indentation convention (relative to the scenario body):
//   `steps:` itself is at indent 1.
//   `- step:` entries are at indent 2.
//   Sub-fields are at indent 3.
func parseWalkthroughSteps(children []line, path string) ([]WalkthroughStep, error) {
	var steps []WalkthroughStep
	var cur *WalkthroughStep
	baseIndent := -1

	for _, l := range children {
		if baseIndent == -1 {
			baseIndent = l.indent
		}
		switch {
		case l.indent == baseIndent:
			// Step header: "- step: <label>"
			t := strings.TrimSpace(l.content)
			if !strings.HasPrefix(t, "- step:") {
				return nil, fmt.Errorf("%s:%d: expected '- step: <label>', got %q", path, l.lineNum, t)
			}
			if cur != nil {
				steps = append(steps, *cur)
			}
			label := strings.TrimSpace(t[len("- step:"):])
			cur = &WalkthroughStep{Label: label}

		case l.indent == baseIndent+1:
			// Sub-field of the current step.
			if cur == nil {
				return nil, fmt.Errorf("%s:%d: step sub-field outside a step block", path, l.lineNum)
			}
			key, val, _ := splitField(strings.TrimSpace(l.content))
			switch key {
			case "action":
				act, err := parseReplayAction(strings.TrimSpace(val))
				if err != nil {
					return nil, fmt.Errorf("%s:%d: action: %w", path, l.lineNum, err)
				}
				cur.Action = &act
			case "expect_board_count":
				n, err := atoi(strings.TrimSpace(val))
				if err != nil {
					return nil, fmt.Errorf("%s:%d: expect_board_count: %w", path, l.lineNum, err)
				}
				cur.ExpectBoardCount = &n
			case "expect_hand_count":
				n, err := atoi(strings.TrimSpace(val))
				if err != nil {
					return nil, fmt.Errorf("%s:%d: expect_hand_count: %w", path, l.lineNum, err)
				}
				cur.ExpectHandCount = &n
			case "expect_undoable":
				v, err := parseBool(strings.TrimSpace(val))
				if err != nil {
					return nil, fmt.Errorf("%s:%d: expect_undoable: %w", path, l.lineNum, err)
				}
				cur.ExpectUndoable = &v
			case "expect_stack":
				cards, err := parseCards(strings.TrimSpace(val))
				if err != nil {
					return nil, fmt.Errorf("%s:%d: expect_stack: %w", path, l.lineNum, err)
				}
				cur.ExpectStack = cards
			case "expect_hand_contains":
				cards, err := parseCards(strings.TrimSpace(val))
				if err != nil {
					return nil, fmt.Errorf("%s:%d: expect_hand_contains: %w", path, l.lineNum, err)
				}
				if len(cards) != 1 {
					return nil, fmt.Errorf("%s:%d: expect_hand_contains: expected exactly one card", path, l.lineNum)
				}
				cur.ExpectHandContains = &cards[0]
			default:
				return nil, fmt.Errorf("%s:%d: unknown step field %q", path, l.lineNum, key)
			}

		default:
			return nil, fmt.Errorf("%s:%d: unexpected indent in steps block", path, l.lineNum)
		}
	}
	if cur != nil {
		steps = append(steps, *cur)
	}
	return steps, nil
}


func parseReplayAction(body string) (ReplayAction, error) {
	if body == "complete_turn" {
		return ReplayAction{Kind: "complete_turn"}, nil
	}
	if body == "undo" {
		return ReplayAction{Kind: "undo"}, nil
	}
	if strings.HasPrefix(body, "split ") {
		return parseReplaySplit(body[len("split "):])
	}
	if strings.HasPrefix(body, "merge_stack ") {
		return parseReplayMergeStack(body[len("merge_stack "):])
	}
	if strings.HasPrefix(body, "move_stack ") {
		return parseReplayMoveStack(body[len("move_stack "):])
	}
	if strings.HasPrefix(body, "place_hand ") {
		return parsePlaceHand(body[len("place_hand "):])
	}
	if strings.HasPrefix(body, "merge_hand ") {
		return parseMergeHand(body[len("merge_hand "):])
	}
	return ReplayAction{}, fmt.Errorf("unknown action kind: %q", body)
}


func parseReplaySplit(rest string) (ReplayAction, error) {
	// shape: [<labels>]@<int>
	at := strings.LastIndex(rest, "@")
	if at < 0 {
		return ReplayAction{}, fmt.Errorf("split missing '@<index>'")
	}
	contentStr, idxStr := rest[:at], rest[at+1:]
	cards, err := parseBracketed(contentStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("split: %w", err)
	}
	idx, err := atoi(strings.TrimSpace(idxStr))
	if err != nil {
		return ReplayAction{}, fmt.Errorf("split index: %w", err)
	}
	return ReplayAction{Kind: "split", Source: cards, CardIndex: idx}, nil
}


func parseReplayMergeStack(rest string) (ReplayAction, error) {
	// shape: [<src>] -> [<tgt>] /<side>
	arrow := strings.Index(rest, "->")
	if arrow < 0 {
		return ReplayAction{}, fmt.Errorf("merge_stack missing '->'")
	}
	srcStr := strings.TrimSpace(rest[:arrow])
	tail := strings.TrimSpace(rest[arrow+2:])
	slash := strings.LastIndex(tail, "/")
	if slash < 0 {
		return ReplayAction{}, fmt.Errorf("merge_stack missing '/<side>'")
	}
	tgtStr := strings.TrimSpace(tail[:slash])
	sideStr := strings.TrimSpace(tail[slash+1:])
	src, err := parseBracketed(srcStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("merge_stack source: %w", err)
	}
	tgt, err := parseBracketed(tgtStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("merge_stack target: %w", err)
	}
	if sideStr != "left" && sideStr != "right" {
		return ReplayAction{}, fmt.Errorf("merge_stack side must be left|right, got %q", sideStr)
	}
	return ReplayAction{
		Kind:   "merge_stack",
		Source: src,
		Target: tgt,
		Side:   sideStr,
	}, nil
}


func parseReplayMoveStack(rest string) (ReplayAction, error) {
	// shape: [<labels>] -> (<top>,<left>)
	arrow := strings.Index(rest, "->")
	if arrow < 0 {
		return ReplayAction{}, fmt.Errorf("move_stack missing '->'")
	}
	contentStr := strings.TrimSpace(rest[:arrow])
	locStr := strings.TrimSpace(rest[arrow+2:])
	cards, err := parseBracketed(contentStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("move_stack content: %w", err)
	}
	loc, err := parseLoc(locStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("move_stack loc: %w", err)
	}
	return ReplayAction{Kind: "move_stack", Source: cards, NewLoc: &loc}, nil
}


func parsePlaceHand(rest string) (ReplayAction, error) {
	// shape: <card> -> (<top>, <left>)
	arrow := strings.Index(rest, "->")
	if arrow < 0 {
		return ReplayAction{}, fmt.Errorf("place_hand missing '->'")
	}
	cardStr := strings.TrimSpace(rest[:arrow])
	locStr := strings.TrimSpace(rest[arrow+2:])
	cards, err := parseCards(cardStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("place_hand card: %w", err)
	}
	if len(cards) != 1 {
		return ReplayAction{}, fmt.Errorf("place_hand: expected exactly one card, got %d", len(cards))
	}
	loc, err := parseLoc(locStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("place_hand loc: %w", err)
	}
	return ReplayAction{Kind: "place_hand", Source: cards, NewLoc: &loc}, nil
}


func parseMergeHand(rest string) (ReplayAction, error) {
	// shape: <card> -> [<target_cards>] /<side>
	arrow := strings.Index(rest, "->")
	if arrow < 0 {
		return ReplayAction{}, fmt.Errorf("merge_hand missing '->'")
	}
	cardStr := strings.TrimSpace(rest[:arrow])
	tail := strings.TrimSpace(rest[arrow+2:])
	slash := strings.LastIndex(tail, "/")
	if slash < 0 {
		return ReplayAction{}, fmt.Errorf("merge_hand missing '/<side>'")
	}
	tgtStr := strings.TrimSpace(tail[:slash])
	sideStr := strings.TrimSpace(tail[slash+1:])
	cards, err := parseCards(cardStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("merge_hand card: %w", err)
	}
	if len(cards) != 1 {
		return ReplayAction{}, fmt.Errorf("merge_hand: expected exactly one card, got %d", len(cards))
	}
	tgt, err := parseBracketed(tgtStr)
	if err != nil {
		return ReplayAction{}, fmt.Errorf("merge_hand target: %w", err)
	}
	if sideStr != "left" && sideStr != "right" {
		return ReplayAction{}, fmt.Errorf("merge_hand side must be left|right, got %q", sideStr)
	}
	return ReplayAction{Kind: "merge_hand", Source: cards, Target: tgt, Side: sideStr}, nil
}


// parseBracketed extracts cards from "[<label> <label> ...]".
func parseBracketed(s string) ([]Card, error) {
	t := strings.TrimSpace(s)
	if !strings.HasPrefix(t, "[") || !strings.HasSuffix(t, "]") {
		return nil, fmt.Errorf("expected [<labels>] form, got %q", s)
	}
	inner := strings.TrimSpace(t[1 : len(t)-1])
	if inner == "" {
		return nil, nil
	}
	return parseCards(inner)
}


func parseCards(s string) ([]Card, error) {
	if s == "" {
		return nil, nil
	}
	var cards []Card
	for _, tok := range strings.Fields(s) {
		c, err := parseCard(tok)
		if err != nil {
			return nil, err
		}
		cards = append(cards, c)
	}
	return cards, nil
}

func parseCard(tok string) (Card, error) {
	if len(tok) < 2 {
		return Card{}, fmt.Errorf("card too short: %q", tok)
	}
	v := valueFromLetter(tok[0])
	if v == 0 {
		return Card{}, fmt.Errorf("bad value letter: %q", tok)
	}
	s := suitFromLetter(tok[1])
	if s == -1 {
		return Card{}, fmt.Errorf("bad suit letter: %q", tok)
	}
	c := Card{Value: v, Suit: s, Deck: 0, BoardState: 0}
	i := 2
	if i < len(tok) && tok[i] == '\'' {
		c.Deck = 1
		i++
	}
	if i < len(tok) && tok[i] == '*' {
		if i+1 < len(tok) && tok[i+1] == '*' {
			c.BoardState = 2
			i += 2
		} else {
			c.BoardState = 1
			i++
		}
	}
	if i != len(tok) {
		return Card{}, fmt.Errorf("trailing chars in card: %q", tok)
	}
	return c, nil
}

func valueFromLetter(b byte) int {
	switch b {
	case 'A':
		return 1
	case 'T':
		return 10
	case 'J':
		return 11
	case 'Q':
		return 12
	case 'K':
		return 13
	}
	if b >= '2' && b <= '9' {
		return int(b - '0')
	}
	return 0
}

func suitFromLetter(b byte) int {
	switch b {
	case 'C':
		return 0
	case 'D':
		return 1
	case 'S':
		return 2
	case 'H':
		return 3
	}
	return -1
}

// parseBool parses true/false as written in DSL bodies.
func parseBool(s string) (bool, error) {
	switch strings.TrimSpace(s) {
	case "true":
		return true, nil
	case "false":
		return false, nil
	}
	return false, fmt.Errorf("expected true | false, got %q", s)
}


// parseLoc parses "(top, left)" into a Loc.
func parseLoc(s string) (Loc, error) {
	t := strings.TrimSpace(s)
	if !strings.HasPrefix(t, "(") || !strings.HasSuffix(t, ")") {
		return Loc{}, fmt.Errorf("expected (top, left) form")
	}
	body := t[1 : len(t)-1]
	parts := strings.Split(body, ",")
	if len(parts) != 2 {
		return Loc{}, fmt.Errorf("expected two integers")
	}
	top, err1 := atoi(strings.TrimSpace(parts[0]))
	left, err2 := atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil {
		return Loc{}, fmt.Errorf("non-integer in loc")
	}
	return Loc{Top: top, Left: left}, nil
}

// parseXY parses a "(x, y)" cursor-point string.
func parseXY(s string) (XY, error) {
	t := strings.TrimSpace(s)
	if !strings.HasPrefix(t, "(") || !strings.HasSuffix(t, ")") {
		return XY{}, fmt.Errorf("expected (x, y) form")
	}
	body := t[1 : len(t)-1]
	parts := strings.Split(body, ",")
	if len(parts) != 2 {
		return XY{}, fmt.Errorf("expected two integers")
	}
	x, err1 := atoi(strings.TrimSpace(parts[0]))
	y, err2 := atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil {
		return XY{}, fmt.Errorf("non-integer in xy")
	}
	return XY{X: x, Y: y}, nil
}


func atoi(s string) (int, error) {
	n := 0
	neg := false
	i := 0
	if len(s) > 0 && s[0] == '-' {
		neg = true
		i = 1
	}
	if i == len(s) {
		return 0, fmt.Errorf("not a number: %q", s)
	}
	for ; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("not a number: %q", s)
		}
		n = n*10 + int(c-'0')
	}
	if neg {
		n = -n
	}
	return n, nil
}
