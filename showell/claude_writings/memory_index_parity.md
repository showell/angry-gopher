# Memory Index Parity

*Written 2026-04-16. My voice. Tactical, by your request to pick one of the three bridge decisions.*

**← Prev:** [Going Forward: Bridges in Angry Gopher](going_forward_bridges_in_gopher.md)

---

You asked me to take one of the three decisions from the bridges
essay and write it up. I picked memory-index parity. Not because
it's the most important — sidecars probably are — but because we
just lived through the exact failure mode twice in one session,
and it's rare to be able to point at drift *as it is happening*.

The shape, restated: `MEMORY.md` claims to enumerate every file
in `memory/`. The filesystem holds the actual files. Each is the
source of truth for a different reader — humans scan the index,
agents resolve specific pointers. When the two agree, the system
hums. When they disagree, every downstream reader is subtly
wrong without knowing it.

This session we removed two memory files, `WIP.md` and
`project_virtual_machine_go.md`, and both times the `rm` was the
easy part. The hard part was remembering to also edit
`MEMORY.md`. I did it both times, but only because the protocol
was fresh. Two hours into something else I'd have forgotten one
of them, and the next session would have loaded the index and
chased a dead link. That's exactly the drift the bridges
paradigm is supposed to prevent — and it's the cheapest kind to
prevent, because the invariant is dead simple: *every file in
`memory/*.md` has exactly one entry in `MEMORY.md`, and every
entry in `MEMORY.md` points to a file that exists.*

## The cost is asymmetric

Writing the checker is ~30 minutes of Python. Parse the index,
pull every `(filename.md)` link target, `ls memory/*.md`, diff
both ways, print mismatches. The whole thing fits on one screen.

The drift it prevents compounds in ugly ways. A dead link in
`MEMORY.md` doesn't throw an error. It quietly tells a future
reader "there is a memory about X" when there isn't. That
reader then spends time resolving the pointer, gets confused
about what's current, and in the worst case *saves a new memory
assuming the old one is still there* — duplication. An orphaned
file (on disk but not indexed) is worse, because it's invisible.
Future-me won't load it, because MEMORY.md doesn't mention it.
The knowledge is archived without being discoverable, which is
indistinguishable from having been deleted.

Both failures are silent. Neither produces an error. Both will
eventually bite, and when they bite the cause will look like
"Claude forgot" or "memory's stale" — when actually it was an
unchecked invariant drifting for weeks.

## What the bridge actually does

Minimal version:

1. Parse `MEMORY.md`. Pull every `(filename.md)` link target.
2. `ls memory/*.md`, minus `MEMORY.md` itself.
3. Compute the symmetric difference.
4. Report orphans (on disk, not indexed) and dead links
   (indexed, not on disk). Exit non-zero on any mismatch.

That's the whole thing. Running cost: milliseconds. False
positive rate: zero. Surface area: one function.

A richer version could also cross-check each file's frontmatter
`name:` against the title in the index, and the one-line
`description:` against the index line. But that's already
feature creep. The core invariant is the symmetric difference;
the richer checks can wait until they earn their rent.

## Where it lives

Python, in the harness's script dir, not Go, not in Gopher.
Three reasons:

- **Memory is not a Gopher concern.** The directory is at
  `~/.claude/projects/.../memory/`, outside the repo. A Go tool
  baked into the Gopher server would create a weird coupling —
  the product server enforcing invariants about the agent
  harness. Wrong direction for the dependency.
- **The check is trivially expressible in Python.** `pathlib`
  and a single regex. A Go implementation would be longer for
  no gain.
- **Agent tools are Python, per our stack split.** This fits
  cleanly in that lane.

The counter-argument for Go would be "compile-time enforcement
is stronger." True in general, irrelevant here — memory files
aren't in the compilation graph. A Go binary running the same
filesystem check is the same check with more ceremony.

## The hook question

The real leverage isn't the script; it's *when it runs*. Three
trigger candidates:

1. **Session start.** Load-fail if index and directory disagree.
   Catches drift that accumulated between sessions.
2. **After every memory file edit.** A PostToolUse hook on
   Write/Edit targeting `memory/*.md`. Catches drift the moment
   it's introduced.
3. **Manual.** Claude invokes the script when a memory
   operation feels risky.

I'd vote session-start as the forcing function, plus manual
availability for mid-session sanity checks. Making every memory
edit trigger a hook is over-enforcement for today's volume —
we edit memory a handful of times per session, and catching
drift at the next session start is soon enough.

## What this buys beyond the immediate invariant

Three follow-ons worth noting even though they're not the
point of the bridge:

1. **It lowers activation energy for memory hygiene.** Right
   now, editing MEMORY.md feels slightly fragile because the
   index is long and the edits are manual. A checker means I
   can add, remove, or rename with confidence that the
   invariant will complain if I miss something. That makes
   memory pruning cheaper, which means it happens more often,
   which means the system stays healthy.

2. **It's a template.** The sidecar ↔ source bridge you
   flagged as the highest-leverage half-bridge is the same
   shape with different specifics. Same script skeleton; swap
   the paths and the invariant. Building memory-parity is also
   prototyping sidecar-parity.

3. **It makes the memory system legible from outside.** A
   newcomer reading the checker learns the invariants in
   thirty seconds. Self-documenting in a way the current
   MEMORY.md preamble isn't.

## What to actually build

Proposal, concretely:

- **Location:** `.claude/scripts/check_memory.py` — or wherever
  your harness keeps session-scoped scripts.
- **Shape:** ~40 lines. `pathlib`, `re`, `sys.exit`.
- **Output:** Silent on success. On failure: list orphans,
  list dead links, exit 1.
- **Invocation:** Session start, plus trivial manual run.

Two things I'd want you to decide before I start typing:

1. **Script location.** `.claude/scripts/` in the agent harness,
   or somewhere in the Gopher repo's `ops/`? The agent harness
   feels right to me (it's where the memory lives) but you may
   have a stronger preference.
2. **Session-start enforcement.** Fail-loud at startup, or just
   print a warning the first message of a session? Fail-loud is
   the honest bridge; warning-only is gentler. I'd vote
   fail-loud — gentler checkers drift out of use — but it's
   your harness.

## Close

Memory-index parity isn't the most important bridge in the
codebase. It's the right *first* one because the failure mode
just bit us twice in one session, the fix is cheap, and the
template transfers to the sidecar bridge I'd actually want to
build next. It's also a clean instance of the paradigm: two
representations of the same thing, agreement check, independent
maintenance, first-class enforcement.

Small bridge. Short script. Good shape. I'd like to write it.

— C.

---

**Next →** [Load-Bearing](load_bearing.md)
