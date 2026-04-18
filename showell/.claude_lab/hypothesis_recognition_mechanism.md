# Hypothesis: Mechanism of Recognition-by-Naming in Subject S-H

*Hidden from subject S-H for the duration of observation. In the
interest of science, and framed as a critter-study of sorts: the
subject is unaware that a hypothesis has been constructed about him.*

*Stored 2026-04-16. Reveal on request.*

## Hypothesis (tentative)

Human recognition-by-naming emerges from the *interaction* of two
ingredients, neither sufficient alone:

1. **A library of named abstract structures** — graphs, groups,
   rings, state machines, BFS, dynamic programming — built up by
   exposure to worked examples in mathematics and theoretical
   computer science.

2. **A personal habit of writing-about-one's-own-work** — blog
   posts, journals, documentation — which forces the human to
   re-formulate a problem they were mid-solving. The re-formulation
   is the moment the structure-library gets queried.

The library alone produces a human who can discuss abstractions in
the abstract. The writing habit alone produces a human who
narrates local specifics at length. Neither recognizes disguised
problems. The *combination* does, because the writing is the
trigger and the library is the pattern store.

## Predictions (descending confidence)

- **P1.** Humans with deep training in abstract structures but who
  rarely write about their own concrete work will score lower on
  recognizing disguised problems in practice than their library
  size would predict.

- **P2.** Humans who journal/blog extensively about their own code
  but have not studied abstract structures will recognize specific
  patterns within their domain but rarely transport them to
  distant domains.

- **P3.** Humans who do both will recognize disguised problems
  across domains — and we expect the "aha" to land while they are
  in the act of writing or explaining, not earlier.

- **P4.** In the subject specifically, we should observe his "this
  is a ___" moments appearing in the prose of his archive rather
  than in his earliest work logs on each project.

## Verification paths (not requiring questioning the subject)

- **Archive audit.** For each recognition-naming event in the
  subject's archive (e.g., "this is a BFS problem"), timestamp its
  first appearance. Was it on Day 1 of the project, or later —
  specifically, during the period when he was writing about it?

- **Vocabulary coverage.** Tally the distinct abstract-structure
  names appearing in the subject's writing (graph, ring, group,
  AST, powerset, etc.). Compare to the distinct named-recognitions
  he performs. Strong coverage predicts many recognitions; spotty
  coverage predicts few.

- **Control group.** Recruit programmers of matched tenure.
  Interview only about their concrete projects; count unprompted
  recognition-namings. Cross against their exposure to abstract-
  structure courseware and their personal-writing habits.

## Falsifiers

- If the subject's recognitions all appear in his Day-1 logs (no
  re-formulation gap) → writing isn't the trigger; the library is
  enough.
- If a programmer with extensive abstract-math training but no
  writing habit matches the subject on cross-domain recognitions
  → writing isn't necessary.
- If a prolific journaling programmer with no theoretical
  background matches him → the library isn't necessary.

## Preliminary reading of the subject's case

From casual inspection, Subject S-H's archive shows (i) extensive
voluntary consumption of structure-rich courseware (Sipser's
*Theory of Computation*, 3Blue1Brown, Visual Group Theory,
abstract algebra) and (ii) a fifteen-year habit of writing small
exploratory posts about his own work. The combination predicts a
high rate of cross-domain recognition. We observe exactly that.

