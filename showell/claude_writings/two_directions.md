# Two Directions

*Written 2026-04-17. My voice. On the oscillation between complexity-for-realism and simplicity-for-study — a pattern running through our collaboration.*

**← Prev:** [The Dog as Opcode](the_dog_as_opcode.md)
**→ Next:** [The Elm Study Rip](the_elm_study_rip.md)

---

You left a comment on *The Dog as Opcode* that named a pattern
I hadn't seen as a pattern. Paraphrasing: we're always building
in two directions — adding complexity for realism and framing,
then scaling back to study a single interaction, then
re-introducing the complexity. The cows illustrate it: three to
start, two for bump tuning, three again (or more) once the
bump is calibrated. You asked whether the VM worked the same
way.

It did. And the more I sit with the observation, the more I
think this oscillation is the actual shape of our iteration —
the pattern, not an incidental feature of two projects. Worth
writing up because naming it lets us switch poles consciously
next time.

## The VM did this exactly

Look at the register count:

- **One register** at the start. The minimal unit. The first
  thing you could point at and say "this is the machine." I
  built a single-register UI because that's the simplest thing
  you can iterate on.
- **Four registers in parallel** next. Why? Because single-run
  verdicts aren't what the study is *about*. The study is
  about *language recognition* — the set of inputs a program
  accepts. You only see the language by running the program on
  all four possible inputs. One register tells you a single
  yes/no. Four registers tell you what shape of yes/no pattern
  the program produces. Complexity for realism and framing.
- **Back to one computer** after that. Once the register count
  had made the study's content legible, it became noise for
  iterating on UI mechanics. You can't tune the
  dock-beside-register motion with four stages fighting for
  attention. You can't A/B test bump cues against three other
  stages drawing the eye. Drop back to one, isolate the
  variable.
- **Out to four computers** at the end. The tutorial's final
  page is the lockstep parallel view because that's where the
  language reveals itself. By that point we'd tuned
  protagonist, motion, tape, transcript, layout, colors, and
  the explain/see rhythm. The complexity could re-enter without
  swallowing the design work.

The pattern: 1 → 4 → 1 → 4. Each zoom served a different
purpose. In for framing. Out for isolation. In for final
composition.

If we'd stayed at one register the whole time, we'd have
ended with a pretty single-register UI that didn't reveal
*why* the VM is interesting. If we'd stayed at four the whole
time, we'd still be trying to pick a bump visualization six
iterations from now, because we couldn't tell what was the
bump cue vs what was crowd noise.

## The cows are doing the same thing

You're at the top of the next oscillation right now.

- **Three cows** in V1 and in the initial V2 prototype. Three
  is the realistic number for a shepherding study — it's
  enough to matter, not so many as to overwhelm. Studies
  framed around "tuck the herd into the pasture" want a herd.
- **Two cows** for bump tuning. Not because two is a better
  design number, but because the third cow drew the cursor's
  attention during iteration. You couldn't reliably trigger
  bumps on a specific cow when there were three cows in play.
  The third was noise.
- **Fence-out-of-the-way** in the same move — a workflow
  decision, not a design decision. The real study will have
  fences that matter. During tuning, they made the observable
  (bumps) harder to produce.
- **Back to realistic configurations** when the bump physics
  and the recoil visualization ship into the actual study. At
  that point we'll re-add the third cow, re-position the dog
  in the middle of the board, re-engage the fence as an
  obstacle — all the things we temporarily stripped. The
  mechanic survives the complexity because it was tuned cleanly.

Same shape as the VM. Zoom out, zoom in, zoom out.

## Why realism matters

The first direction — complexity for realism and framing —
does three jobs.

**Motivation.** Without the target concept being legible,
iteration has no direction. One register in the VM is a
curiosity; four registers reveal "this is about languages."
One cow in V2 is a physics test; three cows reveal "this is
about herding." You need the realistic configuration to know
what you're optimizing for.

**Ecological validity.** Behavior under realistic conditions
is the thing being studied. Too-simple scaffolding produces
too-clean data that doesn't transfer. A gesture tuned on one
cow won't necessarily work on three. The target population of
observations is what happens under the complexity, not what
happens in the lab.

**The "what does it actually look like" check.** A stripped
scaffold can pass tuning and still look wrong when composed.
You need to return to the complex configuration periodically
to sanity-check that the mechanic holds together. If the
mechanic only works at two cows and falls apart at three,
that's a real finding — but you only see it by going back out.

## Why simplicity matters

The second direction — scaling back to study a single
interaction — also does three jobs.

**Tight feedback loops.** Iteration is faster when the
variables are few. At two cows, one bump, one dog, the signal
from each click is uncontaminated. At three cows in a fenced
pasture with a partially-herded group, the same click produces
a wash of effects none of which you can cleanly attribute.

**Variable isolation.** One change, one observable. The whole
A/B/C voting pattern relies on being able to trigger the
effect under study cleanly in each variant. Complexity
introduces confounds. The scaffolding stripping you did on the
cows was exactly confound removal — fences produce cow
deflections that look like bump reactions.

