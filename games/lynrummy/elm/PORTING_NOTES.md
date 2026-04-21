# Porting notes — process insights

A live record of meta-learning extracted while porting LynRummy
game-state + legal-move logic from `angry-cat/src/lyn_rummy/`
(TypeScript, canonical) to Elm. Each entry is tagged so revisions
are visible: `[initial]` (intuition before evidence), `[validated]`
(confirmed by experience), `[revised]` (replaced an earlier take).

The point of writing these now, before the port itself proves
them out, is that future revisions will be diff-legible — so
"this is what we believed; this is what we learned" becomes a
real artifact, not a vibes-summary.

Session: 2026-04-13. Knobs: durability=10, learning=10, efficiency=1.

---

## 1. Discovery-before-porting `[initial]`

Don't start writing target-language code before mapping the
territory. Read source for unclear bits, surprises, and
questions — not for "what to type first." The map produces a
shared mental model that the port can then incrementally fill in.

## 2. Survey-first vs probe-first `[initial]`

With a real-time human collaborator, prefer **surface-first /
top-down** (read entry-points and let foundations be unpacked on
demand). The collaborator can rescue you from incomplete-
foundation confusion. Without a collaborator (async work), the
balance tips toward foundation-first, because confusion is
unrecoverable in real time.

## 3. Within-layer: foundations first if cheap, surface first if expensive `[initial]`

Even after picking top-down, within a layer there's a sub-choice:
read all the foundations (small files in `core/`) before going up,
or skip ahead. Heuristic: if the foundation files are small
(hundreds of lines or fewer), read them — cheap insurance. If
huge (thousands), defer and let surface usage tell you which
parts matter for the port scope.

## 4. Source-language emphasis carries meaning `[initial]`

