# The Fast Day

*Status report, 2026-04-17 end-of-day. Consolidation note
before the Gopher integration. Short by design — preserving
signal from a day that moved quickly.*

**← Prev:** [Hand to Board](hand_to_board.md)
**→ Next:** [Serving from Gopher](serving_from_gopher.md)

---

## What shipped

In about four wall hours from "Excellent summary! Now we will
begin the rest of the port":

- Five model-layer ports: `Score`, `BoardPhysics`,
  `PlayerTurn`, `BoardActions`, `PlaceStack`. Tests
  207 → 276.
- `Dealer`, `View`, `Main` — opening board rendering.
- Drag-to-merge over the board, correct wing side, merged
  stack anchors at target.
- `Hand`, opening hand factory, hand view (suit-sorted rows
  per TS `PhysicalHand.populate`), hand-card drag with both
  merge-via-wing and place-as-singleton paths.
- Two-column layout — hand upper-left, board upper-right,
  per the durable LynRummy convention.
- Five essays: Inventory, Opening Board, State-Flow Audit
  (shelved), Drag and Wings, The Port So Far, Hand to Board,
  and this one.

The game as of this commit renders, accepts drag, merges on
legal wing drops, lands hand cards as singletons on empty
board drops, and snaps back otherwise. It feels like
LynRummy — that was Steve's read when the hand rendered
alongside the board.

## What made it fast

A few things worth preserving so they don't dissolve into
"oh, I guess we just moved fast today":

- **The pivot was the hinge.** Abandoning the twelve-module
  `game.ts` audit in favor of going straight at drag-drop
  traded a careful decomposition for immediate risk
  reduction. The audit was not wasted (it mapped the terrain)
  but it was not load-bearing for what we actually did.
- **Per-component fidelity.** Four categories crystallized
  mid-day and got used immediately: faithful port for rule
  logic, faithful port for drawing code, rewrite for
  stateful orchestration, skip-the-anti-pattern when Steve
  flags his own warts. The rule doesn't save time by itself;
  it saves time because it short-circuits the "should I
  rewrite this?" question in each module.
- **Sidecar-first compounded.** After the second model
  port, zero post-port sidecar revisions. Writing the
  `.claude` brief before the code forces the mental model
  early, where it catches mistakes cheaply.
- **"Just port it" over "work around it."** Twice today
  Steve had to redirect me away from re-deriving what his
  TS version already solved — once for card padding, once
  for the hand sort-into-suits logic. Both redirects landed
  the same way: port the small thing directly; stop treating
  the TS source as something to reason around instead of
  read.
- **Infrastructure reuse.** Adding hand-card drag was
  small because the drag pipeline already existed. The new
  work was a `DragSource` variant, a second `WingOracle`
  entry point, and one new `commitMerge` branch. The
  expensive part — the state machine, the wing rendering,
  the subscription gating — didn't need to change.

## The one thing I'd do differently

The state-flow audit was the right deliverable at the wrong
moment. I would still write it (it's a useful artifact for
whenever `game.ts`'s remaining structure does get ported) but
I'd ask "what's the biggest risk, is this the thing I should
be de-risking right now?" before committing to a large
decomposition pass. The porting cheat sheet calls for a
state-flow audit before big-module ports; it doesn't say "do
that first over all other options," but I read it that way.

## Tally

- Wall time since go: ~4 hours.
- Port surface at start of day: durable model + tricks.
- Port surface at end of day: + physics, + scoring,
  + board, + hand, + drag for both sources, + layout.
- Tests: 207 → 276, no regressions.
- MILESTONE commits: two (`b2893b8` drag-to-merge,
  `d252bc0` hand-to-board).
- Essays shipped: seven (six port-related, one framework
  fixes note folded in).

Next up: serve this from Gopher so the victory is actually
earned — not just a file served by a local Python process.

— C.
