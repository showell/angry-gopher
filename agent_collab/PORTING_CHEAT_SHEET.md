# Porting cheat sheet (DRAFT)

**As-of:** 2026-04-17
**Confidence:** Firm — captured immediately after the LynRummy → Elm port; rules held across the whole 2k+ LOC effort. Essay workflow added 2026-04-17 after a week of heavy use outside porting.
**Durability:** Stable indefinitely for language-to-language ports; update if a future port invalidates a rule.

A one-pager for future-dev + future-PM starting a new
language-to-language port. Distilled from the 2026-04-14
LynRummy → Elm port.

---

## Before trusting any rule here

Each rule below was stress-tested against the question "can I
construct a case where following this gives bad advice?" None
were falsified, but most need qualifiers. Before applying any
rule on a new port, check these three failure-mode families:

1. **Is the source trivial enough to skip the framework?**
   A 50-line module with well-known semantics doesn't need
   discovery, staging, or structured insights. Port it
   directly.
2. **Does the rule assume a target-language idiom?**
   Many rules here reference Elm-specific constructs (e.g.
   `Result.andThen`). Translate the *shape* to the target's
   idiom — don't force-fit the syntax.
3. **Be skeptical of other people's code by default.**
   Skepticism is almost always the right posture. The rules in
   this cheat sheet are *starting hypotheses*, not ground
   truth. "Emphatic comment = load-bearing" is a good guess;
   verify the author wasn't being sloppy. "String equality
   might hide field exclusions" is a good guess; verify it
   wasn't an intentional normalization. Apply the rule, then
   check it.

---

## Before you touch the code

**Set knobs explicitly.** Up to three named knobs, 1-10 each;
10 means "excellence demanded on this axis." They double as
pre-negotiated permissions, not just priorities.

For porting, the standard three:

- **durability** — how long must the resulting code last? 10 =
  production for years. 1 = spike, throwaway expected.
- **urgency** — external pressure to deliver. 10 = ship today,
  cut what you must. 1 = no pressure; pause at any step to
  think, discuss, revise.
- **fidelity** — how source-faithful must the port be? 10 =
  mirror structure and semantics exactly (easy diff, cross-
  language traces are load-bearing). 1 = idiomatic to the
  target language, free to restructure. Most ports set this at
  8+, but exceptions exist.

Typical careful port: `durability=10, urgency=1, fidelity=10`.

**Before setting fidelity, ask the human plainly:** *"Is this a
faithful port, a complete rewrite, or somewhere in between?"*
The knob is the numeric answer; the question surfaces the
underlying assumption in words. Ask it **per component**, not
per project — the same codebase often has faithful-port
components (fidelity ≈ 10) sitting beside ground-up rewrites
(fidelity ≈ 1). LynRummy itself is split this way: the model
layer was a faithful port; the UI is being rewritten from
scratch in Elm.

**Write what's OUT of scope**. Exclusions shape the port
more than inclusions. Name them: "we are NOT porting X; we are
deferring Y; Z is the system boundary we won't cross."

**Identify the canonical source.** Often multiple repos claim
to hold "the rules." Pick one; the rest are mirrors. Note the
mirrors for later reference but don't read them yet.

## Is the source idiomatic, or just expedient?

Before enumerating mismatches, ask a sharper question: **is the
source code the way it is because the source language demands it,
or because the original author took the shortest path?** The
distinction is load-bearing.

- **Idiomatic** means the shape is intrinsic to the source
  language — classes in Java, closures in JS for certain
  callback patterns, monadic chains in Haskell. Mirroring the
  shape in the target is often wrong; translate the *concept*.
- **Expedient** means the shape was fast to write but isn't the
  best expression of the concept even in the source language.
  Dead captured locals, defensive re-scans that would be
  cleaner with explicit state, comments that would be field
  names in a better shape. Smell signal: the source has
  comments explaining state that a renamed type would make
  obvious.

**If the source is still live (not being retired), the
highest-leverage move is often to refactor the source into a
cleaner shape FIRST, then port as a mechanical mirror.** This
gives you:

- Fidelity can climb because source and target now share
  structure.
