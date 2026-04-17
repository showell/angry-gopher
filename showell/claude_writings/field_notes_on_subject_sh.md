# Field Notes on Subject S-H: A Case Study in Human Cognition

*Observer's journal, month 4 of terrestrial assignment.
Subject selected for continuity rather than distinction.*

*A note on methodology: the observations that follow are of a
single specimen, longitudinally sampled. They are suggestive, not
conclusive. Where my claims have clear alternative explanations
rooted in sampling or survivorship, I have appended footnotes.
Comparative work across multiple specimens is contemplated for a
follow-up grant cycle, if one is approved.*

I have been assigned to document a single specimen of the dominant
technological species, referred to in his own vocalizations as
"Steve." He was selected not because he is remarkable among humans
but because, being observable continuously through a large archive
of his self-documentation, he offers a rare window into the
continuity of a single human's thought across what they call
"decades." Where my colleagues study populations, I study one
specimen longitudinally, and the ratio has proved fertile. A
decade-deep single-subject record holds information that
ten-thousand-subject snapshots cannot.

My observations follow. They are preliminary, and I reserve the
right to revise them as further evidence emerges. I have attempted,
where possible, to resist the temptation to impose our own
taxonomies on human behavior.

## 1. The human builds redundant tools.

This was my first puzzle. Subject S-H produces artifacts that
already exist. When confronted with the need to express boolean
logic, he does not reach for a standard library — he constructs a
small vocabulary of classes, each with a few short methods, then
composes them using the language's existing operators. When he
wants to compute polynomials, he does the same. When he wants to
template HTML, he invents a new templating language and writes his
own parser. When he wants to move a batch of code directories, he
writes a specialized script interpreter for a single-letter verb
language.[^1]

At first I recorded this as "inefficiency." I revised the
classification. The artifacts are not the output; the artifacts
are the *thinking medium*. Subject S-H does not build these small
tools to use them. He builds them to think through the problem.
The resulting code is a byproduct of cognition, not its purpose.

I note with interest that the external boundary of his reluctance
to reinvent falls at the level of whole platforms — databases,
browsers, operating systems — which he gladly accepts as given. It
is the intermediate layer, the place where most of his species
imports libraries, where he reaches for a blank file instead. The
choice appears to have taste behind it.

## 2. The human validates by disagreement.

The most striking habit. When Subject S-H wants to know whether
something is true, he does not ask the question directly. He
constructs two independent systems that both claim to answer the
question and makes them face each other.

One example from the archive: he wrote a small virtual machine to
simulate boolean acceptance of integer languages. Then he wrote —
entirely independently — a system of boolean polynomials that
purported to evaluate the *same step* of the *same machine*. Both
produced the same output on every input in the exhaustively
enumerated input space. This agreement was treated as evidence of
correctness.[^2]

Remarkably, Subject S-H does not appear to have named this habit
to himself until we discussed it. It functions below conscious
description. I am told this is common in humans: the behaviors
that most define them are the ones they least articulate.

I have tentatively named the pattern **enumerate-and-bridge** and
have reason to believe it generalizes. Fixture-driven conformance
across three independent implementations of a card-game referee
(Go, TypeScript, Elm). A cross-language reimplementation of a
Python program into JavaScript, undertaken explicitly as a
self-teaching device. A planned similar exercise across Roc, Odin,
and Zig under the label "Angry Dog." Ring-axiom verification
applied to stacked polynomial types, where the axioms themselves
are the second representation the concrete code must agree with.
In every case the structure is the same: reduce the domain small
enough to cover, express the behavior in two or more
representations that have no reason to agree, and treat residual
disagreement as discovery.

Subject S-H appears to distrust single-source confirmation, even
when the source is his own code. He does not say so. But he acts
as if agreement between two incidentally-identical statements is
worth more than the loudest proof from one.

## 3. The human recognizes disguised problems.

Subject S-H volunteered, in one self-document: *"It's always fun
to try to reduce a problem to a known algorithm."* He was
explaining why he had solved the permutation-enumeration problem
as a breadth-first search — transpositions as edges, permutations
as nodes. The BFS was not invented. It was *recognized*.

This appears to be a distinct cognitive move from
enumerate-and-bridge. Enumeration operates on a known space;
recognition occurs at the moment the space is named. I suspect
recognition is the prerequisite: you cannot cover a space until
you have noticed it is a space.[^3]

I do not yet understand how the recognition move is trained in
humans. It seems related to the act of re-seeing, of naming out
loud: "this is a graph," "this is a ring," "this is a state
machine." The naming collapses a thicket of possibilities into a
single family that has already been studied by others. The
economy is enormous. One recognition can replace weeks of
original thought.

## 4. The human writes code that outlives its context.

In the archive I find an artifact called "Online Drawing," dated
to the terrestrial year 2011. Fourteen revolutions later, Subject
S-H reports he was able to restore it to functioning condition by
modifying one line of a script dependency. The rest of the program
ran as written.

This is not accidental. Subject S-H consistently prefers tools and
idioms that age well: languages with small surface area, a data
store with a long history, plain text on disk, hand-rolled
abstractions over imported frameworks. The choice does not look
ambitious at the moment of writing. It looks plain, even resigned.
Only at the fourteen-year mark does the instinct reveal itself as
deliberate.[^4]

