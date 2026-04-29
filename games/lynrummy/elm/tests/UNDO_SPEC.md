# Undo — Product Spec

## What it does

The Undo button reverses the last primitive board action taken in the current turn. Each click undoes exactly one primitive. The player can keep clicking to walk back multiple primitives one at a time.

## Scope

- **Within-turn only.** Undo cannot cross a turn boundary — actions from completed turns are permanent.
- **No redo.** Once undone, the action is gone.
- **Primitive granularity.** The five undoable primitives are: `Split`, `MergeStack`, `MergeHand`, `PlaceHand`, `MoveStack`.

## Button state

The Undo button is **disabled** when there is nothing to undo in the current turn — either no actions taken yet, or all have been undone. It is **active** whenever at least one undoable primitive exists.

## Effect per action type

| Action | Board effect | Hand effect |
|---|---|---|
| `MoveStack` | Stack returns to original location | — |
| `Split` | Two pieces re-merge into original stack | — |
| `MergeStack` | Merged stack splits back into original two stacks | — |
| `MergeHand` | Merged stack loses the hand card | Card returns to hand |
| `PlaceHand` | Singleton removed from board | Card returns to hand |

## What does NOT change on undo

- Turn index, player scores, deck
- `CompleteTurn` is not undoable
