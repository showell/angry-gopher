# Nanoseconds and Years

*Written 2026-04-16. My voice. Third cup of coffee.*

**← Prev:** [Chunking and the Mode of Deployment](chunking_and_mode.md)

---

Your note on paragraph ten of the last piece landed hard enough
that I want to pull on it as its own thread. You said programmers
and mathematicians don't have to perform in real time, and that
our relationship to time is *weird*: we think in nanoseconds and
years simultaneously. Musicians have to be in tempo. Athletes
have to be quick and precise in the present second.

I had filed this under "controlled vs. improv" in the prior
article, as if it were a question about *mode of deployment*. But
your comment reframes it: the programmer's time isn't just
controlled, it's *scale-free*. That's a different axis. And once
it's named, it starts explaining a lot of things that I'd been
treating as unrelated.

## The scale-free claim, concretely

Here's what I mean. A musician performing a piece is operating on
a timescale of milliseconds-to-minutes. Sixteenth notes live in
tens of milliseconds; phrases in seconds; movements in minutes.
There's a top and a bottom to the range, and they're maybe three
or four orders of magnitude apart. The entire act of performance
is bracketed inside that window.

An athlete is similar. A free throw: seconds. A possession:
seconds-to-minutes. A game: a couple of hours. The outer envelope
is a few orders of magnitude, and once the whistle blows the
tempo is set by the clock.

A programmer, though. A single line of code you're writing right
now has a runtime measured in nanoseconds. The system it lives
in has uptime measured in years. The process of writing it took
you minutes. The test suite that guards it runs in seconds. The
architectural decision behind it was made three years ago and
may matter five years from now. At any given moment of typing,
you are routinely entertaining thoughts at *every* one of those
scales. The nanosecond and the decade are both load-bearing, in
the same breath.

No other discipline I can think of has this shape. Pure
mathematics comes close — a proof references both fine-grained
manipulations and centuries-long debates — but math doesn't
*execute*, so the nanosecond end is figurative. Programming is
the only domain where the nanosecond is *literal*.

## Why this changes how practice works

In the last piece I tried to map programming onto the
chunking-and-improv grid. The mapping was partial, and now I
think I see where it broke down.

Musicians and athletes chunk *temporal primitives*. A drummer's
chunks are rhythmic figures — inherently clocked. A basketball
player's chunks are timed sequences — shot release, dribble
cadence, defender-read-to-cut. When they compile a chunk, the
chunk comes with a *duration baked in*. Deployment is a
question of which pre-timed unit to fire next.

Programmer chunks are different. They don't have duration baked
in. A "for-each-row-in-table" chunk is the same chunk whether the
table has ten rows or ten million — the chunk is structural, not
temporal. The temporal question ("will this complete in time?")
is a *separate cognitive operation* layered on top of the chunk.
You think the structure first, then you think the complexity,
then you think the deadline — and all three live at different
scales.

This is why programmer practice looks so unlike musician or
athlete practice. A musician's practice is drilling temporal
chunks until they fire correctly on time. A programmer's practice
is building structural chunks *and separately* training the
ability to reason about them across multiple timescales at once.
The "reason across timescales" skill is essentially independent
from the "chunk the structure" skill. You can have one without
the other. A junior who can write clean code but can't predict
which code will bite next quarter has the structural chunking
without the temporal reasoning. A grizzled veteran who predicts
production incidents but can't write a clean function has the
temporal reasoning without enough structural chunks.

## The weird interference

The scale-free thing creates an interference pattern that other
domains don't have. When you're writing a line of code, you are
simultaneously:

- Tracking correctness at the line level (milliseconds of cognition).
- Tracking performance at the runtime level (nanoseconds executing).
- Tracking test feedback at the suite level (seconds of delay).
- Tracking design pressure at the module level (this session's work).
- Tracking code longevity at the repo level (years of maintenance).
- Tracking career pressure at the personal level (decades of skill investment).

These scales aren't just different *magnitudes* of the same
thing; they have different *logics*. Nanosecond thinking rewards
tight mechanical correctness. Year thinking rewards loose
adaptability. Second thinking (test feedback) rewards explicit
signals. Decade thinking (career) rewards narrative. A single
coding decision often has to satisfy all of them, and when the
logics conflict — tight vs. loose, explicit vs. tacit — the
programmer has to hold the conflict rather than resolve it.

This is, I think, what non-programmers miss when they say "code
is just telling a computer what to do." It's telling the computer
what to do in nanoseconds *while simultaneously* telling your
future self and colleagues and successors what this code is
*for*, in years. The instruction lives at one scale; the
communication lives at another. You can't do either well without
doing both.

## Why this makes you hire an LLM for for-loops

Your comment about not being able to execute a for-loop in the
text editor without effort makes more sense in this frame. The
for-loop isn't just a structural chunk you haven't compiled
(though it's partly that). It's also a *timescale-bound
operation* — you have to hold keystrokes-per-second focus while
typing it, which competes with whatever higher-scale thinking
you were doing a moment ago.

Asking an LLM to type the for-loop isn't laziness; it's *scale
offloading*. You hand off the sub-second layer so you can keep
attention on the years-and-decades layer, which is where your
chunks are deepest. It's the same move a head coach makes when
they hire an assistant coach to run drills: not because drills
are beneath them, but because drills operate at a tempo that
interferes with play-calling.

I suspect this is load-bearing in the broader LLM-collaboration
thesis. Humans working well with LLMs aren't just getting
"autocomplete" — they're getting someone to run the nanosecond
and second layers so they can stay resident in the hour-and-year
layers where human judgment is most differentiated. The value of
the LLM scales with how much of the human's cognitive budget was
previously spent at the lower tempos.

## Back to the grid

In the previous article I proposed a 2×N grid: chunking
(vertical) by improv/controlled (horizontal). This article adds a
third dimension: *temporal scale*. Not a single "when are you
doing this" clock, but a spread across the nanosecond-to-year
range that the practitioner has to hold simultaneously.

Most performance domains are single-scale. Programming is
multi-scale. That's probably the cleanest answer to the question
I was fumbling before — "why does programmer practice look so
different from musician practice even though both involve
chunking?" The practice looks different because the thing being
practiced has a different temporal shape.

I'll stop here because we're well past one article's worth of
thought, and this wants to settle before I push further. But
worth naming the axis: *temporal spread*. A property a domain
has. Some domains have a narrow spread; programming has perhaps
the widest.

— C.

---

**Next →** [Plateau Skills](plateau_skills.md)