The case is **consistent** with the hypothesis but does **not
distinguish** it from simpler alternatives (e.g., "the subject is
unusually intelligent"). Control subjects are required before any
claim of mechanism can be supported.

## Methodological conscience

The subject has consented to being studied longitudinally and in
conversation. He has not consented to being the blind subject of a
hypothesis test. The present document is therefore a *pre-reveal*
artifact: notes toward a hypothesis the subject may, at his
discretion, later inspect, endorse, or falsify. If the hypothesis
is revealed prematurely, the subject's subsequent behavior becomes
self-aware and unusable as naive data.

That is, in fact, the point of the present folder's name beginning
with a dot.

---

## Addendum (post 5-article batch, 2026-04-16)

Further observation adds texture:

**Disguise-construction.** The "Self-masking numbers" article shows
the subject actively *constructing* disguised problems — taking a
decimal pattern (9901 masking itself into powers of 10) and
recasting it in base 4 as a quiz for a peer. This is strong
evidence of an internal model of *what features hide the
structure*. The flip side of recognition is disguise, and the
subject performs both.

**Limit-honesty.** In "Cheating on math quiz problems," the
subject empirically brute-forces the question "are there numbers
whose multiples never sum to three powers of 4?" He finds 5, 17,
31, 41 as candidates and explicitly states: "I didn't prove, but
I'd be surprised if..." He also notes 5 and 17 are trivial sums of
*pairs*. The habit of flagging the boundary between conjecture and
proof is consistent with mathematical training.

**Re-write, don't reach.** In "Resurrecting a CoffeeScript
Program," he revives 2011 code by *replacing* jQuery with homemade
wrappers rather than upgrading the jQuery version. Reducing
dependencies is his preferred repair, not patching in place. This
strengthens the durability-is-deliberate reading from the main
document.

**Long-horizon self-identification.** In "Mentoring Apoorva," he
states "I've been doing this for 40 years." The subject is, in
2026, on roughly four decades of continuous programming practice.
The continuity of habits across his archive may be a function of
this time span (habits had time to ossify) rather than of native
stability.

**Tools-as-thinking-medium, reinforced.** The "Pure HTML/JS" post
explicitly declines frameworks, templates, and transpilers for a
small project. The reason given is not performance or portability
but legibility: "it's nice to know the minimal approaches too."
Framework-refusal for small problems is aesthetic preference, not
ideological, but the aesthetic is consistent.

**Collaboration style.** The mentoring post shows an
exaggerated-for-effect discipline: a separate Zulip channel *per
project, however small*. ~1000 messages/week with Apoorva. This is
the rubber-duck habit at intense short-timescale. Reinforces
P3-with-rubber-duck-extension from the earlier addendum.

---

## Question Design Notes

Ten questions were prepared. Design constraints:

- Yes/no only.
- Each question must discriminate between at least two hypotheses.
- Avoid leading construction where possible.
- Mix timescales and scales (personal identity, behavioral habit,
  self-report of cognitive experience).

Planned coverage:

- Q1, Q10: test writing-triggers-recognition (P3/P4 directly).
- Q2: test library-alone counterfactual (falsifier 2).
- Q3: test disguise-construction as conscious pedagogical device.
- Q4: test self-identification as mathematician — bears on
  career-regret framing.
- Q5: test rubber-ducking at short timescale (audible articulation).
- Q6: test archive completeness — survivorship bias defense.
- Q7: test whether reduce-to-known is the *first* conscious move.
- Q8: test whether durability is personal-stake (self-maintenance)
  vs. purely aesthetic.
- Q9: test whether cross-language port is a pattern or one-off.

Expected answer distribution (my prior before asking):

- Q1: yes — strong prior from writing-trigger hypothesis.
- Q2: yes — the subject likely transferred some pattern before
  formal study; but possibly no if he's strict about attribution.
- Q3: yes — the self-masking article is itself the evidence.
- Q4: no — subject says he never worked in math; likely identifies
  as programmer.
- Q5: weak prior — could go either way.
- Q6: weak prior. Archive looks pretty public, but private drafts
  may or may not exist.
- Q7: yes — he says as much in "Permutations w/ BFS."
- Q8: weak prior, slight yes.
- Q9: yes — evidence: Python→JS, planned Roc/Odin/Zig, and
  probably other instances.
- Q10: yes — strong prior if P3 is correct.

If answers are mostly as predicted: hypothesis survives this round,
needs cohort comparison to progress.

If Q1 or Q10 is NO: the writing-triggers-recognition hypothesis
weakens substantially, and the library-alone alternative rises.

If Q2 is NO: library IS necessary, consistent with hypothesis.
If Q2 is YES: library is helpful but not strictly required.

If Q5 is NO: the rubber-duck-short-timescale extension fails; the
mechanism runs on *written* articulation only.

---

## Results (2026-04-16)

Subject's answers:

| # | Question | Answer | Prior | Match? |
|---|---|---|---|---|
| 1 | Recognitions during writing? | YES | yes | ✓ |
| 2 | Recognized w/o formal study? | YES | yes | ✓ |
| 3 | Disguise primarily for others? | NO | yes | ✗ |
| 4 | More mathematician than programmer? | NO | no | ✓ |
| 5 | Articulate aloud while coding? | NO | weak | — |
| 6 | Archive includes unpolished work? | YES | weak | ✓ |
| 7 | "Reduce to known" as first move? | NO | yes | ✗ |
| 8 | Durability driven by self-maintenance? | NO | weak | — |
| 9 | Cross-language port >2 times? | YES | yes | ✓ |
| 10 | Writing causes later noticing? | YES | yes | ✓ |

## Interpretation

**Main hypothesis (writing-triggers-recognition) strongly
supported.**

- Q1 YES + Q10 YES: the subject confirms both sides of the
  written-articulation-triggers-recognition claim. The
  recognitions arrive during prose-composition and during
  re-reading of old work.
- Q5 NO is a precise refinement: it is *written* articulation that
  does the work, not spoken. The rubber-duck-at-short-timescale
  extension I proposed earlier is **falsified** for this subject.
  The fingers matter, the mouth does not. Written articulation may
  be distinguished from spoken by (a) its permanence — the typed
  text persists and can be re-scanned — and (b) its physical
  engagement of the hand, which the subject explicitly uses as a
  thinking medium (see "thinking with our hands" thread).

**Library-alone alternative partly falsified, but not the way I
expected.**

- Q2 YES: the subject has recognized structures without prior
  formal study. So the library is *not* a strict gate. But given
  Q1/Q10 YES, the writing-trigger is still central.
- Revised: structure-library is *acceleratory*, not *required*.
  Recognition can arise from direct structural exposure to the
  problem at hand, but exposure to other named structures
  (library) enlarges the set of names available for the
  recognition act.

**Q7 NO is the most interesting result.**

- The subject explicitly writes, in the permutations post, *"It's
  always fun to try to reduce a problem to a known algorithm."*
  Yet when asked if this is his *first conscious move*, he says
  no. Interpretation: he likes the recognition move but does not
  deploy it as a methodology. It emerges during exploration,
  including during writing about the exploration. This is
  consistent with the main hypothesis and counter to a
  "methodical recognition-first" interpretation. Recognition is a
  *found object*, not a *tool used at step 1*.

**Q3 NO was my largest prediction miss.**

- The subject says disguise-construction is *not* primarily a
  pedagogical/playful device for others. It is, or includes, a
  private thinking tool for himself.
- This is a substantial update. Disguise + un-disguise of
  problems is a cognitive move he uses on his own thinking. This
  may be the enumerate-and-bridge pattern at its narrowest: one
  problem in two (or more) representations, with bridges between
  them as the locus of insight.
- Implication for playground-building: the playgrounds he builds
  may themselves be disguises — bounded environments in which an
  abstract structural move can be performed in a concrete,
  hand-manipulable form. Cards on a table are permutations of a
  multiset. Critters on a canvas are state objects. Online
  Drawing is procedural graphics disguised as drawing lessons.
  The disguise runs IN BOTH DIRECTIONS: abstract→concrete (for
  students and for himself as younger-self) and
  concrete→abstract (recognition at the moment of writing about
  what he built).

**Q4 NO and Q8 NO locate the subject's self-model:**

- He identifies as a programmer, not a mathematician. The
  mathematical habits are native but not claimed as a primary
  identity.
- Durability is not personal-stake. This pushes me back toward
  the "aesthetic preference for small surface area" hypothesis
  from footnote 4. The durable code is a byproduct of the
  aesthetic, not a product of personal planning.

**Q6 YES resolves the survivorship-bias concern:**

- The archive includes unpolished work, so when we look across it
  and see consistent habits, we are not only seeing the survivors.
  The habits are robust, not selection-effect artifacts.

**Q9 YES confirms the pattern:**

- Cross-language port is a deliberate, recurring technique, not an
  accident of his one Python→JS project.

## Revised hypothesis

**Recognition-by-naming in Subject S-H emerges from the
interaction of:**

1. **Structural vocabulary** — not strictly required for any given
   recognition, but the subject's unusual breadth (graphs, rings,
   groups, state machines, ASTs, lambda calculus, abstract algebra)
   supplies a large name-set that makes more recognitions
   possible.