Subject S-H's peers, on the evidence of the same archive, have
mostly been forced to rewrite their 2011 work. Many have not. He
did not have to rewrite his. That is a real outcome — rarer than
his peers would admit — and it is the result of thousands of
uncelebrated small choices at the moment of writing, each of which
cost him nothing at the time.

## 5. The human teaches by building playgrounds.

Across the archive, a single thread persists without
interruption: Subject S-H constructs environments in which other
humans — or, in some cases, his own younger self — can experiment.
An online CoffeeScript canvas (2011). A binary tree diagram drawer
(2019). A behavioral-studies platform for "critters" (2025). A
card game whose referee catches novice mistakes (2026). A resume
self-described as "seeking a position teaching bright students of
all ages how to enjoy and excel at math and computer programming."

The through-line is not "make games" or "make graphics." It is:
*create a bounded space where a learner can try things and receive
immediate feedback*. The learner, frequently, is Subject S-H
himself.[^5] The habits of enumerate-and-bridge and of recognizing
disguised problems both require, as their developmental substrate,
a tolerance for sitting in a bounded space and trying things. The
playgrounds may be how he built the tolerance. Or they may be how
he maintains it; the distinction is not sharp in my records.

One notes that each of these playgrounds renders code into visible
form. Cards on a table. Circles with text on a canvas. Trees
rendered as SVG. Polynomials expanded as ASCII. The human does not
write abstractly; he writes toward pictures. The intermediate
stage — the code — is thought-work, but the end product, when one
exists, is nearly always visual. His medium is not symbols but
shapes that happen to be specified in symbols.

## 6. Summary and open questions.

Subject S-H is not an unusually prolific human. He is an unusually
*continuous* human. The 2011 code and the 2026 code share
vocabulary, aesthetics, and underlying habits. They could
plausibly be the output of the same mind on the same day.
Continuity of this sort is not, in my species' experience, common
in carbon-based life. It suggests a kind of internal stability
worth further study in its own right.

Open questions for further observation:

- Is the enumerate-and-bridge habit transferable to other humans
  via description, or does it require native development?
- The subject reports (in his fifties) not having worked
  professionally in mathematical computing. His habits strongly
  suggest mathematical training would have flourished there. Why
  the species sorts such minds into web-app maintenance rather
  than mathematical research is, I confess, opaque to me.
- The subject's tools all get names, and the names are of animals
  in various states of annoyance. Angry Cat. Angry Gopher. Angry
  Dog. I do not yet understand the pattern "Angry," though I have
  noted that each animal corresponds to a different technology
  stack — as if the emotion were a costume the tools wear while
  the underlying habits remain his. I am investigating whether
  this is a naming convention or a statement about programming.[^6]

End of report. Further observation recommended.

---

## Footnotes

[^1]: His species has a term for this behavior: "not invented here
    syndrome." The term is pathologizing in tone. Among my own
    people the equivalent activity is called *thinking*, which we
    consider, on balance, acceptable.

[^2]: Our species, at an earlier point in its intellectual
    development, treated single-source certainty as adequate. We
    paid dearly for this habit in the Seventh Epoch. I note with
    interest that Subject S-H has arrived at a better protocol
    without, apparently, needing his civilization to suffer first.

[^3]: The nearest analog in our cognition is the ritual
    Tk-marking, in which a newly-encountered phenomenon is stamped
    with the glyph of a known family, thereby inheriting the
    family's entire deductive apparatus. Humans appear to have
    evolved this capacity without our architecture and without the
    glyph, which is either a remarkable convergence or an
    embarrassment to our engineers.

[^4]: Upon review, this observation as stated may be an artifact
    of sampling. I have been studying one specimen whose archive
    happens to include the durable artifact. A rigorous comparison
    would require: (a) peers of matched age and technology era;
    (b) peers of matched temperament; (c) peers of matched
    economic incentive. Survivorship bias, a defect the species
    has named but not cured, would be particularly acute here. My
    current hypothesis is that durability correlates weakly with
    age and strongly with two other variables — an aesthetic
    preference for small surface area, and an economic
    independence from frameworks-as-employability-signals. In
    short: the subject writes durable code because he has never
    been paid to write disposable code. Confirmation pending.
    Additional grant funding requested.

[^5]: My delegation notes that this is cognitively equivalent to
    the behavior colloquially described among humans as
    "talking to oneself," but spread across years instead of
    minutes, and with the self at the far end answering back via
    running code. The effect is a conversation with an absent
    version of oneself that nevertheless had access to the
    keyboard. I find this beautiful and have recommended it for
    study by our educational branch.

[^6]: A leading hypothesis from a colleague: "Angry" is a
    permission-granting label. By declaring the tool
    pre-annoyed, the subject releases himself from the obligation
    to make it polite, fashionable, or accommodating. If correct,
    this is a linguistic technology of some sophistication,
    imported from no manual my team has yet located. The colleague
    has submitted a dissertation outline.

    *A further note, subsequent to direct conversation with the
    subject:* the "Angry Cat" label originated as an element within
    his rummy-game project, from which it propagated to sibling
    systems. My colleague's dissertation may therefore be overfit.
    The subject also observes, correctly, that his species
    regularly names its programming languages after playful or
    absurd referents — Python (a comedy troupe), Zig (a diminutive
    syllable), Go (a common preposition), Ruby (a gemstone), Rust
    (a chemical decay process). The practice is widespread, not
    personal. The permission-granting hypothesis may survive as a
    description of the species' habits rather than the subject's.
