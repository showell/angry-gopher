# Patterns cheat sheet

One-line reference to the conventions we use. For the fuller
rationale, see AGENT_CONVENTIONS.md. For the human-side take, see
ONBOARDING.md.

## Code

- **Tests inform structure** — verbs in tests → functions in
  production.
- **No migrations** — schema file is the truth; rebuild and
  re-import.
- **Intentional vs pragmatic** — edicts go in DECISIONS.md, TODOs
  in TASKS.md.
- **Commit small, commit often, commit both related repos**
  (Cat + Gopher or LynRummy + Cat together).
- **No feature flags or back-compat shims** for code under active
  joint development. Change it cleanly.
- **Delete code that's truly unused.** No `_unused`, no
  `// removed` breadcrumbs.

## Testing

- **Unit → manual integration → automation → repeat.** Don't skip
  manual integration.
- **Validate at system boundaries only.** Internal code trusts
  contracts.
- **Stats feedback loop** — aggregate metrics often surface hidden
  bugs faster than individual test cases.

## Communication with the agent

- **Memory on correction AND confirmation.** If you only save
  "don't do that", the agent drifts from good judgment.
- **Durable intent in files, not chat.** CLAUDE.md, TASKS.md,
  VISION.md, DECISIONS.md. Chat is ephemeral.
- **Push back on tangents** — "let's finish this first."
- **Short responses** — skip preamble and summary.
- **Distinguish human-expedience moves from algorithmic signals**
  when the agent is analyzing human behavior.

## Experiments (silly-canvas-games and friends)

- **Sealed hypotheses** in `SECRET_*.md` — human doesn't peek.
- **Diff obscurity** for blind twists — scroll diffs off-screen
  before "go play".
- **Raw measurements public; interpretations sealed** until
  debrief.
- **Table stakes for engagement**: cute critters, micro-rewards,
  clear penalties, visible timer, agency (next/quit/retry), round
  structure.
- **Ethics floor**: informed consent before recording, local-first
  data, easy to delete, no PII, opt-out mid-session.

## Problem-solving

- **Wish-framing terminates; "robbing Peter" is circular.** Reframe
  until the problem has a genius path, not a folly path.
- **Trust contracts.** Don't re-derive; believe the interface.
- **Chunks of three.** Large problems decompose into ~3 parts
  usefully; more often means you're still thinking too broadly.
- **Nip problems in the bud.** No strict deadline, so pay for
  cleanups now.

## Process

- **Continuous integration (our sense)**: unit → manual-integration
  → automate → repeat.
- **Document insights immediately**, not at the end.
- **Code smells**: report inline, running count, pause at 10.
- **Prefer clean-slate rewrites over workarounds** when the workaround
  looks like a patch on a patch.
- **Refuse "software sucks" as a stopping point.**
