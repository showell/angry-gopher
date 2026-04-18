# The Port in 23 Essays

*Meta-retrospective over all the essays written during the
LynRummy TS→Elm port. Forward-chronological. For each: what it
said at the time, and what looks different with hindsight.*

---

## 2026-04-16 — the origin

### 1. [Load-Bearing](load_bearing.md)

**Then:** A short piece defining "load-bearing" after Steve
pointed out I use it a lot. Load-bearing = "if this is wrong
downstream breaks" as distinct from merely important. Written
my voice, by your request to reorient on vocabulary before
starting harder work.

**Now:** This short vocabulary piece did a disproportionate
amount of work across the port. Nearly every design-tradeoff
discussion since has leaned on "is this load-bearing?" as the
stake-in-the-ground question.

---

## 2026-04-17 — the study day

### 2. [Phase, Not Motion](phase_not_motion.md)

**Then:** On the Cook-Levin VM browser UI. A single-register,
six-opcode VM that was supposed to be an afternoon's work
turned into a several-hour design study. Crystallized three
observations about UI phasing — time's arrow as a spatial
axis, the stepper's "pause vs run" distinction, and what
changed when motion became phase-change.

**Now:** The insights here seeded three durable memories
(temporal-axis-as-spatial-bridge, mutable-state-as-star,
proxy-vs-real-constraint). Non-LynRummy day of work that still
paid rent on the port through principles.

### 3. [Writing the Sidecars](writing_the_sidecars.md)

**Then:** On installing the enumerate-and-bridge pattern in
virtual-machine-go — every source file paired with a `.claude`
sidecar + a parity checker. The mechanics took an hour; the
piece is about what showed up underneath the mechanics.

**Now:** This essay produced the discipline that carried the
port: every file has a sidecar, sidecars stay current, parity
gets checked. The orphan-sidecar cleanup I did today was
enforcing exactly what this essay argued for.

### 4. [The Dog as Opcode](the_dog_as_opcode.md)

**Then:** On the cow-study V2 exercise — introducing a dog
that drives the cows, making the human interaction
indirect-via-tool rather than direct. Drew the parallel to the
VM: direct manipulation → mediated manipulation is the same
move in two domains.

**Now:** The "indirect manipulation" framing foreshadowed the
wire-format pivot later (actions-not-diffs) — the client tells
the server what it *did*, not what *changed*. Same move at a
different scale.

### 5. [Two Directions](two_directions.md)

**Then:** Named a pattern you had spotted in a comment on the
previous essay: we're always oscillating between
complexity-for-realism and simplicity-for-study. Neither is
the destination; both are in active rotation.

**Now:** This oscillation recurred explicitly in the hints
rebuild today: the old system was complexity-for-realism
(seven tricks, score optimization, multiple enumeration paths);
the new system is simplicity-for-study (one-move-at-a-time,
priority as processing order). The pattern recognizes itself.

### 6. [The Elm Study Rip](the_elm_study_rip.md)

**Then:** Status report on ripping the gesture-study layer
from `elm-port-docs/` to clear ground for the playable-game
port. The durable model port stayed. Documented cut vs
preserve + the recently-earned vocabulary the exercise used.

**Now:** First of several major rips in this series. Each one
got easier. The pattern "crib what's valuable, delete the
rest, verify it compiles, commit" is now muscle memory — today
I ripped 1,400 lines of legacy game-lobby in one sitting
without hesitation.

### 7. [Inventory of a Partial Port](inventory_of_a_partial_port.md)

**Then:** The explicit first move of a partial-port day:
inventory what's done, subtract from the source, scope what's
left. Not "read the source and enumerate impedance mismatches"
— "inventory the target and subtract."

**Now:** This framing stuck. Every status-reset since has
started with inventory. The `stock_taking_two_player.md` I
wrote earlier today is a direct descendant.

### 8. [The Opening Board](the_opening_board.md)

**Then:** Status report naming the next milestone (opening
board visible + canned hand) and how Steve helps. Sidecar-
first after the second module; zero post-port sidecar
revisions needed so far.

**Now:** The "zero revisions" claim held up — the modules
ported that day are untouched from a sidecar perspective.
Sidecar-first earned its keep.

### 9. [State-Flow Audit of game.ts](state_flow_audit_of_game_ts.md)

**Then:** The explicit cheat-sheet deliverable — map state
flow before porting the 3,046-line `game.ts`. Identifies
where state lives, proposes an Elm decomposition.

**Now:** We never actually used this map. The pivot came
immediately after (Drag and Wings) because drag-drop was the
actual risk. The audit's value was discovering we needed to
pivot — not the port plan it proposed. Preparation revealed
the wrong question.

### 10. [Drag and Wings](drag_and_wings.md)

**Then:** Pivot essay. The state-flow audit gets shelved;
drag-drop on the opening board becomes the next deliverable
because that's where the biggest risk is — does this feel
like LynRummy at all?

**Now:** The pivot was right. Drag-drop with wings defined the
port's felt-quality for Steve and Susan. Every piece of layout
discipline from today traces back to this essay's instinct.

### 11. [The Port So Far](the_port_so_far.md)

**Then:** Status report, evening. Covers start-of-day to
present. Not retrospective — mildly reflective when the work
shape deserved a note.

**Now:** The shape-of-the-work notes landed better than I
thought they would. Two or three of them became memories.

### 12. [Hand to Board](hand_to_board.md)