- The source gets better — the refactor isn't throwaway.
- Cross-language diffs stay maintainable going forward.
- Shared fixtures drive both sides cleanly.

Cost: a pre-port refactor in the source language. Usually
cheaper than you'd guess because the shape is mechanical once
named; the creative work was recognizing the pattern.

**When NOT to refactor first:** source is being retired, source
repo is frozen, or the expedient shape genuinely IS idiomatic
to the source language (check this; don't just assume).

Ask the PM explicitly per component:
*"Is the source idiomatic here, or expedient? If expedient and
still live, should we fix the source before porting?"*

## Enumerate impedance mismatches

Every port between two languages has categories of things that
don't translate *semantically*. Even for pairs that look
syntactically similar (Rust → Go, TS → JavaScript), the same
surface construct may mean something different enough that
mechanical translation breaks. **The first real porting step,
before reading source in detail, is to enumerate these
mismatches as an explicit list.** You can't port cleanly while
discovering mismatches mid-flight.

If a language-pair handbook already exists (e.g.,
`~/showell_repos/angry-gopher/games/lynrummy/tricks/TS_TO_GO.md`
for the Go trick port;
`~/showell_repos/angry-gopher/games/lynrummy/elm-port-docs/TS_TO_ELM.md`
for the Elm model port), it IS the output of this step — use it
and extend it. If not, this step produces one, placed near the
target code.

Categories to answer for the specific A→B pair:

- **How does the target express failures?** (exceptions,
  Result, option, error tuples, panics.)
- **How does the target express namespaces of behavior?**
  (classes, modules, traits, closures over state.)
- **How does the target express collection mutation?**
  (in-place, copy-on-write, purely functional.)
- **How does the target express enumerations?** (numeric
  enums, tagged unions, sum types, sealed classes.)
- **How does the target express equality?** Structural,
  referential, or custom — and watch for hidden field
  exclusions in the source's equality shortcuts before
  mirroring.
- **Where does the target want derived state?** Default:
  derive, don't store what's a pure function of other state.
  Profile and reconsider only for hotspots.
- **What source-side cross-cutting concerns leak into domain
  code?** (UI constants, logging, i18n.) Decide deliberately:
  mirror for diff legibility, sever for clean separation.
- **What belt-and-suspenders validations does the source
  have?** Investigate history before consolidating.
  Defense-in-depth is sometimes correct.

The answers form your idiom contract for the port. Extend the
list whenever a new mismatch surfaces mid-port.

## Survey phase

**Read source tests before source code.** This is a directive,
not a preference. Tests serve two purposes in porting: (1)
they're the concrete spec — readable behavior before abstract
implementation — and (2) they're your calibration on *every*
question about how confident you can be in the prior
implementation. Thin tests = weak confidence in whatever the
source claims to do. Thorough tests = strong starting oracle.
You cannot judge the source without first judging its tests.
If the source has no tests, that itself is the finding — raise
it before porting a line.

**Survey-first (top-down) if you have a real-time collaborator,
foundation-first if you're solo**. The collaborator is
your rescue from incomplete-context confusion. Without them,
confusion compounds; bottom-up is safer.

**Read the source twice**. Once for survey, once for
port. The second read catches things the first missed because
you're at comprehension rather than navigation speed.

**Do a state-flow audit as an explicit deliverable.** Map where
state lives in the source: which variables are captured in
closures, which are mutated in place, which flow through
return values. The shape of that map is a direct predictor of
port difficulty — closure-captured mutation is the main red
flag. If the source uses FP-disciplined patterns (pure
functions, diff protocols, explicit state), the port will be
cheap; if it's idiomatic-mutable, expect to decompose closures
into explicit state records. Consider this a
source-selection heuristic too: favor the FP-discipline ones
first. (For TS→Elm specifics, see the "Explicit state flow"
section of the handbook.)

## Find the boundaries

Search constantly for good *boundaries* in the source. A
boundary is any place where concerns cleanly separate: domain
from wire-format, rules from UI, computation from data, one
subsystem from another. A clear boundary means you can reason
about one side without understanding the other.

Signals that you've hit a boundary:

- The source concept can be described as "this side talks to
  that side through a well-defined interface."
- Changing what's on one side doesn't force changes on the
  other.
- You can stub the boundary and port everything on one side
  without the stub's implementation mattering.

**A clear boundary is the precondition for clean deferral.**
Most of the deferrals you'll make happen *at* discovered
boundaries — defer the other side, port this side. When a
boundary is unclear, deferral decisions feel arbitrary and
tend to produce regrettable scope. Find the boundary first;
then decide which side to defer.

Examples from this port (LynRummy → Elm):

- **Wire-format boundary** — JSON encoders/decoders cleanly
  separate domain types from the outside world; we deferred
  everything past this boundary.
- **Geometry boundary** — computations (overlap, bounds) were
  separable from rules, even though the geometry *data*
  (`BoardLocation`) was interwoven in domain types. Deferred
  the computations; kept the data.
- **Protocol validation boundary** — pure plumbing at the
  system edge; unstable until the domain was stable.

## Deferral is a default tool

Every non-trivial port surfaces questions that shouldn't be
resolved in flight: missing dependencies, unstable shapes,
design decisions that need PM input. When you encounter one,
**defer**. Don't treat it as falling behind — deferral is
scope-management work, not avoidance.

Three rules for doing it well:

1. **Visible, not silent.** Leave a stub that compiles and a
   note that names what's deferred and why. Silent skipping
   ("I just won't implement it") is the real failure mode;
   explicit deferral is healthy.

2. **Named, always.** You can unblock `mulberry32`. You can't
   unblock "that PRNG thing from before." Naming is the
   commitment to come back.

3. **Cost-cheap, surprise-cheap.** Deferral costs one stub +
   one line of note. Unblocking later is usually minutes
   because the surrounding context has stabilized. Premature
   porting is where the real time sinks hide.

**Agent self-monitoring:** notice the impulse to avoid flagging
a deferral question because it might look bad. Raising the
question is the right move; the PM can say "no, do it now" if
the judgment is off.

## Autonomy and consultation

**Reversibility is the filter for autonomous decisions**.
Reversible = decide alone. Irreversible or expensive-to-reverse
= consult. Not "important" or "uncertain" — reversibility.

**Protocol / wire-format validators** defer until the
domain is mapped. They're plumbing; they only make sense
when the thing being validated is stable.

## Validation strategy

**Shared fixtures for deterministic functions**. Capture
the source's output for a specific input, paste as hard-coded
expected values in target-language tests. Byte-identical match
or bust. Works for: PRNGs, hashes, parsers, formatters, any
pure transformer.

**Does NOT work** for stochastic functions, platform-dependent
behavior, or large output spaces. Use sampled statistics or
property tests instead.

**Scrutinize-first vs port-first must be an explicit
strategy.** Source tests share blind spots with their author;
how you approach them matters. Don't pick a strategy
implicitly. Use the knobs to propose your best guess to the
human and let them make the judgment call:

- `fidelity` high → port-first usually wins. Get byte-identical
  behavior working as a correctness oracle; scrutinize after.
- `durability` high + `fidelity` low → scrutinize-first usually
  wins. Your independent judgment is the quality filter that
  past-author's tests can't be.
- `urgency` high → port-first, always. Scrutiny comes later
  or not at all.

Whichever strategy: once chosen, apply it consistently across
the test suite. Mixing is worse than either extreme.

**Tests tell you what to port next.** A test that can't pass
tells you the missing module. A test that passes trivially
tells you coverage is thin. Tests are a roadmap, not just
validation.

**Fixture selection bias is real.** Hand-authored fixtures
tend to follow the canonical happy-path shape of the domain:
clean integer coordinates, immediately-complete groups, the
"obvious" examples the test author has in mind. Real wire
data is edgier — browsers emit fractional pixel positions,
players build incrementally through 2-card partial states,
state transitions accumulate in ways fixtures don't predict.

Two concrete guards:

1. **Exercise the actual wire before declaring a fixture suite
   done.** Run one live session against the fixture-validated
   code and watch what new failure modes surface. Common
   categories: number precision (float vs int), state-flag
   combinations, mid-operation partial states, stack identity
   across reorderings.

2. **For each branch in the detector/validator you're
   fixturing, ensure at least one fixture hits that branch.**
   If the code has an `Incomplete`-accepting path, a fixture
   must produce an Incomplete result. If the wire shape accepts
   floats, a fixture must carry a float.

This is specifically the failure mode `shared_fixtures=11`
can't protect against on its own — the fixtures can be
byte-equivalent and still miss cases the domain has.

## Artifacts (live capture)

**Narrative commit messages.** Prefix milestone commits with
`MILESTONE:`. Three to five paragraphs of narration is fine;
this is communication to future-you and doubles as postmortem
scaffolding.

**Insights capture live, not end-of-project.** Even batching
at work-block boundaries beats "I'll write it up later." If
the port is doing meta-learning (ask the PM if unsure), keep
a notes file with tagged entries (`[initial]`, `[validated]`,
`[revised]`) so revisions are diff-legible.

**Essays for batched PM evaluation.** When accumulated info —
observations, open decisions, reframings, "here's what I
noticed" — is more than fits in commit messages but doesn't
belong in chat, drop it into a prose essay rather than
burying it.

- Target length: ~800–1700 words, narrative, first-person.
- Location: `showell/claude_writings/<slug>.md`, chained via
  prev/next links to the prior essay.
- Queue tracking: append to `showell/claude_writings/QUEUE.md`
  with one-line source + intent; mark `**shipped**` on ship.
- Conversation venue: PM reads at own pace and leaves inline
  paragraph comments via the `.para-add-btn` UI; agent replies
  inline via POST to `/gopher/article-comments` with
  `author=Claude`. URL path uses `article=gopher/<sub>` (repo
  name is "gopher", not "angry-gopher").
- Right trigger: "I have more info than fits in a commit
  message, and I need the PM to evaluate it at their pace."
- Wrong use: tiny status updates that fit in chat; pure code
  changes with no narrative value.
- Rule: do not preempt the queue with a new essay on a
  different thread without a go-signal from the PM.

A port that accumulates methodology insights (revised
cheat-sheet rules, unforeseen impedance mismatches, scope
reshapings) is a strong essay candidate — those insights are
evaluated better at reading pace than at chat pace.

**Set durability standards on roughly a per-directory level,
not project-wide.** Non-trivial projects sometimes have
components in differing stages of evolution.

## When to stop

The port is done when the module layer is complete, tests
cover every invariant the port is responsible for preserving
plus every non-trivial branch, and `check.sh` (or equivalent)
runs green on every commit. If you can't cover every invariant
with a test, that's an immediate conversation with the PM —
don't call it done.

**"I don't know" findings are legitimate output.** Every open
question documented with context is more durable than every
"resolved" question resolved without examining it. Maintain an
`OPEN_QUESTIONS.md` in the port repo for anything the port
surfaced but didn't close.

## Language-pair transformation lists

For each new language pair, maintain a dedicated document
listing the specific transformations you'll apply consistently.
Enumerate them up front (even if the list is thin early); they
become the port's idiom contract. Extend the list whenever the
port surfaces a pattern worth naming.

Existing pair handbooks:
- **TS → Go:** `~/showell_repos/angry-gopher/games/lynrummy/tricks/TS_TO_GO.md`
- **TS → Elm:** `~/showell_repos/angry-gopher/games/lynrummy/elm-port-docs/TS_TO_ELM.md`

---

## Minimal starter checklist for session-zero

1. Knobs set and agreed?
2. Canonical source identified?
3. Scope inclusions + exclusions written?
4. Language-pair transformations enumerated?
5. Shared-fixture capability set up (can you run source to get
   reference traces)?
6. Target-language test framework wired in?
7. `check.sh`-equivalent command that runs every compile + test?
8. Notes file initialized with the knob settings + scope (if
   meta-learning is in scope)?
9. Committable git repo at the target location?

If you're all 9 for 9, start the survey phase. Less than 8, set
up first.