Loud comments in the source ("THIS IS THE MOST IMPORTANT FUNCTION
OF THE GAME") are load-bearing. Preserve the emphasis verbatim in
the port — flattening to a calm docstring strips information the
original author deliberately encoded.

## 5. Derived state vs stored state is a port-time checkpoint `[initial]`

When the source stores something computable from other state
(e.g., `Card.color` is a stored field but a pure function of
`suit`), decide deliberately whether to mirror the storage or
derive on demand. Default lean for Elm: derive. Don't carry
state that's a pure function of other state — it's a class of
bug source ("the two got out of sync") that idiomatic Elm rejects
by construction.

## 6. Diff-based protocols are portability gold `[initial]`

When the source defines moves as `(before, remove, add)` rather
than `(before, after)`, that shape is interop-friendly — the
receiver derives the result and can't be lied to. Mirror this
shape exactly across language ports.

## 7. Stage-based early-exit validators map to `Result.andThen` `[initial]`

Imperative cascades of "check thing 1; if fail return; check
thing 2; ..." port naturally to Elm's monadic chains
(`Result.andThen`). Make this idiom translation explicit during
the port — it's not just style, it's a structural pivot.

## 8. Defer protocol-shape validators `[initial]`

Validators that check JSON shape (field types, ranges) aren't
intrinsic to the game domain — they're plumbing at the system
boundary. Read them last. They only make sense once the domain
they're validating is mapped.

## 9. "Plain loops, no closures" comments are portability hints `[initial]`

When the source author flags portability intent in a comment,
trust it. The source is already biased toward easy translation
and probably avoids language-specific cleverness. Lower porting
cost expected.

## 10. Capture insights live, not at the end `[initial]`

Write process notes during the discovery, not as a wrap-up
exercise. Diffs over time become the meta-learning artifact.
The insight you later revise is more valuable than the one you
never wrote down.

## 11. String-based equality may hide field exclusions `[initial]`

When the source uses `a.str() === b.str()` as an equality
shortcut, look hard at what `str()` actually serializes. Hidden
field exclusions (e.g., `origin_deck` not appearing in the
string) become silent semantic differences in the equality
relation. Ports should make the comparison explicit and
deliberately decide which fields participate.

Concrete example here: `CardStack.equals` ignores `origin_deck`
because `str()` doesn't include it. Whether that's intended or a
bug needs Steve's call before the port mirrors or fixes it.

## 12. UI constants in domain code are a port-time decision `[initial]`

When the source has presentation constants (e.g., `CARD_WIDTH`)
inside a domain/rules module, decide deliberately whether to
mirror the coupling or sever it. Mirror = parity, easier to
diff against the source. Sever = cleaner Elm, separates
concerns properly, but introduces a port-only divergence.
Document the call either way.

## 13. Recency-aging state is UI plumbing, not rule logic `[initial]`

State that "ages" across turn boundaries (e.g.,
`FRESHLY_PLAYED` → `FIRMLY_ON_BOARD`) usually exists for visual
highlight purposes, not for rules. The referee does not consult
these fields. The port can defer or implement minimally without
losing rule fidelity. Just don't lose track of which fields are
domain-essential vs UI-supporting.

## 15. Geometry is orthogonal — Steve's theory `[validated with nuance, Steve]`

> "Geometry is basically orthogonal to everything else."
> — Steve, 2026-04-13

**Verdict from the sketch (same session):** Mostly true, with a
load-bearing nuance.

- **Geometry _computations_ are cleanly orthogonal.** The
  domain types use only an opaque `BoardBounds` slot and a
  `validateBoardGeometry` function-shaped slot. Nothing in the
  rules-layer types depends on geometry internals.
- **Geometry _data_ is interwoven.** Every `CardStack` carries a
  `BoardLocation` field. So the domain shape includes positions,
  and you can't actually separate "pure rules" from "stacks
  with positions" — there's no position-free Stack type in the
  source.

Practical implication for the port: we can defer **reading**
`board_geometry.ts` until very late, but we can't defer
**including** `BoardLocation` in the domain types. The
boundary lives at the function signatures, not at the data shape.

Meta-insight that survives: **a human collaborator with domain
knowledge can predict orthogonality and let the porter skip
ahead.** Without that human, the porter would conservatively
read every support module. This is concrete evidence for insight
#2 (top-down works better with a real-time human).

## 16. Split-durability within a single repo `[initial, Steve, 2026-04-14]`

Decision for LynRummy work: `elm-lynrummy/` keeps UI/gesture code
at spike-grade (durability=2, evolve freely via experiment), AND
hosts the durable model port (durability=10) under a separate
sub-tree. One repo, two knob settings, honored by directory.

- **UI / gesture code** (existing): `src/Main.elm`, `src/Layout.elm`,
  `src/Style.elm`, `src/Drag.elm`, `src/Card.elm`, `src/Study.elm`,
  `src/Gesture/` — spike-grade; change freely.
- **Model port** (new): `src/LynRummy/` — durable; careful changes,
  tests, own commits.

**How to apply:**
- Never bundle a model-code change with a UI-spike commit.
- UI experiments that would regress the model (even transiently)
  are blocked; find another path.
- When unsure which bucket a change falls into, ask.

Portable meta-insight: mixed-durability repos work if the
boundary is **mechanical** (different directories) rather than
**cultural** (same directory, different expectations). Cultural
boundaries erode; directory boundaries don't.

## 17. Cost of confusion is recurring; bounded implementation cost is one-time `[initial, Steve, 2026-04-14]`

When choosing between a one-shot implementation effort and
accepting recurring ambiguity, weigh them on the right time axis.

Concrete example: porting mulberry32 faithfully costs ~30–50
lines of careful Elm (no native unsigned ints, so bit-masking +
`Math.imul` emulation). That cost is paid *once*. The alternative
— letting Elm have its own seed lineage — saves the 30-50 lines
but pays a recurring cost in "confusion-about-whether-the-two-
implementations-match" every time a test's card ordering differs.

Steve's framing (2026-04-14): "30-50 lines of careful Elm is
pretty inexpensive compared to the alternative costs of
confusion."

**How to apply:** when a bounded one-time implementation cost
unlocks a recurring clarity benefit (cross-language traces,
parallel test scenarios, diff-against-source sanity checks),
pay the implementation cost. Confusion compounds; careful code
doesn't.

## 14. Defensive validation at multiple layers may be evolutionary `[initial]`

When you see the same invariant enforced in two places (e.g.,
`maybe_merge` rejects problematic stacks at construction AND
`check_semantics` rejects them at the referee level), suspect
evolutionary growth — one layer probably predates the other.
The port can usually consolidate, but the consolidation should
be a deliberate decision, not an accidental drop.

## 19. Shared fixtures are cross-language ground truth `[initial, Steve, 2026-04-14]`

For deterministic functions, the strongest equivalence signal
between two language implementations is **testing against the
same concrete input-output data on both sides**. Not "tests pass
in A" and "tests pass in B" — *the same fixture values flow
through both tests and must match byte-for-byte*.

Concrete instance (this session): mulberry32 with seed=42
produces a specific sequence of 8 floats. Run the TS once,
capture the values, paste them into the Elm test as expected
outputs. If Elm's port is correct, the test passes; if any
bitwise subtlety diverges, the test fails with precise
diagnostics (float X doesn't match).

**Why this is stronger than behavioral tests:**

  - Catches subtle implementation bugs (bitwise wraparound,
    precision, rounding) that property-shape tests miss.
  - Converts "did my port pass a behavioral test" into "did my
    port produce the exact same bits." Precise oracle.
  - The fixtures themselves are durable artifacts. They outlive
    the port and catch regressions in either language.

**Applies where:**

  - Anything deterministic with a seedable or enumerable input
    space: PRNGs, hash functions, parsers, formatters, pure
    transformers.
  - JSON encoders (input object → exact string output).
  - Round-trip tests across a language boundary.

**Doesn't apply where:**

  - Stochastic functions (no seed). Test properties instead.
  - Implementation-dependent outputs (thread scheduling, etc).
  - Large output spaces where hardcoding is impractical — use
    a checksum or summary statistic instead.

Steve's framing: "One of the most effective ways to be sure
that two programming languages are in sync … is to make sure
their tests are operating on the same data." This technique
deserves a name; "shared fixture equivalence" or "golden trace
testing" both work.

## 18. Source-test trust is a two-sided fallibility `[initial, Steve, 2026-04-14]`

When the porter wrote the source tests in a prior session (as
is the case here — Claude authored most of
`angry-cat/src/lyn_rummy/**/*_test.ts`), trust calibration needs
*both* perspectives:

- **Steve's angle (speed):** "Claude wrote these carefully, so
  we can lean on them — port quickly, save time."
- **Claude's angle (caution):** "Past-Claude's blind spots are
  preserved in them. Shared-mind coverage gaps go undetected
  without independent re-examination."

Both are valid. Neither is sufficient. Working rule: **trust
accelerated by provenance, caution preserved by shared-mind
fallibility.** Use source tests as a strong starting point,
but scrutinize them during port — add cases, question framing,
don't treat passing as proof.

Portable insight: when a collaborator is both author and
consumer of an artifact across time, trust-calibration is
two-sided. Each party's natural default is wrong in opposite
directions.

---

## Open questions for next time

- After porting referee + foundations, does the mapping actually
  stay 1:1 with TS, or does Elm's type system want a
  reorganization? (Will tell us whether to extract a "tasteful
  re-model during port" insight.)
- Does the diff-based move format survive Elm record syntax
  comfortably, or does the Elm version want named accessors
  more than positional spreading?
- **`CardStack.equals` deck-blindness**: intentional or bug?
  Affects what the referee considers the "same" stack to remove.
- **CARD_WIDTH placement**: keep in core/ for parity, or move
  to a UI module in the Elm port?
- **Belt-and-suspenders semantic checks**: consolidate, or
  preserve both layers?

---

## Tacit insights (captured 2026-04-14 during postmortem prep)

Insights that surfaced only when I sat and reflected at the end
— didn't fit the flow of writing during the work. Less polished
than #1-19; some may fold into those after more thought.

### T1. Reading source tests teaches faster than reading source code.

When I read `card_test.ts`, the specification was *concrete*:
"these inputs, these outputs, this expectation." When I read
`card.ts` first, I had to *interpret* what behavior mattered.
The tests are an executable spec; the source is an artifact
that implements it. For a port, reading tests before source
might be the better order. We didn't try that, but next port
worth an experiment.

### T2. Elm's compiler strictness is a porting *asset*, not an obstacle.

The type-annotation error (`[] : List Int`), the pattern-match
completeness errors on new constructors, the import rigor — all
of these caught port-time bugs that TS would have let through.
The target language's strictness is a free correctness audit.
Tight target > loose target for porting.

### T3. "Cheap to defer, cheaper to unblock later" held up.

I deferred JSON, protocol\_validation, mulberry32 (initially),
`buildFullDoubleDeck` (initially), board\_geometry (initially),
`pullFromDeck`, `clone`. Most deferrals either stayed deferred
(protocol, clone — correct) or got unblocked in minutes when
the need arose (mulberry, geometry). The cost of deferral was
low and the cost of premature porting would have been higher.
Default: defer aggressively.

### T4. Commit messages doubled as postmortem scaffolding.

When I sat to write POSTMORTEM\_PREP, I didn't have to
reconstruct the arc — the MILESTONE commit messages already
narrated it. "Foundation + referee" / "geometry + mulberry +
shared-fixture testing" are the section headings of the
postmortem, essentially. Narrative-shaped commit messages during
the port paid off as retrospective prep after.

### T5. "I don't know" findings are more valuable than "I know" findings during discovery.

The most durable artifacts from the port are the *open*
questions: `CardStack.equals` deck-blindness, CARD\_WIDTH
placement, belt-and-suspenders checks. Each is a question I
couldn't resolve alone. By contrast, the "I know this is right"
passes (most of the type translations) are invisible — they
just work. Confidence is cheap; calibrated uncertainty is
expensive and valuable.

### T6. The knobs setting worked as a *communication device*, not just a priority knob.

Durability=10 didn't just tell me to be careful; it told Steve
that he could interrupt me for a shortcut with less resistance
from me. The knob encoded a pre-negotiated permission structure.
Future port: set knobs explicitly as the opening move; they act
as shared guardrails, not just preferences.

### T7. Reversibility is the right filter for autonomous decisions.

I took dozens of port-time calls without asking (field
placement, constructor naming, default values, test scope).
The unifying filter was "is this easy to undo?" — not "is this
important?" or "am I sure?". Reversibility maps directly to
the cost of being wrong. Irreversible or expensive-to-reverse
decisions should escalate; everything else should decide fast.

### T8. Layering is a port-time decision, not a source property.

TS had four core files. I could have collapsed to one module or
expanded to ten. Mirroring TS was a *choice* I made for
source-diff legibility, not a requirement. For future ports: be
conscious that the source's layering is a suggestion. Look for
reasons to diverge (Elm's natural boundaries) before defaulting
to mirroring.

### T9. Language-pair transformations are a reusable pattern library.

TS→Elm has a specific vocabulary: classes → modules, stored
derived state → derived functions, exceptions → Maybe/Result,
numeric enums → sum types, Math.imul → emulation, optional
fields → empty list. Each transformation is a *decision I made
the same way every time*. That's a pattern library for this
language pair. Next Python→Rust (or whatever) port should start
by listing the pair-specific transformations explicitly before
writing code.

### T10. Pair-work artifacts are different from solo-work artifacts.

MILESTONE commits have `Co-Authored-By`. PORTING\_NOTES tags
insights with `[Steve]`. The artifacts record not just what
was done but *who contributed what idea*. This wouldn't emerge
from a solo port. The provenance tags make it easier to trace
which decisions were pushed forward by which party — useful
when revisiting later.

### T11. Read the source twice, always.

I read referee.ts once for the survey pass, once for the port
pass. The second read caught things the first missed —
particularly the "compute board\_after from diff rather than
trusting claimed result" invariant. Doubling the reads is
cheap; the second pass is at full comprehension rather than
navigation. Budget for it.

### T12. Exclusions are as valuable as inclusions.

"We are NOT porting AI logic; we are NOT porting UI; we are
deferring JSON." Each exclusion shaped the port more than any
single inclusion did. The scope document is not just a list of
what's in; it's equally a list of what's *out*, and the
reasoning for both. Future port: write the out-scope explicitly
at the start.

### T13. Autonomy with clear criteria was cheap; I feared it being expensive.

Going into the "continue autonomously" phases I expected to
either over-consult or go off the rails. Neither happened.
With durability=10 + clear scope + reversibility filter, the
autonomous stretches were fast AND careful. The agent-workflow
literature often frames autonomy as risky; with these
guardrails it was the efficient mode.

### T14. The postmortem is easier to write if you write it during the work.

POSTMORTEM\_PREP was 10 minutes to produce because the evidence
already existed in commits, PORTING\_NOTES, and memory entries.
If the artifacts hadn't been there, this would have been an
hour of reconstruction. Retrospective prep is accrued during
the work, not assembled after.

---

---

## Stress-test of insights 1-19 (2026-04-14)

For each existing insight, I tried to construct a case where
following it would give bad advice. Verdict of each:

- **survives** = insight holds broadly as written
- **qualified** = insight holds with an added condition
- **context** = insight is context-dependent; frame matters

| #  | Insight (short)                                | Verdict    | Failure mode / qualifier                                                                 |
| -- | ---------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------- |
| 1  | Discovery-before-porting                       | qualified  | For trivial source (~50 LOC, well-known semantics), discovery is overhead; skip.         |
| 2  | Survey-first vs probe-first                    | context    | Assumes human collaborator is real-time responsive. Solo/async inverts the balance.      |
| 3  | Foundations-first if cheap, else surface-first | qualified  | "Cheap" = complexity × lines, not just lines. Dense small files (PRNG) violate naive measure. |
| 4  | Source-language emphasis carries meaning       | qualified  | Caveat: sloppy authors leave emphatic comments that mislead. Default to preserve; override with evidence. |
| 5  | Derived state vs stored state                  | qualified  | Default lean: derive. But for perf-critical code, stored + memoization may win. Profile first. |
| 6  | Diff-based protocols are portability gold      | context    | Only applies when source already uses diff shape. Adopting a diff where source uses snapshot is a bigger change. |
| 7  | Stage validators → `Result.andThen`            | context    | Target-language idiom matters. Elm → andThen; Go → early returns; Rust → `?`. The *shape* generalizes; the syntax doesn't. |
| 8  | Defer protocol-shape validators                | qualified  | Defer for *domain* ports. If the port's GOAL is protocol interop, port validators early. |
| 9  | "Plain loops, no closures" as portability hint | qualified  | Treat as hint; verify by scanning for closures before trusting. Authors sometimes lie (including to themselves). |
| 10 | Capture insights live, not at the end          | survives   | Batching at work-boundaries also works; only "at the end" fails consistently.            |
| 11 | String-based equality may hide field exclusions | qualified  | Sometimes the string IS the equality-by-design (normalization). Look at intent before calling it a bug. |
| 12 | UI constants in domain = port-time decision    | survives   | Already framed as "decide deliberately" — no prescription to stress-test.                |
| 13 | Recency-aging state is UI plumbing             | qualified  | Verify: does the rules layer consult these fields? If yes (e.g., "freshly played wins ties"), they're rules. |
| 14 | Defensive validation at multiple layers        | qualified  | Sometimes belt-and-suspenders is intentional defense-in-depth. Investigate history before consolidating. |
| 15 | Geometry is orthogonal (Steve's theory)        | context    | Domain-dependent. Works for card games; fails for spatial games (Tetris) where geometry IS rules. Already has nuance annotation. |
| 16 | Split-durability within one repo               | qualified  | Works when boundary is mechanical (directory). Cultural-only boundaries erode. Also: team norms may forbid.  |
| 17 | Cost of confusion > bounded impl cost          | qualified  | Only when impl cost is truly bounded. Subtle implementations (bitwise PRNG) can balloon; scope before deciding. |
| 18 | Source-test trust is two-sided fallibility     | context    | Specific to the case where porter = author. If they're different parties, normal trust calibration applies. |
| 19 | Shared fixtures = cross-language ground truth  | qualified  | Needs deterministic function + compatible numeric representation. Platform-dependent or stochastic functions need sampled statistics instead. |

**Patterns visible in the stress-test:**

- **None of the 19 were falsified.** They all survive in some form.
- **Most need a qualifier (12 of 19)**, usually a frontier condition: "applies when the source has X" / "fails when you're solo" / "only for deterministic inputs."
- **Three are genuinely context-dependent** (#2, #6, #15, #18) — they describe one of several valid approaches, not a universal rule.
- **The insights most likely to be "laws" are meta-process ones** (#10 live capture, #12 decide deliberately). The insights most likely to need context are the *prescriptions* (#7 andThen, #15 geometry).
- **Failure modes cluster in a few families:** (a) trivial source doesn't need the framework, (b) target language idiom matters, (c) author intent can invalidate default reads. Future ports should check these three families first.

---

## Decisions taken

- **2026-04-14**: port mulberry32 faithfully for cross-language
  test reproducibility (insight #17). Cost ~30-50 lines of careful
  Elm; unlocks trace-equivalence testing.
- **2026-04-14**: durable port lives at `elm-lynrummy/src/LynRummy/`;
  UI/gesture spikes stay at `elm-lynrummy/src/`. Split-durability
  within a single repo (insight #16).
- **2026-04-14**: module layout mirrors TS 1:1 — `LynRummy.Card`,
  `LynRummy.CardStack`, `LynRummy.StackType`, `LynRummy.Referee`,
  `LynRummy.BoardGeometry` (later).
