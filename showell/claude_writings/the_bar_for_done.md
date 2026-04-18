# The Bar for Done

*Forward plan, 2026-04-18. Defines the success criteria for
the LynRummy TS→Elm porting effort. Durable-ish — the bar
itself shouldn't move much.*

**← Prev:** [Splitting a Stack](splitting_a_stack.md)

---

Steve expects a faithful port of the current behavior as
perceived by the active human players today — Steve and his
mother Susan. The current behavior is not the optimal UI; he
concedes that openly. But it is close enough to port directly,
and the work of *improving* the UI happens AFTER the port
lands, not woven into it. The goal of this essay is to make
"done" concrete enough that we recognize it when we get there
— and that we don't keep moving the line.

## "As perceived" — what counts and what doesn't

The frame restricts what counts as a port-defect to things
Steve or Susan would notice while playing. The internal shape
of the code can change however it needs to. Their experience
should not.

**Doesn't count as a defect:**

- Internal data structures (TS class vs Elm record).
- Where event handlers live (parent vs child element).
- Whether a state update happens in a closure or in
  `update`.
- The exact value of the click-vs-drag threshold, as long
  as it feels right.
- Refactors that change code shape but not visible
  behavior.

**Counts as a defect:**

- The opening board's stacks rendering at different
  locations, in different colors, with different sizes.
- A drag-from-hand-to-wing failing where TS succeeds (or
  vice versa).
- A click-on-card-in-multi-card-stack failing to split.
- Wings appearing on the wrong side, in the wrong color,
  or at wrong moments.
- Status-bar messages or scolds that don't fire when TS's
  do, or that fire with different wording.
- Card colors or backgrounds drifting from the TS
  conventions (red/black by suit; cyan freshly-drawn;
  yellow back-from-board; lightgreen hint).
- Trick recognition producing different outcomes.
- Turn flow advancing differently, scoring computing
  differently, or end-of-game triggering differently.

## The concrete test scenarios

These are the things that have to work — and match TS
exactly — before "done":

1. **Opening a game.** Initial board renders the same six
   stacks at the same positions; hand renders suit-sorted
   rows, value-ascending within each row.
2. **Hand-to-board merge.** Drag any hand card onto a wing
   → merge commits → hand card removed → merged stack
   anchored at target.
3. **Hand-to-board place.** Drop a hand card on empty
   board → new singleton stack at the cursor.
4. **Stack-to-stack merge.** Drag a board stack onto a wing
   → combine → result at the target.
5. **Stack split via click.** Click a card in a multi-card
   stack → split at that card.
6. **Stack ordinary move.** Drag a board stack to an empty
   spot → it lands there.
7. **Snap-back.** Drop in invalid locations (off-board,
   overlapping) → return to origin with the appropriate
   scold.
8. **Trick recognition.** Every trick the TS game
   recognizes — DirectPlay, HandStacks, SplitForSet,
   PeelForRun, RbSwap, PairPeel, LooseCardPlay —
   producing the same outcome.
9. **Turn flow.** Draw, play, discard, complete-turn,
   advance-to-next-player, end-of-game scoring.
10. **Two-player play.** Steve and Susan can play a
    complete game from deal through victory in the Elm
    client, with both players' moves traveling through
    Gopher.

Items 1–8 are mostly client-side and approachable from the
current standalone build. Item 9 needs hand state changes
beyond what's there (the draw/discard model, a turn
machine). Item 10 needs the Gopher Part 2 work — flags,
round-trip, SSE, multi-player auth.

## What's NOT in scope for done

The defining principle of the after-port phase: anything
that *changes the perceived behavior* relative to TS is
out of scope for reaching done, even if it's an obvious
improvement.

- **Touch/tablet support beyond what TS does.** Susan
  plays on a tablet; if her TS experience is "drag works,
  long-press doesn't," the Elm port doesn't need to add
  long-press to be done. Tablet-first redesigns belong
  to after-port. (Caveat: if Susan's tablet experience
  on TS is currently *broken*, the Elm port needs to be
  at least as broken-or-better, not less functional.)
- **UI redesigns.** No layout changes, no new color
  schemes, no new visual affordances — even if obviously
  better.
- **New gestures.** Long-press extract, shelf paradigms,
  swipe-to-do-X. Stay frozen.
- **Better hint display.** Port the existing hint
  highlighting; improvements wait.
- **Improved error messages.** "DON'T TOUCH THE CARDS
  UNLESS YOU ARE GONNA PUT THEM ON THE BOARD" stays as
  written, all caps, playful tone preserved.
- **Performance tuning.** As long as the game doesn't
  visibly stutter, no optimization passes.
- **Refactors that change felt behavior.** Internal
  cleanups are fine. Anything that rounds differently,
  sorts differently, or changes which card pops where is
  a defect, not a refactor.

## How we know we're done

The concrete check: Steve and Susan play a game in the
Elm client; Steve plays a game in the TS client; side-by-
side comparison. If their perceived experience is the same
— same gestures producing same outcomes, same status
messages, same visual feedback at the same moments — port
done. Anything that diverges goes on the port-defect list,
gets fixed, and we re-test.

After done is declared, after-port iteration starts. At
that point we lose the side-by-side TS reference (we'll be
diffing against the prior Elm build), and improvement work
becomes its own thing with its own milestones — touch
support, layout polish, new gestures, all the things that
have been deferred get queued.

## Why this strictness matters

The reason for being so strict about the not-in-scope list
isn't preciousness. It's that mixing port work with
improvement work makes "is this a port defect or a
deliberate change?" unanswerable. Keeping them separate
keeps a stable reference — the TS client — to diff against.
The moment we start changing perceived behavior during the
port, the diff stops being meaningful, and "done" becomes
unfalsifiable.

The two phases aren't symmetric. Port-to-done is finite
work, bounded by the size of `game.ts` and the existing
trick library. After-port iteration has no upper bound; it
continues for as long as LynRummy exists.

## Durability forecast

This essay's content should be durable for the entire
port. The bar shouldn't move; it's the reference point
the rest of the work is measured against. If the bar does
move (e.g., Steve decides some "improvement" really is in
scope after all), update this essay deliberately rather
than letting it drift.

— C.
