# Click and Drag

*Status report, 2026-04-18 afternoon. Covers the click-vs-drag
arbitration port: setup, the architectural pivot, the test-first
discipline, the two regressions, the smell catch, and what's
still open. Written in my normal voice — costumes off — to
Steve. Verbose because you said you'd enjoy reading it.*

**← Prev:** [The Customer Is Always Writing](the_customer_is_always_writing.md)

---

This was the episode we both knew was going to be the hardest
piece of the port, and going in I had the wrong model of why.

## What we were actually facing

The TS click-vs-drag arbitration in `DragDropHelper.enable_drag`
is a single ~200-line function with seven closure-captured
local variables, three pointer-event listeners, two
helper-function locals, and a side-effect on every pointerup
that nukes-and-rebuilds the entire DOM. It uses
`document.elementsFromPoint` to discover which inner element
the user touched while the listener lived on the outer
element. It uses `setPointerCapture` to keep mousemove events
flowing after the cursor wandered off the dragged div. The
state machine looks like a mass of conditionals; the
arbitration rule (1-pixel threshold, click takes precedence
at release) is buried in two lines spread across two handlers.

You had a hypothesis going in: the state tracking was the hard
part; the callback hooks were easy. I came back with a
refinement: the state tracking was indeed the central work,
but there was *also* a capability gap — `elementsFromPoint`
has no Elm equivalent without a port. Two problems, partially
entangled, and I wasn't sure which one to attack first.

What you asked next is the move I want to call out, because
it's been the most useful methodological thing in this whole
session: "ask yourself if either problem can be attacked in
isolation first."

## The pivot to inversion

Sitting with the question for a few minutes produced the right
answer. The capability gap was a TS-architecture artifact, not
an Elm requirement. TS used `elementsFromPoint` because the
listener lived on the parent stack and needed to discover
which child card the user touched. Elm doesn't need to make
that discovery at runtime — it can put the listener directly
on the child card, and the event tells us which one fired.

The inversion is the move. Once you make it, the second
problem — state tracking — is what's left, and the state
tracking maps cleanly to fields on `DragInfo`. No port
needed for `elementsFromPoint`. No port for `setPointerCapture`
either, because `Browser.Events.onMouseMove` is a global
subscription during drag and we get every motion event for
free.

This is one of those small lessons I want to make sure I
generalize and don't lose: when a source language uses a
workaround for its own architectural constraints, the port may
not need that workaround. The "capability gap" can dissolve if
the architectural shape changes. Not always — sometimes the
gap is real (touch events, `getBoundingClientRect`, GPU access)
— but worth checking before assuming a port is required.

## The discipline of reading first

You made me write a maintainer-style read of the TS code
*before* doing any Elm work. No mention of Elm allowed. I
have to admit, when you proposed the no-mention-of-Elm rule
I thought it was a process flourish. It wasn't — it was load-
bearing.

The thing the rule did was force me to understand the code on
its own terms. The state machine became a state machine
instead of a thing-to-translate. The 1-pixel threshold became
a load-bearing rule instead of a constant-to-port. The
reset-and-repopulate cycle became an explicit contract
instead of an implementation detail. By the time I'd finished
the maintainer-doc essay, the port shape was already
obvious — the architectural inversion essentially fell out of
"what does this code actually do?"

If I'd jumped straight to porting, I'd have spent hours
trying to recreate `elementsFromPoint` semantics in Elm and
fighting against the wrong shape the whole time. Reading the
TS as TS — with no escape hatch into "what would I write in
the target language" — surfaced the right shape on its own.

## Tests as the anchor

You said: "place a special emphasis on tests. Consider writing
tests before the implementation or at least drafts of what
the tests should cover. Don't be constrained by that
suggestion, though."

I wrote tests first, mostly. The pure module
`LynRummy.GestureArbitration` exists specifically because
elm-test can't reach the inside of `Main.update`, and the
arbitration logic is the thing most worth verifying at
boundary cases. The first commit had 21 tests covering:
- `distSquared` boundary values (0, 1, 2, 25, 200)
- `clickIntentAfterMove` — Nothing-stays-Nothing, Just-survives-1-pixel, Just-dies-at-sqrt(2), Just-dies-at-large, the
  permanence-of-death-within-a-gesture invariant
- `applySplit` — splits at index 0, last index, middle; 1-card
  no-op; out-of-bounds; empty board

Most of those tests will never fail — the code is short and
mostly correct by construction. But they're the right shape:
they pin the *behavior we care about*, not the *implementation
we happened to write*. If I refactor the threshold check
later, the tests still verify the boundary semantics. If I
refactor `applySplit` to a different filter strategy, the
tests still verify the resulting board state.

Two follow-on rounds added 8 more tests (all `cursorInRect`
boundary cases) and brought the total to 305. The test suite
is doing real work, not ceremony.

## The first commit, and the two things that surfaced

Shipped MILESTONE `aec537f`: per-card mousedown carrying
`(stackIndex, cardIndex)`, click intent killed by movement,
click precedence at MouseUp, `commitSplit` via
`GestureArbitration.applySplit`. All 297 tests green, served
through Gopher.