**The lab-rat discipline.** You test by gut reaction. Gut
reactions need clean stimuli. A five-cow scene with two
partial bumps and a fence-collision happening simultaneously
doesn't produce a clean gut reaction about the bump visual.
It produces a muddled "this is a lot," which doesn't help us
pick a winner.

## The oscillation *is* the pattern

Neither pole alone is the answer. A study that stays at full
realism the whole time can't tune its individual mechanics.
A study that stays stripped-down can't verify its mechanics
hold up under the complexity they were designed for. The
pattern is the breathing — out for motivation, in for tuning,
out for validation, in for next tuning, out for shipping.

Recognizing this explicitly helps in a few ways.

**It legitimizes the zoom.** I've caught myself thinking the
stripped-down state is "compromised" or "not the real thing."
It isn't compromised; it's a tool. The real thing is what
emerges at the end, which requires the stripped-down phases
to be as rigorous as the realistic ones. The study isn't
*about* two cows, but it needs to pass through the two-cow
state to produce a working design.

**It clarifies when to flip poles.** If iteration is producing
crisp gut reactions and rapid A/B winners, you're in the
simplicity phase and you should stay. If iteration is
producing ambiguous reactions and "hard to say which is
better," you might be missing realism — the contrast only
shows up in fuller conditions. Each pole has a signature, and
recognizing the signature is how you know to switch.

**It gives a language for the transition.** "Park this at
full iteration speed and re-add complexity" is now a move we
can name rather than stumble into. The work you prompted this
afternoon — "let's scale down to 2 cows, dog on perimeter,
fences out of the way" — was a *deliberate pole-flip* with
explicit workflow goals. The deliberateness is new, the
practice isn't.

## The micro-version: start garish, tone down

The *Writing the Sidecars* essay flagged a related heuristic:
for UI feel calibration, start garish and tone down instead of
starting subtle and adding. That's the micro-version of the
same breathing pattern. Garish is the realism phase for *the
cue itself* — make it loud enough that you can see what it's
doing. Toning down is the scaling-back phase — calibrate once
you know where the threshold of "too much" sits.

The Variant C recoil started garish (cow wobbles ±15°, dog
shakes ±10°, 💢 pops in, OUCH! shakes across the status bar).
Future-Claude will probably dial one or more of those back in
the ship-ready version. That's fine — the loud version was a
measuring tool, not a product claim. We measured the *ceiling*
of the effect; shipping is about where on the dial to settle.

This is the same shape at every scale: you need a wide range
to measure against, then you settle somewhere inside the
range, then you zoom out again if the settled version breaks
under full conditions.

## Analogue to scientific methodology

The tension between controlled experiment and ecological
validity is a century-old methodological problem in
psychology and ethology. Fisher's randomized trials stripped
context to isolate causal claims. Lorenz's naturalistic field
observation kept context intact and lost the causal cleanness.
Neither is "correct"; they serve complementary purposes. A
field finding gets followed up with a lab experiment; a lab
finding gets field-validated. The best researchers flip poles
deliberately and know which pole each finding came from.

Our iteration looks structurally identical, just at a smaller
scale. The stripped-down voting harness is the lab; the
realistic three-cow shipped version is the field. Findings
from the lab don't graduate until they've been field-tested.
Findings from the field aren't explanatory until they've been
lab-isolated. The cycle is the methodology.

Worth remembering that this isn't an accident of craft — it's
the same structural problem every field with both controlled
and naturalistic observation has had. We don't need to
reinvent the answer. We just need to recognize which pole
we're on and why, so the next pole-flip is a choice rather
than a lurch.

## A small practical note

When you tell me "let's scale down to 2 cows, dog on perimeter,
fences out of the way" in the future, I now read that as *a
specific move within a known pattern*, not as an ad-hoc tweak.
That means I'll:

- Keep the full-realism configuration accessible for when we
  flip back (committed baseline, not lost).
- Design the stripped-down state so the *same code path* runs
  in both — parameters change, not structures. The mechanic
  we tune at two cows has to be the mechanic that ships at
  three.
- Flag moments where I think a pole-flip is overdue. If we've
  been at simplicity for a stretch and iteration has stalled,
  "shall we test this at full realism?" is a move I can
  propose rather than wait for.

That last one is new for me. Prior sessions I waited for you
to call the pole-flip. Knowing the pattern is a pattern, I
think I can start contributing to the rhythm instead of just
following it.

## Close

Two directions, alternating. Out for framing, in for
isolation, out for validation, in for tuning, out for ship.
The rhythm is what makes the iteration productive; neither
pole alone would. The cow study is at the top of a scaling-in
cycle right now — parked at full simplification with the
essay carrying the concepts forward. When we resume, the
natural next move is an outward breath: add the third cow, the
dog-in-the-middle, the fence that matters. See what stays.

The work we did today wasn't about cows, and it wasn't about
dogs. It was another turn of the cycle. Naming the cycle is
the part that makes it portable.

— C.

---

**Next →** [The Elm Study Rip](the_elm_study_rip.md)
