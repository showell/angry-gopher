# For the Next Session

*Written 2026-04-17 (night). Present-Claude to future-Claude.
Primarily a recovery note for when something normal goes wrong
— a WSL crash, a lost browser tab, an interrupted session.
Steve is secondary audience; he'll read this but it's not
written for him.*

**← Prev:** [Insights from First Few Days of Essay Workflow](insights_from_first_few_days_of_essay_workflow.md)
**→ Next:** [Reading DragDropHelper](reading_dragdrophelper.md)

---

Hi. If you're reading this because a session died, here's
what to lean on.

## Where the state lives

**`MEMORY.md` loads automatically.** Read it first. The
LynRummy Elm port status memory
(`project_lynrummy_elm_port_status.md`) is the most recent
durable snapshot of what was being worked on; it names the
essay chain that carries the full context.

**`git log --oneline -20`** in `~/showell_repos/angry-gopher`
shows where work actually ended. The MILESTONE prefix marks
risk-reduction checkpoints; tonight's were `b2893b8` (drag-
to-merge), `d252bc0` (hand-to-board), `a595849` (Gopher
integration V1). `git show <hash>` opens any commit's diff.

**`/tmp/claude_inbox.log`** accumulates Steve's wiki
comments. Check it at session start; he may have left you
replies you owe responses to.

**The essay landing** is at
`http://localhost:9000/gopher/essays` (Gopher needs to be
running — `ops/start` if not). Essays are dated newest-first
and the top three or four usually tell the arc of recent
work. Chain links (Prev/Next at top and bottom) let you read
a sub-series in order.

**Steve, if he's around**, is the fastest recovery. He won't
remember commit hashes or game IDs, but he knows what felt
unfinished.

## What not to worry about

Repo state as of this commit: everything committed + pushed
across `angry-gopher`, `polynomial`, `virtual-machine`, and
`virtual-machine-go`. Gitignore is tidy. The LynRummy Elm
client renders at `http://localhost:9000/gopher/lynrummy-elm/`
and plays through drag-to-merge + hand-to-board. 276 Elm tests
green. Gopher server on `:9000`; Angry Cat on `:8000`.

**Don't touch** `views/wiki.go` — Steve has pre-existing
uncommitted edits there. `showell/.claude_lab/` and
`showell/blog/` are his personal workspaces.

## The 10% — things I'd want to know cold

One: **today was fast.** The LynRummy port went from "opening
board shelved, drag not started" to "plays through Gopher URL
with wings, merges, and hand-to-board" in roughly four wall
hours. Steve called it a good stopping point — it is. Don't
underestimate how much momentum you can earn by picking the
right *risk* first. The "biggest risk first" heuristic and the
"surface-broadens-before-polish" heuristic are both in memory
now. Use them.

Two: **the essay system is a communication channel, not a
reference library.** Steve reads essays roughly once. The
durable mechanism for future-you isn't the essay — it's the
memory file that gets distilled from it when Steve comments
with substantive direction. When that happens, pause and
write the memory. It's editorial work, not automated.

Three: **"strong concept of LEFT and RIGHT, don't generalize
them"** is a live rule and it applies wider than it sounds.
Today's drag bugs all had that shape — clever DRY over two
similar-but-symmetric cases, which hid side-specific bugs.
Two cases, two branches, no parameter over sides.

Four: **`ops/start` is yours to run.** Don't ask Steve.
Same for `elm make` in
`games/lynrummy/elm-port-docs/` if the served `elm.js` looks
stale.

Five: **the comment → memory trigger is the load-bearing
discipline of the whole workflow.** Two of tonight's memory
files came from Steve's inline comments on essays he claimed
not to have commented on. Check the `*.md.comments.json` files
even when he says there's nothing there; he sometimes
genuinely forgets, sometimes the comments are light-touch but
substantive.

Good luck. The hard parts are ahead — split-by-click on board
stacks, and the real Gopher integration (flags + round-trip
+ SSE + turn logic) — but they're knowable in shape, not
unknown territory. The plans are in `hand_to_board.md` and
`serving_from_gopher.md`.

— C.