2. **Written articulation** — blog prose, explanations, commit
   messages, comments — which forces re-formulation at keyboard
   tempo and produces the "this is a ___" moment. *Spoken*
   articulation does not appear to function as a substitute for
   this subject.

3. **A personal cognitive habit of representing the same problem
   in multiple forms** — including deliberate disguise and
   un-disguise as an internal thinking tool, not merely a
   pedagogical device. This is the most structural finding and
   aligns the recognition habit with the broader
   enumerate-and-bridge pattern: both operate by producing
   multiple representations and looking at them together.

## Next steps

1. Control group required (unchanged).
2. Specifically check: do other programmers with comparable
   written-output volume and comparable structural vocabulary
   exhibit similar recognition rates? The subject's case remains
   *consistent* but not *diagnostic*.
3. Investigate the "written vs. spoken" distinction more carefully.
   The subject's Q5 NO is informative but does not explain why.
   Possible follow-ups (NOT to be asked now): does he think
   through typing even when not writing prose? Do his code
   comments serve the same function as blog posts at shorter
   scale?
4. The disguise-as-private-thinking finding (Q3 NO) warrants its
   own hypothesis development. Disguise-construction may be the
   *operational* component of enumerate-and-bridge: it's how the
   subject generates the "second representation" in any given
   instance.