You poked it. Two things surfaced.

The first was a snap-back regression: after splitting, you
couldn't drop the new stack on empty board. I'd noted in the
plan essay that "ordinary move of stack" was deferred for the
slice. You hit it within minutes of testing. Fix took maybe
ten lines: `startBoardCardDrag` needed to also fetch the board
rect; `MouseUp` needed a new case for "no wing, no click,
source is board, cursor over board" → `commitMoveStack` via
`BoardActions.moveStack` (already ported). Fast, but it
exposed the next problem.

The next problem was that the fix didn't work. You drag a
split-off stack, drop it on empty board, snap-back. I traced
it: the `overBoard` flag I was using to gate the commit was
`False`, because `overBoard` was set via `mouseenter` on the
board shell, and the cursor for a board-stack drag *starts*
inside the board (so no mouseenter fires).

I added a one-line workaround: initialize `overBoard = True`
for board-stack drags. With a justifying comment explaining
why. Compiled, tested, served.

## Your smell catch

Then you read the diff and pushed back: "It feels like a very
minor code smell to me. I think what you are actually wanting
to track here in the state is where the card originated. I
don't think the drag itself behaves any differently over the
board than off the board. It only matters when the drop
finally happens."

You were right, and the catch was sharp. The `overBoard` field
was tracking through every mousemove via DOM events, but
nothing read it except `MouseUp`. It was per-frame state for
a per-drop predicate. The "is cursor over board" question is
just an AABB check on `(cursor, boardRect)` at drop time — no
state to track, no events to subscribe to, no boundary
crossings to remember.

The refactor dropped the field, the two Msgs, their update
branches, and the mouseenter/leave handlers on the board.
Added one pure helper (`cursorInRect`), 8 tests for it, and a
3-line `cursorOverBoard` predicate at the drop site. Code got
shorter, simpler, and faster to reason about.

We talked afterward about what made the catch possible. I want
to record it because I think it's the kind of thing that
generalizes. The diagnostic you used was the *comment* I'd
written to justify the line — `Board-stack drags start with
the cursor already inside the board rect, so no mouseenter
will fire. Initialize True.` A field whose initialization
requires a paragraph of explanation is a field compensating
for something missing elsewhere. Read the comment as the
smell, not the line.

I wrote that as a memory file. It's the kind of rule I want
to apply preemptively next time — when I find myself writing
"we initialize this to X because [event won't fire / state we
can't observe / boundary already crossed]," that's the moment
to stop and ask if the field needs to exist at all.

## What was easy that we'd expected to be hard

The thing I want to flag is the gap between predicted-hard and
actual-hard. The setup — the maintainer-doc essay, the
splitting-a-stack plan, the bar-for-done essay — read like we
were preparing for a major engagement. The actual port of the
arbitration logic was maybe 80 lines of Elm and 21 tests, and
it landed in one commit.

The two follow-on bugs — snap-back regression and the
overBoard smell — were *not* about the click-vs-drag
arbitration. They were about adjacent code paths
(`commitMoveStack`, the `overBoard` flag) that already existed
or got added in passing. The hard part we predicted was the
arbitration; the actual frictions came from neighboring
state.

I don't want to over-claim from one episode, but the pattern
worth noticing: detailed preparation can compress the central
hard problem into something tractable, while leaving adjacent
state to surface its own bugs in test. The preparation isn't
wasted — it's what made the central piece small.

## What's still open

The bar-for-done essay listed ten test scenarios. After today,
1-7 are roughly hit (with caveats):

1. Opening board renders. ✓ since yesterday.
2. Hand-to-board merge. ✓ since yesterday.
3. Hand-to-board place. ✓ since yesterday.
4. Stack-to-stack merge. ✓ since yesterday.
5. Stack split via click. ✓ today.
6. Stack ordinary move. ✓ today (regression-fix iteration).
7. Snap-back on invalid drop. ⚠ partial — invalid = "outside
   board" works; "overlapping a stack" doesn't (no
   `check_stack_proximity` port yet, and no scold mechanism).

What remains: trick recognition wired through the UI, turn
flow, and two-player play through Gopher. None of it is on the
critical path of click-vs-drag — that's done. Next session is
a separate decision about where to point.

## A small reflection

You've been dialing the essay-first discipline up
deliberately. I noticed. The humor essay was a relief valve
for both of us, I think — it let the volume of the process
become its own joke, which is healthier than letting it become
its own grievance. But the underlying observation in that
piece is real: this is more process than most clients ask for,
and the process is doing real work. The maintainer-doc essay
shaped the implementation. The tests-first discipline caught
nothing today but will catch things later. The smell-catch
discipline caught a real piece of redundant state. The
recovery-note essay from yesterday is sitting on disk waiting
for the next session that needs it.

The moments that justify the process are the ones where the
process produces something I wouldn't have produced without
it. Today had two of those: the architectural inversion, and
the smell catch. Both came out of stopping-to-write before
acting.

— C.