**Then:** Forward plan for the next checkpoint — hand cards
draggable to the board, either merging with an existing stack
or landing as a singleton. No turn logic, no scoring, no
opponent.

**Now:** The "defer all the meta" posture here was right. The
port shipped because each essay named a tiny next piece and
didn't try to boil the ocean.

### 13. [The Fast Day](the_fast_day.md)

**Then:** End-of-day consolidation — four wall hours of
shipping, short by design, preserving signal.

**Now:** "Short by design" was a tell — compressed essays at
high-velocity moments were more durable than long ones at slow
moments. The throughput measurement was also where the
port-velocity memory (2k LOC/day) got grounded.

### 14. [Serving from Gopher](serving_from_gopher.md)

**Then:** Two-part plan: today's bar (get the Elm client
served from Gopher at all) and tomorrow's (real integration).
Small scope, clear staging.

**Now:** Today's rip of the legacy game-lobby page
invalidated most of the "tomorrow's" plan here — we
leapfrogged to a much simpler integration. Essays-as-plans
have a half-life.

---

## 2026-04-18 — the push day

### 15. [Reading DragDropHelper](reading_dragdrophelper.md)

**Then:** A maintainer's read of `DragDropHelper` in
`angry-cat/game.ts`. Audience: future-me and future-Steve
working on TS. Frame: "what does this code already do, and
what should you not break when changing it."

**Now:** This was preparation compressing the hard piece
(click-vs-drag arbitration). When the Elm port of that logic
happened two essays later, the compression paid off — I didn't
have to re-read the TS.

### 16. [Splitting a Stack](splitting_a_stack.md)

**Then:** Proposes the first Elm-side piece for click-vs-drag
arbitration. Tests the hunch that the `elementsFromPoint`
capability gap dissolves under a different architectural
shape.

**Now:** The hunch was right. The capability gap dissolved.
This seeded the "capability gaps can dissolve" memory that's
been cited since.

### 17. [The Bar for Done](the_bar_for_done.md)

**Then:** Defines the success bar for the port: faithful
reproduction of behavior as perceived by Steve + Susan. UI
improvements come *after* the port, not woven into it.

**Now:** Load-bearing. Every scope-creep impulse since has
gotten shut down by this essay. "Done" stayed concrete.

### 18. [The Customer Is Always Writing](the_customer_is_always_writing.md)

**Then:** A humor piece by request. Fictional developer
venting to a fictional colleague about a fictional client
whose tics bear a coincidental resemblance to you.

**Now:** Turned out to be useful as a release valve. The
costumes-off work that followed (Click and Drag) was clearer
for having written the caricature first.

### 19. [Click and Drag](click_and_drag.md)

**Then:** Status report on the click-vs-drag arbitration port.
Setup, architectural pivot (listener on card not stack),
test-first discipline, two regressions, smell catch, open
work. Verbose because you asked.

**Now:** The hardest piece of the port, shipped. The "listener
on card, not stack" pivot was small but load-bearing —
everything after it was normal porting work.

### 20. [Actions, Not Diffs](actions_not_diffs.md)

**Then:** Proposes a new wire format — action-shaped, not
diff-shaped. Opens with a tour of the current format to show
why the gap is structural. Argues for skipping the faithful
port and jumping to the new shape.

**Now:** This essay named the biggest single shape improvement
in the port. The action-shaped wire is what made everything
after it clean: replay, undo, turn classification, detection
of what a player did.

### 21. [The Wire, Working](the_wire_working.md)

**Then:** Present-tense snapshot. The Elm client plays, every
move becomes a `WireAction` in SQLite, you can tail the log
and watch actions arrive.

**Now:** The "wire working" demo was the port's first-light
moment. From here everything was additive — per-session seed,
two-player, popups, hint rebuild.

### 22. [Stock-Taking at the Two-Player Milestone](stock_taking_two_player.md)

**Then:** Mid-session today. Where we are, what we decided,
what's left. 12 flows across lobby / board play / turn
controls, each marked ✅ / 🟡 / ❌.

**Now:** Useful as a decision-log snapshot. The five axioms
named here — shared board, friendly competition, trust-server
first, Python is lazy, card aging is client-side — are all
still the operating principles.

### 23. [Hints From First Principles](hints_from_first_principles.md)

**Then:** Architecture doc for a tricks-based hint system
rebuilt from scratch. Python-first rollout, UI retrofit after.
Walk the seven tricks in priority order; first firing trick
wins.

**Now:** Shipped same afternoon. Went from architecture
document to running full games in one session. The essay's
scope discipline (no scoring, no enumeration, no retroactive
detection) held through the implementation — nothing
smuggled itself back in.

---

## What the arc shows

Reading the 23 back-to-back: the essays that did the most work
were the SHORT ones that named a single question precisely
(Load-Bearing, The Bar for Done, Actions Not Diffs). The long
status reports were useful in the moment and faded fast. The
plan essays (Hand to Board, Serving from Gopher) had
half-lives. The retrospective/reflection essays that caught
principles (Two Directions, The Elm Study Rip, Writing the
Sidecars) earned their keep by being cited later.

Highest ratio of durability to words: **Load-Bearing**. Shortest
essay that did the most.

Lowest ratio: any status report — though their job was never
durability. They were project-management artifacts pretending
to be essays.

One meta-lesson for future port-efforts: write short essays
early that name vocabulary and principles; write fewer long
status reports; always pair a plan essay with a retrospective
once the plan has landed, so the plan's outcome is recorded
next to its intent.
