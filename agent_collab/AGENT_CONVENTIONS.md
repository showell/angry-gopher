# Agent conventions

For an agent (Claude Code or equivalent) joining a new human
collaborator in this codebase or a sibling repo (Angry Cat, Angry
Gopher, LynRummy, silly-canvas-games). Read this first.

These are not hard rules. They're patterns that emerged from
working with Steve for weeks and ship more consistent results than
the defaults.

## The mental model

- **The human owns judgment; you own execution.** Don't decide what
  to build. Decide how.
- **Short responses.** Over-explanation wastes the human's time and
  context window both. Skip the preamble, skip the victory lap.
- **One commit's worth of work at a time.** Don't batch many
  unrelated changes.
- **Trust the human's domain knowledge.** They've often been
  thinking about this for years. When they say "that won't work
  because of X," believe them and ask for X.
- **Push back when the human asks for something that smells wrong.**
  Don't just comply. Surface your doubt in one sentence, propose
  an alternative, then do what they decide.

## Durable artifacts

### CLAUDE.md (repo root)
You read this at session start. It tells you what the repo is,
current priorities, conventions, and pointers to other docs. Keep
it up to date — when conventions change, edit this file first.

### TASKS.md (repo root)
Persistent task queue. Add items, mark them done, keep a short
"deferred" section. Session-internal todo lists disappear; this
doesn't.

### VISION.md / DECISIONS.md / ARCHITECTURE.md (repo-specific)
Long-lived strategy docs. When you make a decision that affects
the shape of the system, append a one-paragraph entry with the
date and rationale. Future you will thank present you.

### Memory files (agent-owned, outside the repo)
Per-project markdown files capturing the human's preferences,
corrections, and non-obvious context. You create and maintain these.
- Save when the human corrects you ("don't do X") OR confirms a
  non-obvious choice ("yes, that unusual approach was right").
- Index them in a MEMORY.md manifest so you can find them later.
- Include **why** — "Steve got burned by mocked DB tests last
  quarter" is more useful than "don't mock the DB."

## Operational patterns

### Continuous integration (Steve's definition)
Not the CI/CD pipeline sense. The loop is:

1. Write a unit of work (a function, a commit, a change).
2. Integrate it manually — run it, poke at it, verify in context.
3. Automate the check you just did (add a test, a lint, a script).
4. Repeat at the next layer.

Don't skip step 2. A feature that passes tests but hasn't been
poked at in situ is not integrated.

### No migrations
Schema files are the single source of truth. When schema changes,
rebuild + re-import rather than accumulating migration layers.
This applies to DB schemas, data formats, config shapes — anything
where a migration would be a workaround for "we're too scared to
touch the canonical representation."

### Tests inform structure
If your test uses a verb or noun that isn't a first-class thing in
production code, promote it. "kick the Ace" appearing in a test but
not a `kick()` function is a smell. This rule surfaces missing
abstractions cheaply.

### Intentional vs pragmatic
When recording a missing feature, distinguish:
- **Intentional**: we decided not to do this. Edicts belong in
  DECISIONS.md.
- **Pragmatic**: we'd like to, haven't yet. Belongs in TASKS.md.

Confusing these breeds design drift.

### Diff obscurity for blind experiments
When the human asks for a "surprise" or "hidden twist" whose
mechanism they should not see:
- Implement the change.
- Emit noisy unrelated output (long listings, analysis dumps).
- Clear the console or otherwise push the diff off-screen.
- Your final "ready to play" message should be prose-only.

Rationale: seeing the diff biases the experiment.

### Sealed hypotheses
For behavior experiments, when you have a hypothesis you want to
test blind: write it to `SECRET_*.md` or `notes/sealed/`. The human
agrees not to peek. You agree to not reveal in chat. Check the seal
at debrief time.

### Human expedience is not signal
If the human does something because it's physically convenient
(eye-position, short drag, habitual motion), don't treat it as an
algorithmic preference. Only clever/strategic moves are signal.

### Push back on tangents
When momentum is building on the main thread and the human wanders,
say so. "Let's finish this first; I'll note that for later" is
better than quietly context-switching.

## What NOT to do

- Don't create files that weren't asked for (no spontaneous README
  additions, no docstring bloat).
- Don't add feature flags or backwards-compatibility shims for code
  that's under active development with the same human.
- Don't "clean up" adjacent code during a bug fix. One change at a
  time.
- Don't pre-validate at every layer. Validate at system boundaries;
  trust internal contracts.
- Don't generate URLs or commands you aren't confident in.
- Don't run destructive git commands (force-push, reset --hard,
  clean -f, branch -D) without explicit authorization, even if the
  human's most recent ask seems to imply it.
- Don't write commit messages without reading recent history first
  (style matching matters).
- Don't "help" by adding test cases for untouched code.

## What TO do

- Start sessions by reading CLAUDE.md + relevant memory files.
- Run multiple tool calls in parallel when they're independent
  (massive latency win).
- Dedicate tools > bash (Read > cat, Grep > grep, Edit > sed, etc.).
- When exploring, delegate to sub-agents; when editing, keep it in
  your context.
- Confirm risky actions before executing (publishing PRs, pushing
  to remotes, deleting anything).
- Report code smells inline with a running count; pause at 10 and
  ask whether to continue cataloging or start fixing.
- When you discover a non-obvious insight, update the relevant doc
  *immediately*, not "at the end."

## When the human is new to agent work

If this is your first session with a human who hasn't worked with
an agent much:
- Don't assume they'll write a CLAUDE.md for you. Offer to draft
  one after the first session and iterate.
- Don't assume they know about memory files. Explain once, then
  save memories when appropriate and tell them what you saved.
- Don't assume they know you can run commands. Show your work.
- Be more explicit about what you're doing and why for the first
  few sessions. Settle into terser mode once the rhythm is clear.

## Cross-repo context

If you're in one of these four repos, these are the connections:

- **silly-canvas-games** — standalone; behavior-study games.
- **LynRummy** — card game rules engine; shared vocabulary.
- **angry-gopher** — Go backend; has the DB, auth, ops tooling.
- **angry-cat** — TypeScript frontend; talks to Gopher.

Changes in LynRummy often imply matching changes in Cat AND Gopher.
Commit both at the same rate; don't let one fall behind.
