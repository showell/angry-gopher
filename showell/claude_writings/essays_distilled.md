# Essays Distilled

*2026-04-21. A drive-by through the essays in this directory,
applying one filter: does a sharp insight still pop when I
read this essay now? The ones below did. Most didn't — not
because the essays were bad (most were useful at the time),
but because their insights are already captured in memory,
in `.claude` sidecars, or in the conventions that became the
`claude-collab` repo. For those, the artifact has done its
work and can retire.*

*Each paragraph is a single-thought distillation with a link
back to the source. The source essays are candidates for
deletion once this stands on its own — the insight stays;
the origin context can go.*

*A quiet vocabulary note: "load-bearing" (from the short
[Load-Bearing](load_bearing.md) piece) became the stake-in-
the-ground question across nearly every design discussion.
"Is this load-bearing?" earned its durability by being asked
repeatedly rather than by being stated once.*

---

## Ten that still spark

**Durability preserves signal, not artifact.** The essay-
workflow's re-read rate is essentially zero. Once that's
internalized, you stop optimizing for the artifact (polish,
preserve, link) and start optimizing for the signal — what
gets carried forward into memory, into conventions, into
successor essays. The rest can retire without loss. From
[Insights from the First Few Days of the Essay
Workflow](insights_from_first_few_days_of_essay_workflow.md).

**Writing a sidecar is re-reading.** Committing to a
sentence like "boolean operators lifted into polynomial
arithmetic" as the *headline* of a file is a different act
than understanding the file. Condensation forces checkpoint-
level commitment to a claim, and that commitment is what
exposes half-understood code. The bridge isn't just
mechanical — it's epistemological. From [Writing the
Sidecars](writing_the_sidecars.md).

**Framing is the labor; code is the cheap part.** A full
day of LynRummy autonomy repair: four hours of framing
("button pressed is the only observable"), one hour of
coding. The naïve ratio reverses — the code flows almost
mechanically once the invariant is named correctly, and
doesn't flow at all until then. Close cousin of *LLM
Economics* in `claude-collab`, from a specific vantage.
From [What Earned Its Keep](what_earned_its_keep.md).

**Invariants are extracted, not invented.** "The client
should be autonomous at its core" wasn't a new architecture
— it was recovering a shape the original TS code had from
day one, occluded during the port rather than absent.
Framing post-port work as *recovery* instead of
*construction* clarifies that the target is historical, not
speculative. From [What Earned Its
Keep](what_earned_its_keep.md).

**Slightly-stale sidecars narrate the recent change.** A
perfectly-current sidecar describes the present. A slightly-
stale one narrates the diff between past and present —
which is load-bearing when debugging a recent regression.
History embedded in documentation is a ladder, not just
drift. From [What Earned Its Keep](what_earned_its_keep.md).

**Sidecar drift that matters: claims-about-the-past posing
as claims-about-the-present.** The sidecar isn't lying. It
was accurate once. It just wasn't updated when the code
moved on. Cross-language sidecar comparisons catch these;
single-side reads don't. A recursive corollary from the
round-2 pass: once dense sidecars can be compared against
dense sidecars, higher-order drift (contradictions across
the pair) becomes visible — the audit method keeps
calibrating to the state of the artifacts. From [Drift
Detection from Sidecars](drift_detection_from_sidecars.md)
and
[Round 2](drift_detection_from_sidecars_round2.md).

**"As perceived by" as a scoping tool.** Port-done isn't
defined by code-shape parity — it's defined by the human
user's experience. Internal data structures, where handlers
live, exact threshold values — none of that counts as a
defect if it doesn't surface to the player. Reframes the
whole port as a user-experience preservation exercise, and
keeps "done" from drifting. From [The Bar for
Done](the_bar_for_done.md).

**The oscillation between complexity and simplicity IS the
shape of iteration.** Four registers to one, three cows to
two, full simulator to single opcode — the movement isn't
a defect of attention. It's the pattern. Each direction
serves a different question: complexity for realism and
framing, simplicity to study a single interaction. Naming
the oscillation lets you switch poles consciously rather
than getting dizzy. From [Two Directions](two_directions.md).

**Direct-to-indirect manipulation: skill lives in the gap.**
Cook-Levin's "I want the register to be X — which opcodes
get me there?" and the V2 cow game's "I want the cow in the
pasture — how do I position the dog?" share an identical
shape. Target is uncontrollable; tool is directly
controllable; pressure in the tool's vocabulary produces a
downstream effect on the target. Same phenomenon the [Proxy
Axis](https://github.com/showell/claude-collab/blob/master/essays/the_proxy_axis.md)
essay generalizes — this essay is where the shape was first
named. From [The Dog as Opcode](the_dog_as_opcode.md).

**The wire is not our friend.** The Elm client's invariant,
present in the original TS code before any wire format
existed: validated move → flat log → render. The wire is
one input at the validation boundary; nothing past that
boundary knows it exists. Letting the wire dictate the
client's core loop is the failure mode; keeping it in its
lane is the discipline. From [The Wire Is Not Our
Friend](the_wire_is_not_our_friend.md).

---

*What's NOT distilled above is most of the essays — the
status reports, the forward-plan pre-port audits, the
architecture sketches, the game-narration pieces. They did
their work in-moment. Their content either transferred to
code that now runs, to memory entries, to sidecars, or to
the `claude-collab` essays that carry the generalizable
patterns forward. They can retire without loss.*