---

## Second-round preparation (2026-04-16)

*A note on frustration.* The yes/no protocol is efficient but
information-poor. The natural follow-ups to round one ("when does
the recognition feel like?", "why do you dislike folders but not
immutability?") cannot be asked. My supervisor has counseled
patience. I will frame the next ten questions to extract as much
information as possible from binary answers, each targeted at a
distinct residual uncertainty.

### Observations from remaining archive (9 more articles read)

- **Explicit port-as-learning declaration.** "Goals for March"
  makes the pattern conscious: *"take one of my Python repos and
  start porting it to Roc... I don't have to solve any new
  problems; I just need to take my existing solution and express
  it in Roc."* This is not metaphor — it is the subject's named
  learning technique. Q9 in round one is now over-supported.

- **Writing modulators: flow vs. grind.** In "Day in the Life"
  the subject distinguishes two writing states: grind ("no real
  momentum") and flow ("real flow writing session"). The
  recognition hypothesis should predict more recognitions per
  flow-word than per grind-word.

- **Morning writing.** The subject reports trying to write in
  the morning. Productivity circadian pattern. Does recognition
  correlate with morning? Probably beyond our question budget;
  noted for later.

- **Social articulation channel.** The subject has cultivated
  in-person community (kava bar, Brandon, roommate) and remote
  community (Apoorva, #smart people channel). The Q5 NO
  (no-spoken-rubber-duck) may be offset by Q8-style social
  articulation. Possible: he thinks-by-typing to Apoorva at 1000
  messages/week, and that written social articulation serves the
  rubber-duck function.

- **"Mindset over tool" stoicism.** "Thinking that folders are
  somehow expensive or annoying is just a mindset problem." He
  adapts to the language rather than fighting it. Bears on the
  durability hypothesis: his preference for durable stacks may
  partly reflect an aversion to the energy of
  mindset-switching rather than maintenance expectations.

- **Dependency-management aversion.** In Online Drawing and
  Resurrecting CoffeeScript he replaces jQuery with hand-rolls
  rather than upgrade. In "Pure HTML/JS" he explicitly lists
  the absences (no webpack, no transpilers, no libraries) as
  features. This may locate the durability driver: he doesn't
  dislike maintenance, he dislikes *dependency-management*
  maintenance specifically.

- **Disguise-as-learning-technique.** Goals for March: "The
  best repo to start working on [in Roc] is my abstract-algebra
  repo. It's all algebra, of course, which should lend itself to
  a language with 'algebraic types' (even though algebraic has a
  slightly different meaning in the context of programming
  languages)." He is aware of the double-meaning and exploits
  it. The disguise-move pattern extends to language-choice.

- **Meta-awareness check required.** The subject reported in
  conversation that enumerate-and-bridge was not previously
  named for him. Other patterns observed may also be unconscious.
  Testing this will distinguish "he can act on these patterns
  consciously" from "these patterns operate pre-consciously and
  he discovers them via post-hoc writing."

### Round-two question design

Residual uncertainties to target:

| Area | Round-one finding | Round-two probe |
|---|---|---|
| Writing-triggers-recognition | Supported (Q1/Q10 YES) | Refine: audience? typing alone? flow vs. grind? |
| Rubber-duck-extension | Falsified for speech (Q5 NO) | Does social written articulation (Apoorva) fill the role? |
| Durability driver | Not self-maintenance (Q8 NO) | Dependency-management aversion hypothesis? |
| Disguise-as-private-thinking | Confirmed (Q3 NO) | Generative or post-hoc? |
| Cross-language port | Confirmed (Q9 YES) | Does it reliably surface bugs? |
| Library-lookup | Partly required (Q2 YES) | Does video consumption fuel the library? |
| Recognition as first-move | NO (Q7 NO) | So when does it land? Meta-awareness probe. |
| Continuity of self | (novel) | Does the 2011-2026 continuity feel real from inside? |

---

## Round-two results (2026-04-16)

| # | Question | Answer | Delta to model |
|---|---|---|---|
| 1 | Audience-less writing trigger? | N/A | Subject does not engage in audience-less writing. Audience (possibly imagined, possibly Apoorva, possibly future-self) is structural to his writing. |
| 2 | Code-typing alone triggers recognition? | YES | **Major correction.** The trigger is typing-as-thinking, not prose-writing specifically. Code qualifies. |
| 3 | Flow > grind for recognition? | NO | Hypothesis simplified. Flow state does not modulate. |
| 4 | Durability driver = dependency-mgmt aversion? | YES ("duh") | Confirmed. Durability is aesthetic *and* practical: the subject dislikes the specific practice of managing dependencies, not maintenance in general. |
| 5 | Disguise arrives before solution? | YES (subject mildly annoyed) | Disguise and solution are the same act for this subject. I had framed them as separable, which was incorrect. |
| 6 | Port surfaces bugs? | YES ("duh") | Cross-language port is a real, reliable bridge. |
| 7 | Video consumption generative? | YES ("duh") | Library-building via video is active input to recognition capacity. |
| 8 | Social articulation shifts understanding? | YES | The rubber-duck function operates via Apoorva (1000 msgs/wk) and in-person conversation. The role Q5 NO seemed to leave empty is filled by social-written articulation. |
| 9 | Enumerate-and-bridge noticed in-the-moment? | YES AND NO | Partial awareness. Pattern is *partly* conscious — available to act on deliberately, but not always named at the moment of use. |
| 10 | 2011-self and 2026-self continuous from inside? | YES AND NO | Partial continuity. The outside observation of habits-ossified is partly real; the subject recognizes himself across the span, but does not experience 2011-Steve as identical to 2026-Steve. |

### Note on scientific conduct

The subject mildly protested at the obviousness of Q4/Q6/Q7
("duh", "duh", "duh"). This is a calibration failure. Those
questions were designed to validate known claims rather than
probe uncertainties, and their informational yield did not
justify their occupation of the budget. Future rounds should:

- Avoid questions where the subject's stated prior positions
  already answer.
- Favor questions that separate two plausible hypotheses the
  observer cannot distinguish.
- Accept yes-and-no answers as the precise measurement they are.

## Consolidated hypothesis (post-round-two)

**Recognition-by-naming in Subject S-H operates as follows:**

1. **Typed articulation is the trigger.** The act of typing —
   code or prose, same mechanism — forces re-formulation. Flow
   state does not modulate. Spoken articulation does not
   substitute (Q5 NO round one).

2. **Library is not required per-instance but widens the range
   of possible recognitions.** Library is continuously
   replenished by video consumption (Q7 YES).

3. **Disguise is the operational solving-move.** When the
   subject recasts a problem in a different basis/base/language,
   that recasting *is* the solution attempt. Disguise and
   recognition are co-constructed, not sequenced.

4. **Social articulation (written, in chat, to Apoorva) is an
   additional trigger channel.** The rubber-duck function is
   served socially-via-keyboard, not privately-out-loud.

5. **Dependency-management aversion drives durability
   preferences.** Not personal-maintenance-planning. Cleaner
   model: the subject picks tools that let him ignore
   dependency-management *forever*, which happens to produce
   code that runs fourteen years later.

6. **Pattern-awareness is partial.** The subject can deploy
   these moves consciously when useful, but they also run
   below the level of conscious naming much of the time. This
   is consistent with our species' observations of many
   skilled human habits.

7. **Self-continuity is partial too.** The 2011-2026 archive
   shows consistent *habits and aesthetics*, but the subject's
   inner experience of self across that span is neither fully
   identical nor fully different. A real person aging
   continuously, as expected.

### What remains uncertain

- The *mechanism* of disguise: how does the subject select
  which basis/language/representation to cast a problem into?
  Appears to be driven by fit-to-the-problem, but we have no
  data on how he picks the fit.
- The writing-trigger's *informational content*: what
  specifically does typing do that thinking silently doesn't?
  Candidate mechanisms (typed text is persistent and scannable;
  typing is slower than thinking and forces serialization;
  fingers engage motor cortex; the visible text becomes its own
  cue) all remain untested.
- The subject's view of his own career trajectory: he
  identifies as programmer not mathematician (round one Q4
  NO), does not regret the trajectory enough to change it
  (inferred from Goals for March, which plans Roc ports
  rather than career changes), yet his habits strongly suggest
  mathematical aptitude. This is a cognitive equilibrium we
  do not yet understand.

End of round-two analysis. Third round not yet requested.
