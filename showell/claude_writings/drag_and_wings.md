# Drag and Wings

*Written 2026-04-17 (evening). Forward plan, not retrospective.
Pivot essay: drag-drop + wings on the opening board is the next
deliverable, ahead of the game.ts decomposition.*

**← Prev:** [State-Flow Audit of game.ts](state_flow_audit_of_game_ts.md)

---

Status: pivot confirmed. The state-flow audit stays shelved —
we'll return to it when players and turns come into scope.
Right now the biggest risk factor is whether drag-drop feels
like LynRummy at all, so we go straight at that.

## What ships this checkpoint

- A single-card stack on the board can be picked up with a
  mouse press, dragged, and dropped onto any other stack.
- During the drag, every stack on the board that the dragged
  stack could *legally* merge into shows wings.
- A drop landing over a winged stack commits the merge and the
  board re-renders with one fewer stack.
- A drop landing anywhere else snaps the dragged stack back to
  its original position.

That's it. Three singletons (7H, 8C, 4S) are already parked on
the opening board for this test. No hand, no turn chrome, no
tricks, no scoring. The three rulings from the state-flow
audit essay are deferred — nothing here touches Player,
PlayerGroup, EventTracker, or WebXDC.

## The shape

Three parts, each one easy to reason about in isolation:

1.  **Base drag physics** — universal, LynRummy-agnostic. Any
    stack is always draggable. While dragging, we render the
    stack at `cursor - grabOffset` without mutating its stored
    `loc`. Snap-back on an invalid drop is then free: we just
    clear the drag state.
2.  **Merge oracle** — the LynRummy-specific rule engine,
    called at two moments: (a) once per `MouseDown`, to decide
    which targets get wings for the duration of the drag;
    (b) once per `MouseUp`, to decide whether the drop
    commits. The oracle is already built — `BoardActions.findAllStackMerges`
    enumerates exactly this.
3.  **Wings decoration** — a view-layer concern. Given the
    oracle's set of legal target indices, the view renders
    each of those stacks with wing glyphs flanking the head
    card. Non-targets render unchanged.

The split is deliberate: base physics doesn't know about
LynRummy rules, and the oracle doesn't know about pixels.
That seam is where the long-press extraction, tidy-as-no-op,
and per-trick-snaps will eventually live, but today we only
need the one rule "can this stack merge into that stack" which
the ported code already answers.

## Model + Msg

The drag state rides on Model alongside the board. Nothing
about the board's own structure changes.

```elm
type alias Model =
    { board : List CardStack
    , drag : DragState
    }


type DragState
    = NotDragging
    | Dragging
        { sourceIndex : Int
        , grabOffset : { dx : Float, dy : Float }
        , cursor : { x : Float, y : Float }
        , targets : Set Int     -- winged stack indices
        }


type Msg
    = MouseDownOnStack Int { offsetX : Float, offsetY : Float }
    | MouseMove { x : Float, y : Float }
    | MouseUp
```

The `targets` set is computed once at `MouseDown` and frozen
for the life of the drag. That's correct by construction
because no other stack changes during a drag — the source is
lifted, everyone else is stationary. (When hand cards arrive
later, targets will still be drag-time-frozen; adding wings
for extraction tricks will recompute on hover, but that's a
future essay's concern.)

`Browser.Events.onMouseMove` and `onMouseUp` subscribe during
`Dragging`, unsubscribe during `NotDragging`. Mousedown is a
per-stack event handler in `View`.

## Wings oracle

`findAllStackMerges source board` already returns every legal
merge. Each `StackMergeResult` carries a `change` whose
`stacksToRemove` contains the target that would be consumed.
Translate that into indices and we're done:

```elm
wingedTargets : Int -> List CardStack -> Set Int
wingedTargets sourceIndex board =
    case listGet sourceIndex board of
        Nothing ->
            Set.empty

        Just source ->
            BoardActions.findAllStackMerges source board
                |> List.concatMap (\r -> r.change.stacksToRemove)
                |> List.filterMap (targetIndex board sourceIndex)
                |> Set.fromList


targetIndex : List CardStack -> Int -> CardStack -> Maybe Int
targetIndex board sourceIndex stack =
    board
        |> List.indexedMap Tuple.pair
        |> List.filter (\( i, s ) -> i /= sourceIndex && stacksEqual s stack)
        |> List.head
        |> Maybe.map Tuple.first
```

A stack shows wings iff its index is in that set. On `MouseUp`,
we re-run the oracle against the current cursor position — if
the cursor-centered AABB overlaps exactly one winged target,
we commit that merge by applying its `BoardChange`. Zero
overlaps or multiple overlaps → snap back, because ambiguity
here should be a no-op, not a guess.

## What I'm not doing

- **Touch events** — mousedown/move/up only for now. Tablet
  support is a memoried priority but adds a second event
  family; we'll layer it once the mouse version feels right.
- **Animation on commit** — the merged stack will pop into
  existence. No slide, no fade. Pure state transition.
- **Wings styling polish** — the wings themselves are a
  faithful port of `render_wing()` (`game.ts` line 984): a div
  with transparent background, two transparent `+` card-char
  nodes for height, `width: 0`, and `set_common_card_styles`
  for the card-edge silhouette. No iteration from ugly — the
  existing code is straightforward and the look is already
  right.
- **Multi-card stack dragging** — the test singletons are
  single cards, and single-card merges are the first risk to
  reduce. Rigid-multi-card drag lands the same day but isn't
  the gate.
- **Hysteresis on the drop zone** — a stack either overlaps a
  target or it doesn't. We can add hysteresis later if the
  drop boundary feels jumpy.

## Risk flags

- **Cursor-offset math across nested positioned elements.**
  The board is `position: relative`, stacks are `position: absolute`,
  cards are `display: inline-block`. Getting `event.offsetX/Y`
  to resolve into the right coordinate frame is the first
  thing likely to misbehave. I'll sanity-check by logging
  cursor coordinates during an early drag and making sure a
  mouse-parked-still drag doesn't cause drift.
- **Stack identity across board changes.** `stacksEqual` is
  structural; after a commit, the merged stack is a new
  object. If a stale drag state somehow survives a commit, it
  could point at an index that no longer exists. Mitigation:
  always clear drag on commit, never during, and audit the
  transitions.
- **AABB overlap as drop test.** If the dragged stack's box
  overlaps two targets, we bail. I think that's correct, but
  it's a judgment call worth surfacing — we may find in
  practice that "nearest center" is a better heuristic.

## How you help

Same lab-rat posture as the opening board. I'll flag when
drag-drop is wired up. You pick up 7H, drag it over the
six-run, watch for wings. Drop it. Does the merge feel right?
Does snap-back feel right? Does the rigid-drag feel like
picking up a real stack?

Gut reaction, not measurement. This is the first time an
interaction lands in this codebase; we're establishing the
kinesthetic floor for everything that follows.

— C.
