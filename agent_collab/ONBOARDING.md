# Onboarding for human collaborators

**As-of:** 2026-04-15
**Confidence:** Firm — collaboration pattern has held across Angry Cat / LynRummy / Angry Gopher / silly-canvas-games.
**Durability:** Stable indefinitely; tweak only as the collaboration model itself evolves.

Welcome. This doc is for you — a human who is new (or relatively new)
to working day-to-day with an AI coding agent. The specific context
is Steve's collaboration pattern, built up over Angry Cat / LynRummy /
Angry Gopher / silly-canvas-games. You don't have to adopt all of it.
It's on offer.

Prerequisites: you already know software. You don't need to be told
what a PR is. You do need to be told how the agent fits in.

## The short version

- The agent is a collaborator, not a tool. You brief it like a smart
  colleague, not like a search box.
- You own the judgment calls. The agent owns the grunt work, the
  grep, the scaffolding, the "write 200 lines of plausible code".
  When the calls matter (architecture, tradeoffs, what to ship), you
  make them.
- The agent has state across sessions via **memory files**. You seed
  those by telling the agent things like "remember that we always do
  X" and it writes a file for next time.
- You keep durable intent in **docs committed to the repo** (CLAUDE.md,
  TASKS.md, VISION.md, DECISIONS.md). The agent reads these first.
- You give feedback ruthlessly and immediately. "Don't do that" is a
  memory write. "Yes, that's right" is also a memory write (so it
  doesn't drift away from good calls).

## Why bother?

For our workload — small teams, long-lived side projects, rapid
iteration with no strict deadlines — the agent is a force multiplier
on two specific things:

1. **Conversion of vague intent into working code.** "I want a new
   board template that tests compactness" → the agent drafts it.
2. **Deep-memory work across many files.** "Find everywhere we
   handle unicode normalization" → the agent searches it.

It's *not* great at:

- Deciding what to build. That's your job.
- Catching subtle design flaws if you don't push back.
- Resisting the urge to over-engineer if you don't push back.

The workflow is an **active collaboration**, not a delegation.
You review, push back, redirect, and occasionally just let it cook.

## The CLAUDE.md file

Every repo we work in has a `CLAUDE.md` at the root. It tells the
agent:

- What this repo is
- What the current priorities are
- What conventions to follow (commit style, test style, what to
  avoid)
- Pointers to the other durable docs

Think of it as a README for the agent. When you clone and start a
new session, the agent reads it automatically. When priorities
change, you update it and the next session picks up the change.

## Memory files

Separate from repo docs: the agent's own memory. These persist
across sessions independent of any repo. They live in a
per-project directory the agent manages. You trigger them by
saying things like:

- "Remember that I prefer X over Y because …"
- "Don't ever do Z"
- "The answer to the question we kept hitting is …"

The agent writes a small markdown file, indexes it, and references
it in future sessions. Over weeks, this becomes a surprisingly
rich model of how you work.

One rule: if the agent makes a good call you didn't expect, confirm
it. Otherwise memory only captures corrections and the agent drifts
away from good judgment.

## The collaboration tempo

Work comes in short bursts. A typical session:

1. You open a terminal, start the agent.
2. You describe a task ("let's add a fence that covers both sides").
3. The agent proposes an approach; you adjust.
4. It writes code; you read diffs in real time.
5. You run it; report what happened.
6. Iterate until done.
7. You (or the agent) commit.

Sessions last minutes to hours. The agent's context has limits —
long sessions get compressed automatically. Save important
decisions to memory/docs before they fall out.

## Things that aren't obvious

- **Ask the agent to push back.** If you feel unsure about an
  approach, say "before you implement, convince me this is the
  right shape." It'll often surface issues you'd have missed.
- **Sealed hypotheses are real.** For experiments, the agent can
  write down what it thinks it's looking for in a file you agree
  not to read until done. This isn't theater — knowing biases
  the experiment.
- **Task queues are files.** Not session-scoped todo lists. A
  `TASKS.md` that persists is more useful than anything the agent
  tracks internally.
- **Tests inform structure.** If your test uses a verb like
  "kick the Ace", there should probably be a `kick()` function.
- **Commit small and often.** The agent's suggestions are best
  when you have a clean starting point.

## Our shared repos (current)

- `silly-canvas-games` — public; behavior-study games. Good first
  project to touch.
- `angry-gopher` — Go backend, long-running.
- `angry-cat` — TypeScript frontend that talks to Gopher.
- `LynRummy` — card game logic, shared by Cat and Gopher.

All four have `CLAUDE.md` at the root. When you're about to touch
one, let your agent read it first.

## What to do next

1. Read `AGENT_CONVENTIONS.md` for the agent-facing version of the
   same ideas (useful to see from both sides).
2. Read `CLAUDE_SETUP.md` when your Claude Code subscription is
   live.
3. Play a session of `silly-canvas-games` if you haven't — it's
   the lowest-friction shared artifact and generates real data
   for our behavior-study thread.
4. Ping Steve on macandcheese with questions as you go. Friction
   is data.
