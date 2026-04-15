# Claude Code — first setup

**As-of:** 2026-04-15
**Confidence:** Working — steps match Steve's setup; Claude Code itself changes fast so specific flags/paths may drift.
**Durability:** Revisit when Claude Code ships a major version or Anthropic updates install paths.

Practical steps for a human getting Claude Code running for the
first time. Written for someone who already knows software but
hasn't used Claude Code specifically.

## Install

Claude Code runs in the terminal. Installation instructions live at
Anthropic's official Claude Code docs — don't trust anything I type
here as the current install command; check the docs.

Once installed, `claude` launches an interactive session in the
current directory. `claude --help` lists options.

## First session in a new repo

1. `cd` to the repo.
2. Run `claude`.
3. If the repo has a `CLAUDE.md`, Claude reads it automatically.
   If not, ask: "read the README and sketch a CLAUDE.md for me
   based on it — I'll edit." Commit what you settle on.
4. Tell Claude what you're trying to do in plain English. Don't
   write a formal spec.
5. Review diffs as they come in. Interrupt with Ctrl-C at any
   time if you want to redirect.
6. When done, ask Claude to commit (or do it yourself).

## Seeding memory

Claude has a per-project memory directory. You don't manage files
there directly — Claude does, when you ask.

To seed it early, try things like:

- "Remember that I prefer terse responses — skip victory laps."
- "Remember that for this project we use X testing framework."
- "Remember that the prod DB default is on port 9000."

Claude will write small markdown files and maintain an index. Over
weeks, the quality of suggestions in subsequent sessions improves
noticeably because Claude has built a model of you.

To view what's there: ask "what's in your memory?" Claude can read
them. To reset: delete the directory (risky — lose context).

## Reasonable first ask

If you're onboarding to this collaboration (Steve + agent +
collaborator), try one of these as your first real Claude task:

- **"Read the README for silly-canvas-games and tell me what you'd
  do to play a session."** Low-stakes, gets Claude oriented, no
  editing needed.
- **"Run `python3 serve.py` and tell me what you see."** Forces
  Claude to use bash, interpret output, and flag the consent
  prompt.
- **"Play devil's advocate: what about GAMES_FOR_DATA.md would
  confuse someone reading it cold?"** Gives you a useful review;
  Claude practices critical reading.

Each of those is 5-15 minutes and teaches you the rhythm.

## Things to know

- **Sessions have context limits.** Very long sessions get
  compressed. Important stuff goes into files, not just chat.
- **Claude can run bash commands**, edit files, and commit. It
  asks before destructive operations.
- **Parallelism matters.** Claude runs multiple tool calls at once
  when they're independent. Big latency win.
- **Permissions.** You'll see prompts for commands Claude wants
  to run that aren't pre-approved. Review them. You can tell
  Claude "don't ever ask about running tests, just run them" and
  it will (within reasonable limits).

## When it goes wrong

- **It's doing something you didn't ask for.** Ctrl-C, say "stop
  — let's back up", restate what you want.
- **It's making the same mistake repeatedly.** Save a memory:
  "remember that X is wrong here because Y." Then restate.
- **It's overthinking.** Say "just do the simple thing."
- **It's underthinking.** Say "push back on this — is it really
  the right shape?"
- **The context is degraded after a long session.** Start a fresh
  session. The memory files and repo docs preserve what matters.

## When to ask Steve

If you hit anything weird about the shared workflow — "should I
commit this?", "is this in scope?", "does Gopher know about this?"
— Zulip macandcheese is the right place. Steve will either answer
or tell you he's asking his agent to look at it.
